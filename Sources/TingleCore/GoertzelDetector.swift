import Foundation

/// Pure-Swift tone detection pipeline. No AVFoundation dependencies so it can
/// be unit-tested with synthetic buffers.
///
/// Two layers:
///
/// 1. Goertzel window analysis — batches are subdivided into fixed windows of
///    `windowSize` samples (carry-over across batches). A tone "hits" a
///    window when its target bin is >= `thresholdDB` above BOTH guard bins
///    (at +/- `guardOffset` Hz) AND above the median in-band level.
/// 2. Burst tracking + chirp state machine, decoding the flashed device's
///    signaling (device/tingle_main.py, event engine v2 — the tone WAVs are
///    120ms bursts, one per slot; `spl.trigger(-1, slot, False)` cannot stop
///    a oneshot sample, so the device sequences whole bursts with gaps):
///      - single burst of tone N            -> whitePress(N+1) (stock playback)
///      - burst N then burst (N+1)%4        -> modeChanged(N+1) (green)
///      - burst N then burst (N-1)%4        -> fxChanged(nil) (orange; the
///        preset number is not recoverable over audio)
///      - fixed pair burst 0 then burst 2   -> triggerDown (handle squeezed)
///      - fixed pair burst 2 then burst 0   -> triggerUp (handle released)
///        (+2-apart pairs are unreachable by the relative +1/-1 mode/fx
///        encodings, so decoding stays collision-free)
///    The second burst of a chirp is triggered ~200ms after the first
///    (~80ms gap after the 120ms tone), so a lone burst is resolved as a
///    white press after `chirpWait` with no follow-up.
///
/// Every emitted event is followed by a refractory period during which all
/// state is held reset (guards against FX tails — delay/reverb — retriggering
/// and swallows the remainder of a chirp's second burst).
public struct GoertzelDetector {
    public struct Configuration {
        var sampleRate: Double
        /// Target frequencies in slot order (tone index n = slot n = mode n+1).
        var targetFrequencies: [Double]
        var guardOffset: Double = 250
        var thresholdDB: Double = 8
        /// Hysteresis (Schmitt trigger): once a tone is ON, it keeps hitting
        /// while its margin stays above this lower bar. Starting a burst is
        /// strict; sustaining one is lenient — marginal-SNR bursts (quiet
        /// volume knob, lossy cable) hold together instead of fragmenting.
        var sustainDB: Double = 4
        /// Consecutive hit/miss windows for a tone to switch on/off (debounce).
        var onWindows: Int = 2
        /// 3 tolerates a single flickering window mid-burst at marginal SNR
        /// (was 2; costs 20ms of burst-end latency, which chirpWait absorbs).
        var offWindows: Int = 3
        /// Valid burst duration bounds, in windows. The flashed tones are
        /// 120ms (~6 windows at 20ms/window); shorter activations are clicks,
        /// longer ones are program audio — both rejected.
        var minBurstWindows: Int = 3
        var maxBurstWindows: Int = 15   // 120ms legacy tones = 6 windows; 80ms = 4
        /// After a valid burst ends, how long to wait for a chirp's second
        /// burst before resolving the first as a white press. The second
        /// burst's onset arrives ~80ms after the first ends; 200ms is ample
        /// margin and keeps white-press action latency at ~320ms.
        var chirpWait: Double = 0.2
        /// Kept short: chirp classification + tail suppression already prevent
        /// double-fires, and a long refractory swallows the first burst of the
        /// NEXT chirp when a repeatable action is pressed rapidly.
        var refractoryDuration: Double = 0.15
        /// Samples above this absolute value mark a window as near-clipping.
        /// Clipped windows are NOT blanket-rejected — the tones themselves
        /// can clip the capture on hot line-in gain (verified on hardware:
        /// every tone window of a real recording was clipped). Instead they
        /// must clear `clippedMedianMarginDB` over the in-band median.
        var clipLevel: Float = 0.98
        /// Absolute plausibility floor for beacon acquisition (uncalibrated
        /// power dB): measured today, real beacons span ~+12..+31 across
        /// every configuration seen (including the broken-quiet fw-1.0.8 +
        /// 0.30-amplitude regression), while line-noise pops span -25..-64.
        /// -10 splits the gap with ~15dB margin both ways. Relative gates
        /// still do the fine discrimination; this kills the "locked onto
        /// the noise floor" class outright.
        var minPlausibleLevelDB: Double = -10
        /// Extra narrowband dominance (dB over the in-band median) demanded
        /// of clipped windows, replacing `thresholdDB` for the median test.
        /// Decodes clipped tones while still suppressing clipped loud speech.
        var clippedMedianMarginDB: Double = 20
        /// Window length in samples, chosen so bins land near the targets:
        /// 50Hz bins (N = 960 at 48kHz; 17.5/18/18.5/19k = bins 350/360/370/380).
        var windowSize: Int

