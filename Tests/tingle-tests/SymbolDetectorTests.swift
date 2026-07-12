import Foundation
import TingleCore

/// v2 coded-symbol decoder tests. Signals are synthesized from SymbolSet
/// itself (the same source Flasher writes to the device), so these prove
/// the whole air-gap contract end to end.

private let sr = SymbolSet.sampleRate

private func sym(_ s: Int, amplitude: Double = 0.95) -> [Float] {
    SymbolSet.samples(symbol: s).map { Float($0 * amplitude) }
}

private func gap(_ d: Double) -> [Float] { [Float](repeating: 0, count: Int(d * sr)) }

private func pair(_ a: Int, _ b: Int, amplitude: Double = 0.95) -> [Float] {
    sym(a, amplitude: amplitude) + gap(0.05) + sym(b, amplitude: amplitude)
}

/// Three periodic beacons lock the pilot.
private func symPrime(amplitude: Double = 0.95) -> [Float] {
    gap(0.5)
        + pair(1, 3, amplitude: amplitude) + gap(1.72)
        + pair(1, 3, amplitude: amplitude) + gap(1.72)
        + pair(1, 3, amplitude: amplitude) + gap(0.4)
}

private func symDecode(_ samples: [Float]) -> [TingEvent] {
    var detector = SymbolDetector()
    var events: [TingEvent] = []
    var i = 0
    while i < samples.count {
        let end = min(i + 4800, samples.count)
        events += detector.process(samples: Array(samples[i..<end]))
        i = end
    }
    events += detector.process(samples: [Float](repeating: 0, count: Int(sr)))
    return events
}

private func isBeaconish(_ e: TingEvent) -> Bool { e == .beacon || e == .beaconHeld || e == .beaconSensed }

func runSymbolDetectorTests() {
    // Acquisition contract.
    expectEqual(symDecode(gap(0.5) + pair(0, 2) + gap(1)), [],
                "symbols: unlocked — trigger suppressed")
    expectEqual(symDecode(symPrime()), [.beacon],
                "symbols: three periodic beacons lock; first two provisional")

    // Every pair code decodes after lock.
    expectEqual(symDecode(symPrime() + pair(0, 2) + gap(1)).filter { !isBeaconish($0) },
                [.triggerDown], "symbols: trigger down")
    expectEqual(symDecode(symPrime() + pair(2, 0) + gap(1)).filter { !isBeaconish($0) },
                [.triggerUp], "symbols: trigger up")
    expectEqual(symDecode(symPrime() + pair(3, 0) + gap(1)).filter { !isBeaconish($0) },
                [.modeChanged(mode: 4)], "symbols: mode chirp with wraparound")
    expectEqual(symDecode(symPrime() + pair(2, 1) + gap(1)).filter { !isBeaconish($0) },
                [.fxChanged(preset: nil)], "symbols: fx chirp")
    expectEqual(symDecode(symPrime() + sym(1) + gap(1)).filter { !isBeaconish($0) },
                [.whitePress(mode: 2)], "symbols: lone symbol = white press")
    expectEqual(symDecode(symPrime() + pair(3, 1) + gap(1)).suffix(1).map { $0 },
                [.beaconHeld], "symbols: held beacon")

    // Deep SNR: the matched filter should decode far below v1's floor.
    var rng: UInt64 = 7
    func noise(_ n: Int, _ amp: Double) -> [Float] {
        (0..<n).map { _ in
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float((Double(rng >> 11) / Double(UInt64.max >> 11) * 2 - 1) * amp)
        }
    }
    let quiet = symPrime(amplitude: 0.004) + pair(0, 2, amplitude: 0.004) + gap(1)
    let noisy = zip(quiet, noise(quiet.count, 0.01)).map(+)
    expectEqual(symDecode(noisy).filter { !isBeaconish($0) }, [.triggerDown],
                "symbols: trigger decodes at amp 0.004 in 0.01 noise (-8dB broadband SNR)")

    // Adversaries: LEGACY PURE TONES must not decode (tones do not match
    // chirp templates) — the v1 waveform itself becomes an adversary.
    func tone(_ f: Double, amp: Double = 0.5) -> [Float] {
        (0..<Int(0.08 * sr)).map { Float(amp * sin(2 * .pi * f * Double($0) / sr)) }
    }
    expectEqual(symDecode(symPrime() + tone(18_000) + gap(0.05) + tone(19_000) + gap(1)).filter { !isBeaconish($0) },
                [], "symbols: legacy pure-tone pair fires nothing")

    // Broadband noise alone, locked and unlocked: silence.
    expectEqual(symDecode(noise(Int(5 * sr), 0.3)), [],
                "symbols: loud noise fires nothing (unlocked)")
    expectEqual(symDecode(symPrime() + noise(Int(5 * sr), 0.3)).filter { !isBeaconish($0) },
                [], "symbols: loud noise fires nothing (locked)")

    // Adversarial corpus (ported from the v1 referee suite).
    // Sibilance-ish bandpassed bursts.
    var sib = gap(3)
    var rng2: UInt64 = 5
    func rnd2() -> Double {
        rng2 = rng2 &* 6364136223846793005 &+ 1442695040888963407
        return Double(rng2 >> 11) / Double(UInt64.max >> 11) * 2 - 1
    }
    for burst in 0..<6 {
        let start = Int((0.4 * Double(burst) + 0.1) * sr)
        var lp1 = 0.0, lp2 = 0.0
        for i in 0..<Int(0.12 * sr) {
            lp1 += 0.55 * (rnd2() - lp1)
            lp2 += 0.25 * (lp1 - lp2)
            sib[start + i] = Float((lp1 - lp2) * 0.6)
        }
    }
    expectEqual(symDecode(symPrime() + sib).filter { !isBeaconish($0) }, [],
                "symbols: sibilant bursts fire nothing")

    // Percussive HF hits with inharmonic ringing partials.
    var perc = gap(3)
    for hit in 0..<8 {
        let start = Int((0.35 * Double(hit) + 0.1) * sr)
        for i in 0..<Int(0.05 * sr) {
            let t = Double(i) / sr
            let env = exp(-t * 90)
            let v = env * (sin(2 * .pi * 16_300 * t) + 0.7 * sin(2 * .pi * 19_700 * t) + 0.5 * sin(2 * .pi * 11_113 * t))
            perc[start + i] = Float(v * 0.4)
        }
    }
    expectEqual(symDecode(symPrime() + perc).filter { !isBeaconish($0) }, [],
                "symbols: percussive HF hits fire nothing")

    // Program glide straight through both bands. A slow glide is locally
    // chirp-like ONLY if its sweep rate matches ours (12.5kHz/s); this one
    // sweeps at 2kHz/s and must not correlate.
    let glide: [Float] = (0..<Int(2 * sr)).map { i in
        let t = Double(i) / sr
        let f = 16_000 + 2_000 * t
        return Float(0.3 * sin(2 * .pi * f * t))
    }
    expectEqual(symDecode(symPrime() + glide + gap(1)).filter { !isBeaconish($0) }, [],
                "symbols: slow glide through the band fires nothing")

    // 60s noise soak: no cold lock, no events, ever.
    expectEqual(symDecode(noise(Int(60 * sr), 0.02)), [],
                "symbols: 60s noise soak never locks or fires")
}
