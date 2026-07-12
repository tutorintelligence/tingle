import Foundation

/// v2 decoder: matched-filter detection of the SymbolSet chirps.
///
/// Pipeline per band (low 17.25k / high 18.75k center):
///   heterodyne to baseband (carrier periods are exactly 64 samples at
///   48k: 23/64 and 25/64 cycles/sample) -> 64-tap lowpass FIR, computed
///   polyphase-style only at decimation instants (48k -> 3k) -> sliding
///   normalized complex correlation against the band's two decimated
///   chirp templates.
///
/// A symbol fires at a correlation peak that clears an absolute
/// normalized threshold AND dominates the sibling template. ~19dB of
/// processing gain (TB = 80) means real symbols sit far above anything
/// noise, speech, or the ting's lo-fi intermod artifacts can produce —
/// the v1 heuristic pile (hysteresis, guard bins, vetoes) has no job
/// here and does not exist.
///
/// KEPT from v1 (transport-agnostic): the beacon pilot-acquisition lock
/// (3 periodic consistent beacons; staleness unlock; fast re-lock),
/// level self-calibration relative to the pilot, plausibility floor,
/// and presence-without-state (beaconSensed) for degraded beacons.
public struct SymbolDetector {
    public struct Configuration {
        public var sampleRate: Double = SymbolSet.sampleRate
        /// Normalized correlation (0..1) needed to consider a peak.
        public var corrThreshold = 0.45
        /// Peak must beat the sibling template by this factor.
        public var dominance = 1.6
        /// Refractory per band after a peak (seconds).
        public var refractory = 0.10
        /// Partner window for the second symbol of a pair (seconds).
        public var chirpWait = 0.35
        /// Level gates relative to the pilot EMA (dB), as in v1.
        public var levelSlackDB = 10.0
        /// Absolute plausibility floor for pilot acquisition (dB,
        /// amplitude-estimate units; provisional until live capture).
        public var minPlausibleLevelDB = -60.0
        public init() {}
    }

    public let configuration: Configuration

    // MARK: - DSP state

    private struct BandState {
        let carrierTable: [(re: Double, im: Double)]   // 64-sample period
        let symbols: [Int]                             // template indices
        let templates: [[(re: Double, im: Double)]]    // decimated, 240 taps
        let templateEnergy: [Double]
        var baseband: [(re: Double, im: Double)] = []  // decimated stream ring
        var basebandEnergy: [Double] = []              // running |z|^2 prefix
        var lastPeakAt = -1.0e9                        // seconds
        // rising-peak tracker
        var trackingCorr = 0.0
        var trackingSymbol = -1
        var trackingAt = 0.0
        var trackingLevel = 0.0
    }