        public init(sampleRate: Double, targetFrequencies: [Double]) {
            self.sampleRate = sampleRate
            self.targetFrequencies = targetFrequencies
            self.windowSize = max(64, Int((sampleRate / 50.0).rounded()))
        }
    }

    public let configuration: Configuration

    // Derived, in window units.
    private let chirpWaitWindows: Int
    private let refractoryWindows: Int

    // Streaming state.
    private var carry: [Float] = []
    /// Per-bin noise floors (dB), tracked over time with asymmetric EMA:
    /// fast to follow the floor down, slow to creep up, and never learning
    /// from windows where the bin is excited (tones must not raise their
    /// own floor). This replaces the per-window across-band median as the
    /// noise reference — the floor adapts to ANY volume level and any
    /// stationary interference without a tuned constant.
    private var targetFloors: [Double] = []
    private var windowClock = 0
    private var refractoryUntil = 0
    private var tones: [ToneState]
    /// A completed valid burst awaiting either a chirp's second burst or the
    /// chirp-wait timeout (-> white press).
    private var pendingBurst: (tone: Int, endWindow: Int, marginDB: Double, levelDB: Double)?
    /// Beacon cadence tracking: beacons are periodic (~1.75-2s), so a lone
    /// beacon-slot tone arriving on schedule is a beacon that lost its
    /// second tone — never a white press (phantom whites fired the summon
    /// action at low volume, 2026-07-11).
    private var lastBeaconWindow: Int?
    private var beaconIntervalWindows: Double?
    /// EMA of beacon first-tone LEVELS (raw dB, not margins — margins
    /// inflate against near-silent floors): the device's heartbeat
    /// continuously calibrates "how loud a real chirp is right now". A
    /// burst claiming to be a user event must be comparably loud —
    /// artifacts and noise pops run 10-20dB colder than real output.
    private var beaconLevelEMA: Double?
    /// Pilot acquisition: NO events are emitted until the device is
    /// LOCKED — two beacons on plausible cadence at consistent level
    /// (noise cannot fake that; a single fake pair once poisoned the
    /// level EMA with a -64dB reference and let pure line noise fire
    /// white presses while the ting was asleep, 2026-07-11 22:01-22:06).
    /// Staleness (no beacon for ~3 intervals: device asleep/unplugged)
    /// drops the lock, muting the decoder until the pilot returns. A
    /// remembered level allows single-beacon fast re-lock after sleep.
    private(set) var locked = false
    /// Cold acquisition requires THREE beacons: consistent level AND
    /// periodic spacing (interval1 ~= interval2). Two level-matched noise
    /// pops occur over minutes on a dead line (observed: a -58dB false
    /// lock, 2026-07-11 22:51); three on a regular clock do not — the
    /// heartbeat's periodicity is the one signature noise cannot fake.
    private var provisionalBeacons: [(window: Int, levelDB: Double)] = []
    private var rememberedLevelDB: Double?
    /// Best available "how loud is the device" reference: the locked EMA,
    /// else the last locked level (sleep), else the provisional sighting
    /// (bootstrap) — so credibility gates work during acquisition too.
    private var levelReference: Double? {
        beaconLevelEMA ?? rememberedLevelDB ?? provisionalBeacons.last?.levelDB
    }
    /// EMA of burst detection margins (dB over the strictest criterion);
    /// chronically low = the user should raise the ting's volume knob.
    public private(set) var signalMarginDB: Double?

