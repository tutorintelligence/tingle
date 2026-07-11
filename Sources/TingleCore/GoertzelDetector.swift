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
        /// Consecutive hit/miss windows for a tone to switch on/off (debounce).
        var onWindows: Int = 2
        var offWindows: Int = 2
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
    private let inBandProbeFrequencies: [Double]

    // Streaming state.
    private var carry: [Float] = []
    private var windowClock = 0
    private var refractoryUntil = 0
    private var tones: [ToneState]
    /// A completed valid burst awaiting either a chirp's second burst or the
    /// chirp-wait timeout (-> white press).
    private var pendingBurst: (tone: Int, endWindow: Int)?

    private struct ToneState {
        var hitStreak = 0
        var missStreak = 0
        var isOn = false
        var onStartWindow = 0
        /// Set when this tone's current activation is a beacon's second
        /// burst: its end must be ignored rather than becoming pending.
        var suppressNextBurstEnd = false
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.tones = Array(repeating: ToneState(), count: configuration.targetFrequencies.count)

        let windowDuration = Double(configuration.windowSize) / configuration.sampleRate
        self.chirpWaitWindows = max(1, Int((configuration.chirpWait / windowDuration).rounded()))
        self.refractoryWindows = max(1, Int((configuration.refractoryDuration / windowDuration).rounded()))

        // Probe grid spanning the tone band, for the median in-band level.
        let low = (configuration.targetFrequencies.min() ?? 17500) - 1000
        let high = (configuration.targetFrequencies.max() ?? 19000) + 500
        self.inBandProbeFrequencies = Array(stride(from: low, through: high, by: 250))
    }

    /// Human-readable burst/decision notes accumulated since the last drain
    /// (the host logs them at debug level so a listening-but-not-detecting
    /// session is diagnosable from Console). Only appended on burst
    /// boundaries — no per-window cost.
    private var diagnostics: [String] = []

    mutating func drainDiagnostics() -> [String] {
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

        // A pending burst with no follow-up within the chirp wait is a lone
        // tone: white press. Resolve before looking at this window's audio so
        // a stale pending can't pair with an unrelated late onset.
        if let pending = pendingBurst, now - pending.endWindow > chirpWaitWindows {
            pendingBurst = nil
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
        do {
            let probeLevels = inBandProbeFrequencies.map { powerDB(window, frequency: $0) }
            let medianLevel = Self.median(probeLevels)
            let threshold = configuration.thresholdDB
            let medianMargin = clipped ? configuration.clippedMedianMarginDB : threshold
            for (index, frequency) in configuration.targetFrequencies.enumerated() {
                let target = powerDB(window, frequency: frequency)
                let guardLow = powerDB(window, frequency: frequency - configuration.guardOffset)
                let guardHigh = powerDB(window, frequency: frequency + configuration.guardOffset)
                hits[index] = target >= guardLow + threshold
                    && target >= guardHigh + threshold
                    && target >= medianLevel + medianMargin
            }
        }

        var events: [TingEvent] = []
        for index in tones.indices {
            events.append(contentsOf: updateTone(index, hit: hits[index], now: now))
        }

        // Beacons (~2s heartbeat) never enter refractory — a real event chirp
        // can start right behind one and must still decode.
        if events.contains(where: { $0 != .beacon }) {
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
        }

        if !state.isOn, state.hitStreak >= configuration.onWindows {
            // Tone switched on. If a valid burst is pending, this onset is a
            // chirp's second burst: classify immediately (low latency; the
            // remainder of the burst is absorbed by refractory).
            state.isOn = true
            state.onStartWindow = now - configuration.onWindows + 1
            if let pending = pendingBurst {
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
                    // Fixed pair: beacon heartbeat (~2s). Internal liveness
                    // signal — must NOT enter refractory, or it could swallow
                    // the first burst of a real event chirp right behind it.
                    // The tail of this second burst is suppressed instead.
                    event = .beacon
                    state.suppressNextBurstEnd = true
                case (3, 1):
                    // Fixed pair: beacon while the handle is HELD (state-
                    // carrying heartbeat; like .beacon, never refractory).
                    event = .beaconHeld
                    state.suppressNextBurstEnd = true
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
            } else {
                diagnostics.append("burst tone=\(index + 1) \(duration)w -> pending")
                pendingBurst = (tone: index, endWindow: endWindow)
            }
            // TODO: overlapping bursts (heavy FX tails stretching the first
            // tone past the second's onset) end up here with pendingBurst
            // already set and are dropped; revisit after on-hardware tuning.
        }

        tones[index] = state
        return events
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