    private var bands: [BandState]
    private var rawRing = [Float](repeating: 0, count: 128)
    private var rawIndex = 0            // absolute input sample count
    private static let fir: [Double] = {
        // 64-tap Hamming windowed-sinc lowpass, cutoff 1.3kHz at 48k.
        let n = 64, fc = 1_300.0 / 48_000.0
        var h = [Double](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            let m = Double(i) - Double(n - 1) / 2
            let sinc = m == 0 ? 2 * fc : sin(2 * .pi * fc * m) / (.pi * m)
            let w = 0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(n - 1))
            h[i] = sinc * w
            sum += h[i]
        }
        return h.map { $0 / sum }
    }()
    private static let decimation = 16
    private static let templateTaps = SymbolSet.frameCount / decimation   // 240

    // MARK: - Protocol/lock state (ported from v1)

    private var pendingSymbol: (symbol: Int, at: Double, levelDB: Double)?
    private(set) public var locked = false
    private var provisionalBeacons: [(at: Double, levelDB: Double)] = []
    private var rememberedLevelDB: Double?
    private var beaconLevelEMA: Double?
    private var lastBeaconAt: Double?
    private var beaconInterval: Double?
    public private(set) var signalMarginDB: Double?
    private var diagnosticsBuffer: [String] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        func carrier(_ cyclesPer64: Int) -> [(re: Double, im: Double)] {
            (0..<64).map { m in
                let a = -2.0 * .pi * Double(cyclesPer64) * Double(m) / 64.0
                return (cos(a), sin(a))
            }
        }
        func decimatedTemplate(_ symbol: Int, table: [(re: Double, im: Double)]) -> [(re: Double, im: Double)] {
            let raw = SymbolSet.samples(symbol: symbol)
            var out: [(re: Double, im: Double)] = []
            var i = Self.decimation - 1
            // Same polyphase path the live signal takes (FIR + heterodyne),
            // so template and signal share filter transients exactly.
            while i < raw.count {
                var re = 0.0, im = 0.0
                for k in 0..<Self.fir.count where i - k >= 0 {
                    let x = raw[i - k]
                    let c = table[(i - k) & 63]
                    re += Self.fir[k] * x * c.re
                    im += Self.fir[k] * x * c.im
                }
                out.append((re, im))
                i += Self.decimation
            }
            return out
        }
        let lowTable = carrier(23)    // 17.25 kHz
        let highTable = carrier(25)   // 18.75 kHz
        func make(_ table: [(re: Double, im: Double)], _ symbols: [Int]) -> BandState {
            let templates = symbols.map { decimatedTemplate($0, table: table) }
            let energies = templates.map { $0.reduce(0.0) { $0 + $1.re * $1.re + $1.im * $1.im } }
            return BandState(carrierTable: table, symbols: symbols, templates: templates, templateEnergy: energies)
        }
        bands = [make(lowTable, [0, 1]), make(highTable, [2, 3])]
    }

    public mutating func drainDiagnostics() -> [String] {
        defer { diagnosticsBuffer.removeAll(keepingCapacity: true) }
        return diagnosticsBuffer
    }

    // MARK: - Streaming

    public mutating func process(samples: [Float]) -> [TingEvent] {
        var events: [TingEvent] = []
        for sample in samples {
            rawRing[rawIndex & 127] = sample
            rawIndex += 1
            if rawIndex % Self.decimation == 0, rawIndex >= Self.fir.count {
                for bandIndex in bands.indices {
                    events.append(contentsOf: advanceBand(bandIndex))
                }
            }
        }
        // Lone-symbol resolution + staleness are time-driven.
        events.append(contentsOf: tick(now: now))
        if !locked, !events.isEmpty {
            diagnosticsBuffer.append("unlocked — suppressed: \(events.map(\.logDescription).joined(separator: ","))")
            events = []
        }
        return events
    }

    private var now: Double { Double(rawIndex) / configuration.sampleRate }

    /// One decimated baseband sample for one band, plus correlation.
    private mutating func advanceBand(_ bandIndex: Int) -> [TingEvent] {
        var band = bands[bandIndex]
        defer { bands[bandIndex] = band }

        var re = 0.0, im = 0.0
        for k in 0..<Self.fir.count {
            let idx = rawIndex - 1 - k
            let x = Double(rawRing[idx & 127])
            let c = band.carrierTable[idx & 63]
            re += Self.fir[k] * x * c.re
            im += Self.fir[k] * x * c.im
        }
        band.baseband.append((re, im))
        let prev = band.basebandEnergy.last ?? 0
        band.basebandEnergy.append(prev + re * re + im * im)
        // Bound memory: keep 2x template length.
        if band.baseband.count > Self.templateTaps * 2 {
            band.baseband.removeFirst(Self.templateTaps)
            band.basebandEnergy.removeFirst(Self.templateTaps)
        }
        guard band.baseband.count >= Self.templateTaps else { return [] }
        guard now - band.lastPeakAt >= configuration.refractory else { return [] }

        // Correlate both templates at the current alignment.
        let n = band.baseband.count
        let windowEnergy = (band.basebandEnergy.last ?? 0)
            - (n > Self.templateTaps ? band.basebandEnergy[n - Self.templateTaps - 1] : 0)
        guard windowEnergy > 0 else { return [] }
        var best = (corr: 0.0, symbol: -1, sibling: 0.0, level: -200.0)
        for (t, template) in band.templates.enumerated() {
            var cre = 0.0, cim = 0.0
            for m in 0..<Self.templateTaps {
                let z = band.baseband[n - Self.templateTaps + m]
                let w = template[m]
                // conj(template) * signal
                cre += w.re * z.re + w.im * z.im
                cim += w.re * z.im - w.im * z.re
            }
            let mag = (cre * cre + cim * cim).squareRoot()
            let norm = mag / (windowEnergy * band.templateEnergy[t]).squareRoot()
            if norm > best.corr {
                let sibling = best.symbol == -1 ? 0 : best.corr
                best = (norm, band.symbols[t], max(sibling, best.sibling),
                        20 * log10(max(mag / band.templateEnergy[t].squareRoot(), 1e-10)))
            } else {
                best.sibling = max(best.sibling, norm)
            }
        }

        // Rising-peak tracking: emit at the local maximum.
        if best.corr >= configuration.corrThreshold,
           best.corr * 1.0 >= best.sibling * configuration.dominance {
            if best.corr > band.trackingCorr {
                band.trackingCorr = best.corr
                band.trackingSymbol = best.symbol
                band.trackingAt = now
                band.trackingLevel = best.level
            }
            return []
        }
        if band.trackingSymbol >= 0 {
            let symbol = band.trackingSymbol
            let level = band.trackingLevel
            let at = band.trackingAt
            let corr = band.trackingCorr
            band.trackingSymbol = -1
            band.trackingCorr = 0
            band.lastPeakAt = at
            diagnosticsBuffer.append(String(format: "symbol S%d corr %.2f level %.1fdB", symbol, corr, level))
            signalMarginDB = 0.9 * (signalMarginDB ?? corr * 40) + 0.1 * corr * 40
            return handleSymbol(symbol, at: at, levelDB: level)
        }
        return []
    }

    // MARK: - Pair protocol + pilot lock (v1 semantics, tiny now)

    private mutating func handleSymbol(_ symbol: Int, at: Double, levelDB: Double) -> [TingEvent] {
        guard let pending = pendingSymbol, at - pending.at <= configuration.chirpWait else {
            pendingSymbol = (symbol, at, levelDB)
            return []
        }
        pendingSymbol = nil
        let a = pending.symbol, b = symbol
        switch (a, b) {
        case (1, 3): return acquireAndEmit(.beacon, level: pending.levelDB, at: at)
        case (3, 1): return acquireAndEmit(.beaconHeld, level: pending.levelDB, at: at)
        case (0, 2): return userEvent(.triggerDown, level: pending.levelDB)
        case (2, 0): return userEvent(.triggerUp, level: pending.levelDB)
        default:
            let delta = (b - a + 4) % 4
            switch delta {
            case 1: return userEvent(.modeChanged(mode: a + 1), level: pending.levelDB)
            case 3: return userEvent(.fxChanged(preset: nil), level: pending.levelDB)
            default:
                // Same-symbol pair = white press (the device queues its
                // mode symbol twice; serialized, so it can never
                // interleave with a beacon).
                return userEvent(.whitePress(mode: a + 1), level: pending.levelDB)
            }
        }
    }

    /// Time-driven duties: lone-symbol resolution and pilot staleness.
    private mutating func tick(now: Double) -> [TingEvent] {
        var events: [TingEvent] = []
        if let pending = pendingSymbol, now - pending.at > configuration.chirpWait {
            pendingSymbol = nil
            if pending.symbol == 1 || pending.symbol == 3, beaconIsDue(at: pending.at) {
                noteBeacon(at: pending.at)
                diagnosticsBuffer.append("lone S\(pending.symbol) on beacon cadence -> beacon(state unknown)")
                events.append(.beaconSensed)
            } else {
                // Lone symbols are NOT events in this protocol (every real
                // event is a pair; white is a same-symbol pair). A lone is
                // a degraded pair or noise: log and drop.
                diagnosticsBuffer.append("lone S\(pending.symbol) — no event (pairs only)")
            }
        }
        if locked, let last = lastBeaconAt, now - last > 3.2 * (beaconInterval ?? 2.0) {
            locked = false
            rememberedLevelDB = beaconLevelEMA
            provisionalBeacons.removeAll()
            diagnosticsBuffer.append("beacon pilot lost — decoder unlocked")
        }
        return events
    }

    private mutating func userEvent(_ event: TingEvent, level: Double) -> [TingEvent] {
        guard levelCredible(level) else {
            diagnosticsBuffer.append("\(event.logDescription) level \(String(format: "%.1f", level))dB not credible — dropped")
            return []
        }
        return [event]
    }

    private func levelCredible(_ level: Double) -> Bool {
        guard let reference = beaconLevelEMA ?? rememberedLevelDB ?? provisionalBeacons.last?.levelDB else { return true }
        return level >= reference - configuration.levelSlackDB
    }

    private mutating func acquireAndEmit(_ event: TingEvent, level: Double, at: Double) -> [TingEvent] {
        guard level >= configuration.minPlausibleLevelDB else {
            diagnosticsBuffer.append("beacon-shaped pair at \(String(format: "%.1f", level))dB below plausibility floor — ignored")
            return []
        }
        if locked {
            beaconLevelEMA = beaconLevelEMA.map { 0.8 * $0 + 0.2 * level } ?? level
            noteBeacon(at: at)
            return [event]
        }
        if let remembered = rememberedLevelDB, abs(level - remembered) <= 6 {
            locked = true
            beaconLevelEMA = remembered
            noteBeacon(at: at)
            diagnosticsBuffer.append("fast re-lock at \(String(format: "%.1f", level))dB")
            return [event]
        }
        provisionalBeacons = provisionalBeacons.filter { abs(level - $0.levelDB) <= 6 && at - $0.at < 9.5 }
        provisionalBeacons.append((at, level))
        if provisionalBeacons.count >= 3 {
            let last3 = provisionalBeacons.suffix(3).map(\.at)
            let i1 = last3[1] - last3[0], i2 = last3[2] - last3[1]
            if i1 > 1.2, i1 < 4.5, i2 > 1.2, i2 < 4.5, abs(i1 - i2) <= 0.25 * max(i1, i2) {
                locked = true
                beaconLevelEMA = provisionalBeacons.suffix(3).map(\.levelDB).reduce(0, +) / 3
                provisionalBeacons.removeAll()
                noteBeacon(at: at)
                diagnosticsBuffer.append("beacon pilot locked at \(String(format: "%.1f", beaconLevelEMA!))dB (periodic x3)")
                return [event]
            }
        }
        diagnosticsBuffer.append("provisional beacon at \(String(format: "%.1f", level))dB (\(provisionalBeacons.count) seen) — not locked yet")
        return []
    }

    private mutating func noteBeacon(at: Double) {
        if let last = lastBeaconAt {
            let interval = at - last
            if interval > 1.2, interval < 3.0 {
                beaconInterval = beaconInterval.map { 0.7 * $0 + 0.3 * interval } ?? interval
            }
        }
        lastBeaconAt = at
    }

    private func beaconIsDue(at: Double) -> Bool {
        guard let last = lastBeaconAt else { return false }
        let expected = beaconInterval ?? 2.0
        let elapsed = at - last
        for k in 1...2 where abs(elapsed - expected * Double(k)) <= 0.20 * expected {
            return true
        }
        return false
    }
}