    private struct ToneState {
        var hitStreak = 0
        var missStreak = 0
        var isOn = false
        var onStartWindow = 0
        /// Sum/count of detection margins over the burst's hit windows.
        var marginSum = 0.0
        var marginCount = 0
        /// Sum of raw target levels (dB) over hit windows: margins inflate
        /// against near-silent floors, so "is this as loud as real chirps"
        /// must compare LEVELS, not margins.
        var levelSum = 0.0
        /// Set when this tone's current activation is a beacon's second
        /// burst: its end must be ignored rather than becoming pending.
        var suppressNextBurstEnd = false
        /// Last window in which a guard bin (not the target) was hot for
        /// this tone — the signature of a tone MOVING through the band.
        var lastGuardHotWindow = -1000
        /// Last window this tone was hitting/on — used to discount guard
        /// bins polluted by an ADJACENT target tone (device tones sit
        /// 500Hz apart, so neighbors share a guard bin at the midpoint).
        var lastActiveWindow = -1000
        /// Consecutive guard-hot windows: a glide sustains guard energy;
        /// a noise spike lasts one window and must not arm the veto.
        var guardHotStreak = 0
        /// Burst started with recent guard activity: program audio gliding
        /// into the bin, not a chirp appearing from silence.
        var taintedByApproach = false
        /// Running peak (dB) of the current burst: the sustain hysteresis
        /// is bounded to peak-12dB so noise flicker near the floor cannot
        /// stretch a burst past its true end (a real tone's plateau is
        /// flat; its end is a >20dB cliff).
        var peakDB = -200.0
    }

    /// Per-window margin tracing for the --decode harness (set
    /// TINGLE_DECODE_TRACE=1): prints every window's per-tone margins.
    /// Diagnostic only — costs a dictionary lookup per window when unset.
    private let traceWindows = ProcessInfo.processInfo.environment["TINGLE_DECODE_TRACE"] != nil

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.tones = Array(repeating: ToneState(), count: configuration.targetFrequencies.count)

        let windowDuration = Double(configuration.windowSize) / configuration.sampleRate
        self.chirpWaitWindows = max(1, Int((configuration.chirpWait / windowDuration).rounded()))
        self.refractoryWindows = max(1, Int((configuration.refractoryDuration / windowDuration).rounded()))

    }

    /// Human-readable burst/decision notes accumulated since the last drain
    /// (the host logs them at debug level so a listening-but-not-detecting
    /// session is diagnosable from Console). Only appended on burst
    /// boundaries — no per-window cost.
    private var diagnostics: [String] = []

    public mutating func drainDiagnostics() -> [String] {
        defer { diagnostics.removeAll(keepingCapacity: true) }
        return diagnostics
    }

    /// Process a batch of mono samples. Returns the events that fired.
    public mutating func process(samples: [Float]) -> [TingEvent] {
        carry.append(contentsOf: samples)

        var events: [TingEvent] = []
        let n = configuration.windowSize
        var start = 0
        while carry.count - start >= n {
            events.append(contentsOf: analyzeWindow(at: start))
            start += n
        }
        carry.removeFirst(start)
        return events
    }

    // MARK: - Per-window state machine

    private mutating func analyzeWindow(at start: Int) -> [TingEvent] {
        let n = configuration.windowSize
        let window = carry[start ..< start + n]
        windowClock += 1
        let now = windowClock

        if now <= refractoryUntil {
            return []
        }

        // Lock staleness: the pilot went quiet (sleep/unplug/jack pulled).
        if locked, let last = lastBeaconWindow {
            let windowDuration = Double(configuration.windowSize) / configuration.sampleRate
            let expected = beaconIntervalWindows ?? (2.0 / windowDuration)
            if Double(now - last) > 3.2 * expected {
                locked = false
                rememberedLevelDB = beaconLevelEMA
                provisionalBeacons.removeAll()
                diagnostics.append("beacon pilot lost — decoder unlocked")
            }
        }

        // A pending burst with no follow-up within the chirp wait is a lone
        // tone: white press. Resolve before looking at this window's audio so
        // a stale pending can't pair with an unrelated late onset.
        if let pending = pendingBurst, now - pending.endWindow > chirpWaitWindows {
            pendingBurst = nil
            // Beacon-cadence rescue: beacon chirps lead with tone 1
            // (released) or tone 3 (held). A lone one of those arriving
            // when a beacon is DUE is a beacon whose second tone drowned —
            // deliver the state it carries instead of a phantom white.
            if pending.tone == 1 || pending.tone == 3, beaconIsDue(at: pending.endWindow) {
                noteBeacon(at: pending.endWindow)
                // State is ambiguous from one tone: a released-beacon's
                // SECOND tone (3) looks exactly like a held-beacon's FIRST.
                // Deliver presence without state — a guessed state would
                // feed the trigger reconciler false edges.
                diagnostics.append("lone burst tone=\(pending.tone + 1) on beacon cadence -> beacon(state unknown)")
                return locked ? [.beaconSensed] : []
            }
            // Lone bursts landing right behind a beacon are the marginal-SNR
            // phantom class (noise splatter off the beacon tones, observed
            // as self-firing white presses at -35dBFS): demand a healthy
            // margin there. Real presses at sane volume clear this easily.
            if let last = lastBeaconWindow,
               Double(pending.endWindow - last) * Double(configuration.windowSize) / configuration.sampleRate < 0.6,
               pending.marginDB < configuration.thresholdDB + 4 {
                diagnostics.append("lone burst tone=\(pending.tone + 1) weak (\(String(format: "%.1f", pending.marginDB))dB) right after beacon — dropped")
                return []
            }
            // Self-calibrated strength gate: a real white press is as loud
            // as the beacons the device has been sending. Well below that =
            // noise pop, and firing an action on it runs shell commands.
            if let reference = levelReference, pending.levelDB < reference - 10 {
                diagnostics.append("lone burst tone=\(pending.tone + 1) level \(String(format: "%.1f", pending.levelDB))dB << beacon level \(String(format: "%.1f", reference))dB — dropped")
                return []
            }
            guard locked else {
                diagnostics.append("lone burst tone=\(pending.tone + 1) suppressed (not locked)")
                return []
            }
            diagnostics.append("lone burst tone=\(pending.tone + 1) -> whitePress")
            enterRefractory(now: now)
            return [.whitePress(mode: pending.tone + 1)]
        }

        // Clipped windows are NOT rejected outright: the tones themselves may
        // clip the capture on hot line-in gain (0.85-amplitude tones × 2VRMS
        // ting output — verified on real recordings). Instead a clipped
        // window must show much stronger narrowband dominance over the
        // in-band median, which still suppresses clipped-loud-speech false
        // positives while decoding clipped tones.
        var peak: Float = 0
        for sample in window {
            peak = max(peak, abs(sample))
        }
        let clipped = peak >= configuration.clipLevel

        var hits = [Bool](repeating: false, count: tones.count)
        var margins = [Double](repeating: -200, count: tones.count)
        do {
            let floorMargin = clipped
                ? configuration.clippedMedianMarginDB - configuration.thresholdDB
                : 0
            for (index, frequency) in configuration.targetFrequencies.enumerated() {
                let target = powerDB(window, frequency: frequency)
                let guardLow = powerDB(window, frequency: frequency - configuration.guardOffset)
                let guardHigh = powerDB(window, frequency: frequency + configuration.guardOffset)
                // Track the per-bin noise floor (skip excited windows).
                if targetFloors.count <= index {
                    targetFloors.append(target)
                }
                if target < targetFloors[index] + 3 {
                    targetFloors[index] = 0.9 * targetFloors[index] + 0.1 * target
                } else {
                    targetFloors[index] += 0.02   // creep up ~1dB/s: recovers from level shifts
                }
                // Margin over the strictest criterion: the guard bins give
                // frequency selectivity (and wideband rejection — wideband
                // energy raises guards as much as the target); the bin's own
                // tracked floor gives level adaptivity. Clipped windows must
                // clear a larger floor margin, as with the old median rule.
                //
                // Adjacent DEVICE tones are 500Hz apart and share a guard
                // bin at the midpoint: when the neighbor target was active
                // within the last ~3 windows, that guard is measuring our
                // own protocol, not interference — discount it (fw 1.0.8's
                // tighter chirp spacing made back-to-back tones overlap
                // guard windows; this ate real triggerUp chirps that
                // followed a beacon).
                // "Recently but not currently": the discount exists for
                // SEQUENTIAL protocol tones (neighbor just ended, we
                // start). A neighbor hitting in this same window means its
                // sidelobes are live at our guard right now — that guard
                // must stay armed or the neighbor's leakage registers as
                // a burst on our bin.
                let lowRecent = windowClock - (index > 0 ? tones[index - 1].lastActiveWindow : -1000)
                let highRecent = windowClock - (index < tones.count - 1 ? tones[index + 1].lastActiveWindow : -1000)
                var lowPolluted = lowRecent >= 1 && lowRecent <= 3
                var highPolluted = highRecent >= 1 && highRecent <= 3
                // Sequential protocol tones only ever pollute ONE side;
                // BOTH neighbors recently active = broadband energy, which
                // is exactly what guards exist to reject — keep them.
                if lowPolluted && highPolluted {
                    lowPolluted = false
                    highPolluted = false
                }
                var criteria = [target - targetFloors[index] - floorMargin]
                if !lowPolluted { criteria.append(target - guardLow) }
                if !highPolluted { criteria.append(target - guardHigh) }
                let margin = criteria.min()!
                margins[index] = margin
                // Schmitt trigger: strict to start, lenient to sustain —
                // but sustain is bounded to the burst's own peak so noise
                // can't stretch a burst past the tone's actual end.
                let bar = tones[index].isOn ? configuration.sustainDB : configuration.thresholdDB
                hits[index] = margin >= bar
                    && (!tones[index].isOn || target >= tones[index].peakDB - 12)
                if hits[index] {
                    tones[index].lastActiveWindow = windowClock
                    tones[index].peakDB = max(tones[index].peakDB, target)
                }
                // Guard bins DOMINATING the target = energy centered off-bin
                // moving through the neighborhood (program-audio glide). A
                // real tone always beats its own sidelobe leakage, and mere
                // noise flutter fails the 6dB dominance test.
                if !hits[index],
                   max(guardLow, guardHigh) >= targetFloors[index] + configuration.thresholdDB,
                   max(guardLow, guardHigh) >= target + 6 {
                    tones[index].guardHotStreak += 1
                    if tones[index].guardHotStreak >= 2 {
                        tones[index].lastGuardHotWindow = windowClock
                    }
                } else {
                    tones[index].guardHotStreak = 0
                }
                if hits[index] {
                    // Track detection health (EMA): chronically thin margins
                    // mean the volume knob is too low for reliable decode.
                    signalMarginDB = 0.9 * (signalMarginDB ?? margin) + 0.1 * margin
                    tones[index].marginSum += margin
                    tones[index].marginCount += 1
                    tones[index].levelSum += target
                }
            }
        }

        if traceWindows {
            let desc = margins.enumerated().map { i, m in
                String(format: "%d:%@%.0f", i + 1, hits[i] ? "*" : " ", m)
            }.joined(separator: " ")
            diagnostics.append("w\(now) [\(desc)]")
        }

        var events: [TingEvent] = []
        for index in tones.indices {
            events.append(contentsOf: updateTone(index, hit: hits[index], now: now))
        }
        if !locked, !events.isEmpty {
            diagnostics.append("unlocked — suppressed: \(events.map(\.logDescription).joined(separator: ","))")
            events = []
        }

        // Beacons (~2s heartbeat) never enter refractory — a real event chirp
        // can start right behind one and must still decode. ALL beacon
        // variants: the exemption once covered only .beacon, so every
        // held-state heartbeat (i.e. during dictation) blanked 150ms and
        // ate release chirps that followed it (found via TINGLE_DECODE_TRACE
        // on a real recording, 2026-07-11).
        let isBeaconVariant: (TingEvent) -> Bool = { $0 == .beacon || $0 == .beaconHeld || $0 == .beaconSensed }
        if events.contains(where: { !isBeaconVariant($0) }) {
            enterRefractory(now: now)
        }
        return events
    }

    private mutating func updateTone(_ index: Int, hit: Bool, now: Int) -> [TingEvent] {
        var state = tones[index]
        var events: [TingEvent] = []

        if hit {
            state.hitStreak += 1
            state.missStreak = 0
        } else {
            state.missStreak += 1
            state.hitStreak = 0
            if !state.isOn {
                // Not in a burst: a miss ends any hit streak, so the
                // accumulators must restart — otherwise stale low-level
                // pops from minutes ago poison the next burst's level
                // average (observed: real beacons reading 28dB colder
                // than they were).
                state.marginSum = 0
                state.marginCount = 0
                state.levelSum = 0
                state.peakDB = -200
            }
        }

        if !state.isOn, state.hitStreak >= configuration.onWindows {
            // Tone switched on. If a valid burst is pending, this onset is a
            // chirp's second burst: classify immediately (low latency; the
            // remainder of the burst is absorbed by refractory).
            state.isOn = true
            state.onStartWindow = now - configuration.onWindows + 1
            state.taintedByApproach = now - state.lastGuardHotWindow <= 4
            // Overlap race (fw 1.0.8 shrank inter-tone gaps to ~34ms): this
            // onset can be confirmed BEFORE the previous tone's end (which
            // needs offWindows of misses). If no pending exists but another
            // tone is still nominally on with a valid-length, credible
            // burst, close it now — its end confirmation is pure latency —
            // so the pair classifies instead of decaying into a lone white.
            if pendingBurst == nil {
                for other in tones.indices where other != index && tones[other].isOn {
                    var otherState = tones[other]
                    let duration = now - otherState.onStartWindow
                    let level = otherState.peakDB
                    let credible = beaconLevelEMA.map { level >= $0 - 10 } ?? true
                    if duration >= configuration.minBurstWindows,
                       duration <= configuration.maxBurstWindows,
                       !otherState.suppressNextBurstEnd,
                       !otherState.taintedByApproach,
                       credible {
                        let margin = otherState.marginCount > 0 ? otherState.marginSum / Double(otherState.marginCount) : 0
                        diagnostics.append("burst tone=\(other + 1) \(duration)w closed early (overlap with tone=\(index + 1) onset)")
                        pendingBurst = (tone: other, endWindow: now - 1, marginDB: margin, levelDB: level)
                        otherState.isOn = false
                        otherState.marginSum = 0
                        otherState.marginCount = 0
                        otherState.levelSum = 0
                        otherState.peakDB = -200
                        tones[other] = otherState
                        break
                    }
                }
            }
            if let pending = pendingBurst {
                // The incoming onset must be device-loud too: a faint
                // artifact riding beside a real chirp must not consume the
                // credible pending — the real partner tone is right behind
                // it and still pairs correctly. Peak (not average): onset
                // windows straddle the tone start and average low; -13dB
                // allows a partial first window while artifacts (~20dB
                // colder) still fail.
                if let reference = levelReference, state.peakDB < reference - 13 {
                    diagnostics.append("onset tone=\(index + 1) peak \(String(format: "%.1f", state.peakDB))dB << beacon \(String(format: "%.1f", reference))dB — not consuming pending")
                    tones[index] = state
                    return events
                }
                pendingBurst = nil
                let event: TingEvent
                switch (pending.tone, index) {
                case (0, 2):
                    // Fixed pair: handle squeezed (push-to-talk on).
                    event = .triggerDown
                case (2, 0):
                    // Fixed pair: handle released.
                    event = .triggerUp
                case (1, 3):
                    guard acquire(pendingLevel: pending.levelDB, at: now) else {
                        // Provisional: unemitted, but this IS a beacon pair —
                        // its second tone's tail must not become pending.
                        state.suppressNextBurstEnd = true
                        tones[index] = state
                        return events
                    }
                    // Fixed pair: beacon heartbeat (~2s). Internal liveness
                    // signal — must NOT enter refractory, or it could swallow
                    // the first burst of a real event chirp right behind it.
                    // The tail of this second burst is suppressed instead.
                    event = .beacon
                    state.suppressNextBurstEnd = true
                    noteBeacon(at: now)
                case (3, 1):
                    guard acquire(pendingLevel: pending.levelDB, at: now) else {
                        state.suppressNextBurstEnd = true
                        tones[index] = state
                        return events
                    }
                    // Fixed pair: beacon while the handle is HELD (state-
                    // carrying heartbeat; like .beacon, never refractory).
                    event = .beaconHeld
                    state.suppressNextBurstEnd = true
                    noteBeacon(at: now)
                default:
                    let delta = (index - pending.tone + 4) % 4
                    switch delta {
                    case 1:
                        // First tone = new sam_pos, second = (sam_pos+1)%4.
                        event = .modeChanged(mode: pending.tone + 1)
                    case 3:
                        // Second = (sam_pos-1)%4; preset unknown over audio.
                        event = .fxChanged(preset: nil)
                    default:
                        // Not a chirp code (e.g. a rapid second white press).
                        // Resolve the first burst; the new one dies in refractory.
                        event = .whitePress(mode: pending.tone + 1)
                    }
                }
                diagnostics.append("chirp pair (\(pending.tone),\(index)) -> \(event.logDescription)")
                events.append(event)
            }
        } else if state.isOn, state.missStreak >= configuration.offWindows {
            // Tone switched off; a duration-valid burst becomes pending.
            state.isOn = false
            let endWindow = now - configuration.offWindows + 1
            let duration = endWindow - state.onStartWindow
            if state.suppressNextBurstEnd {
                // Tail of a beacon's second burst (real events use refractory
                // for this; beacons must not). Never becomes pending.
                state.suppressNextBurstEnd = false
                diagnostics.append("burst tone=\(index + 1) \(duration)w suppressed (beacon tail)")
            } else if duration < configuration.minBurstWindows {
                diagnostics.append("burst tone=\(index + 1) \(duration)w rejected (too short, min \(configuration.minBurstWindows)w)")
            } else if duration > configuration.maxBurstWindows {
                diagnostics.append("burst tone=\(index + 1) \(duration)w rejected (too long, max \(configuration.maxBurstWindows)w — program audio?)")
            } else if pendingBurst != nil {
                diagnostics.append("burst tone=\(index + 1) \(duration)w dropped (pending burst already waiting)")
            } else if locked, state.taintedByApproach,
                      !(beaconLevelEMA != nil && state.peakDB >= beaconLevelEMA! - 10) {
                // (Unlocked: no events fire anyway, and taint here would
                // starve acquisition — its cadence+level consistency is
                // the gate while unlocked.)
                // A glide that entered via the guard bins can complete a
                // "burst" but must never become pending (lone bursts run
                // actions) — UNLESS it is beacon-loud: a real chirp tone
                // right after an adjacent real tone (e.g. triggerUp behind
                // a beacon) lights guards via sidelobes and must not be
                // vetoed. Chirp SECOND tones classify at onset and never
                // reach here.
                diagnostics.append("burst tone=\(index + 1) \(duration)w rejected (moving tone — guards hot before onset)")
            } else {
                let avgMargin = state.marginCount > 0 ? state.marginSum / Double(state.marginCount) : 0
                // Peak, not average: stretched bursts at low SNR average in
                // noise windows and swing 10dB burst-to-burst; the max
                // window tracks the tone's true level stably.
                let avgLevel = state.peakDB
                if let reference = levelReference, avgLevel < reference - 10 {
                    // Too quiet to be the device (beacons prove its real
                    // output level): artifact — never becomes pending, so
                    // it can't squat the slot while a real chirp arrives.
                    diagnostics.append("burst tone=\(index + 1) \(duration)w level \(String(format: "%.1f", avgLevel))dB << beacon \(String(format: "%.1f", reference))dB — ignored")
                } else {
                    diagnostics.append("burst tone=\(index + 1) \(duration)w margin \(String(format: "%.1f", avgMargin))dB level \(String(format: "%.1f", avgLevel))dB -> pending")
                    pendingBurst = (tone: index, endWindow: endWindow, marginDB: avgMargin, levelDB: avgLevel)
                }
            }
            state.marginSum = 0
            state.marginCount = 0
            state.levelSum = 0
            state.peakDB = -200
            // TODO: overlapping bursts (heavy FX tails stretching the first
            // tone past the second's onset) end up here with pendingBurst
            // already set and are dropped; revisit after on-hardware tuning.
        }

        tones[index] = state
        return events
    }

    /// Beacon acquisition: returns true when this beacon may be emitted
    /// (locked, locking now, or fast re-lock); false while provisional.
    private mutating func acquire(pendingLevel: Double, at window: Int) -> Bool {
        guard pendingLevel >= configuration.minPlausibleLevelDB else {
            diagnostics.append("beacon-shaped burst at \(String(format: "%.1f", pendingLevel))dB below plausibility floor — ignored")
            return false
        }
        if locked {
            beaconLevelEMA = beaconLevelEMA.map { 0.8 * $0 + 0.2 * pendingLevel } ?? pendingLevel
            return true
        }
        // Fast re-lock: the device we knew came back at its known level.
        if let remembered = rememberedLevelDB, abs(pendingLevel - remembered) <= 6 {
            locked = true
            beaconLevelEMA = remembered
            diagnostics.append("fast re-lock at \(String(format: "%.1f", pendingLevel))dB")
            return true
        }
        // Cold acquisition: three beacons at consistent level with
        // PERIODIC spacing. Drop provisionals that stopped fitting.
        let windowDuration = Double(configuration.windowSize) / configuration.sampleRate
        provisionalBeacons = provisionalBeacons.filter {
            abs(pendingLevel - $0.levelDB) <= 6
                && Double(window - $0.window) * windowDuration < 9.5
        }
        provisionalBeacons.append((window: window, levelDB: pendingLevel))
        if provisionalBeacons.count >= 3 {
            let last3 = provisionalBeacons.suffix(3)
            let w = last3.map(\.window)
            let i1 = Double(w[w.startIndex + 1] - w[w.startIndex]) * windowDuration
            let i2 = Double(w[w.startIndex + 2] - w[w.startIndex + 1]) * windowDuration
            if i1 > 1.2, i1 < 4.5, i2 > 1.2, i2 < 4.5, abs(i1 - i2) <= 0.25 * max(i1, i2) {
                locked = true
                beaconLevelEMA = last3.map(\.levelDB).reduce(0, +) / 3
                provisionalBeacons.removeAll()
                diagnostics.append("beacon pilot locked at \(String(format: "%.1f", beaconLevelEMA!))dB (periodic x3)")
                return true
            }
        }
        diagnostics.append("provisional beacon at \(String(format: "%.1f", pendingLevel))dB (\(provisionalBeacons.count) seen) — not locked yet")
        return false
    }

    /// Beacon bookkeeping for the cadence rescue.
    private mutating func noteBeacon(at window: Int) {
        if let last = lastBeaconWindow {
            let interval = Double(window - last)
            let windowDuration = Double(configuration.windowSize) / configuration.sampleRate
            // Only learn plausible heartbeat intervals (1.2-3s).
            if interval * windowDuration > 1.2, interval * windowDuration < 3.0 {
                beaconIntervalWindows = beaconIntervalWindows.map { 0.7 * $0 + 0.3 * interval } ?? interval
            }
        }
        lastBeaconWindow = window
    }

    private func beaconIsDue(at window: Int) -> Bool {
        guard let last = lastBeaconWindow else { return false }
        let windowDuration = Double(configuration.windowSize) / configuration.sampleRate
        let expected = beaconIntervalWindows ?? (2.0 / windowDuration)
        let elapsed = Double(window - last)
        // Due = within +/-20% of the expected next heartbeat (or a missed
        // one: check modulo up to 2 periods for a single dropped beacon).
        for k in 1...2 {
            let target = expected * Double(k)
            if abs(elapsed - target) <= 0.20 * expected { return true }
        }
        return false
    }

    private mutating func enterRefractory(now: Int) {
        refractoryUntil = now + refractoryWindows
        pendingBurst = nil
        for index in tones.indices {
            tones[index] = ToneState()
        }
    }

    // MARK: - DSP

    /// Goertzel power (dB, uncalibrated) at the bin nearest `frequency`.
    private func powerDB(_ window: ArraySlice<Float>, frequency: Double) -> Double {
        let n = Double(window.count)
        let k = (n * frequency / configuration.sampleRate).rounded()
        let omega = 2.0 * Double.pi * k / n
        let coefficient = 2.0 * cos(omega)

        var s1 = 0.0
        var s2 = 0.0
        for sample in window {
            let s0 = Double(sample) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        return 10.0 * log10(max(power, 1e-12))
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return -120 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
