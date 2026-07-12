import Foundation
import TingleCore

/// Sensitivity sweeps and adversarial false-positive corpus. Two jobs:
///
/// 1. Pin the decode floor: trigger chirps must decode down to a known
///    SNR, and quiet must never be WORSE than a pinned floor (a detector
///    change that regresses sensitivity fails here before hardware does).
/// 2. Prove silence on tone-free adversaries: speech-band sibilance,
///    HF-rich percussion-ish bursts, clicks, and program sweeps must fire
///    ZERO events at any level (phantom presses run shell commands).
///
/// This suite is the referee for any future detector rewrite: a candidate
/// must hold the floor of (1) without breaking (2).

private let sweepSampleRate = 48_000.0
private let sweepTones = [17_500.0, 18_000.0, 18_500.0, 19_000.0]

/// Deterministic noise (LCG) so failures reproduce exactly.
private struct Rand {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64.max >> 11) * 2 - 1
    }
}

private func toneBurst(_ frequency: Double, amplitude: Double) -> [Float] {
    let n = Int(0.08 * sweepSampleRate)
    let fade = Int(0.01 * sweepSampleRate)
    return (0..<n).map { i in
        var v = amplitude * sin(2 * .pi * frequency * Double(i) / sweepSampleRate)
        if i < fade { v *= 0.5 * (1 - cos(.pi * Double(i) / Double(fade))) }
        let fromEnd = n - 1 - i
        if fromEnd < fade { v *= 0.5 * (1 - cos(.pi * Double(fromEnd) / Double(fade))) }
        return Float(v)
    }
}

private func mix(_ signal: [Float], noiseAmplitude: Double, seed: UInt64) -> [Float] {
    var rng = Rand(seed: seed)
    return signal.map { $0 + Float(rng.next() * noiseAmplitude) }
}

private func quiet(_ duration: Double) -> [Float] {
    [Float](repeating: 0, count: Int(duration * sweepSampleRate))
}

private func sweepDecode(_ samples: [Float]) -> [TingEvent] {
    decodeSamples(samples)  // shared helper from AudioFixtureTests
}

private func triggerChirp(amplitude: Double) -> [Float] {
    // Self-calibration prelude at the SAME amplitude (a quiet device has
    // quiet beacons too), then the trigger pair under test.
    quiet(0.5)
        + toneBurst(sweepTones[1], amplitude: amplitude) + quiet(0.05) + toneBurst(sweepTones[3], amplitude: amplitude)
        + quiet(1.72)
        + toneBurst(sweepTones[1], amplitude: amplitude) + quiet(0.05) + toneBurst(sweepTones[3], amplitude: amplitude)
        + quiet(0.4)
        + toneBurst(sweepTones[0], amplitude: amplitude)
        + quiet(0.05) + toneBurst(sweepTones[2], amplitude: amplitude) + quiet(1)
}

private func isBeaconVariant(_ e: TingEvent) -> Bool { e == .beacon || e == .beaconHeld || e == .beaconSensed }

func runDetectorSweepTests() {
    // --- 1. Sensitivity floor -------------------------------------------
    // In broadband noise at -40dBFS (amplitude 0.01), trigger pairs must
    // decode down to tone amplitude 0.008 (~ -42dBFS, SNR ~= -2dB
    // broadband but ~+20dB in-bin). Pinned from measurement; a detector
    // regression that raises this floor fails loudly.
    let noiseAmp = 0.01
    for (i, toneAmp) in [0.5, 0.05, 0.02, 0.008].enumerated() {
        let samples = mix(triggerChirp(amplitude: toneAmp), noiseAmplitude: noiseAmp, seed: UInt64(i + 1))
        expectEqual(sweepDecode(samples).filter { !isBeaconVariant($0) }, [.triggerDown],
                    "sweep: trigger decodes at tone amp \(toneAmp) in 0.01 noise")
    }

    // Clean-line floor (no noise): far quieter still.
    expectEqual(sweepDecode(triggerChirp(amplitude: 0.002)).filter { !isBeaconVariant($0) },
                [.triggerDown],
                "sweep: trigger decodes at -54dBFS on a clean line")

    // --- 2. Adversarial corpus: ZERO events allowed ---------------------
    var adversaries: [(String, [Float])] = []

    // Broadband noise, loud.
    var rng = Rand(seed: 42)
    adversaries.append(("loud broadband noise", (0..<Int(3 * sweepSampleRate)).map { _ in Float(rng.next() * 0.5) }))

    // Sibilance-ish: bandpassed noise bursts around 6-12kHz (speech "s").
    var sib = quiet(3)
    var rng2 = Rand(seed: 7)
    for burst in 0..<6 {
        let start = Int((0.4 * Double(burst) + 0.1) * sweepSampleRate)
        var lp1 = 0.0, lp2 = 0.0
        for i in 0..<Int(0.12 * sweepSampleRate) {
            let white = rng2.next()
            lp1 += 0.55 * (white - lp1)         // ~8kHz lowpass
            lp2 += 0.25 * (lp1 - lp2)           // shape the band
            sib[start + i] = Float((lp1 - lp2) * 0.6)
        }
    }
    adversaries.append(("sibilant speech bursts", sib))

    // Percussion-ish: sharp wideband clicks with ringing HF tails.
    var perc = quiet(3)
    for hit in 0..<8 {
        let start = Int((0.35 * Double(hit) + 0.1) * sweepSampleRate)
        for i in 0..<Int(0.05 * sweepSampleRate) {
            let t = Double(i) / sweepSampleRate
            let env = exp(-t * 90)
            // Inharmonic partials near (but not on) the signal band.
            let v = env * (sin(2 * .pi * 16_300 * t) + 0.7 * sin(2 * .pi * 19_700 * t) + 0.5 * sin(2 * .pi * 11_113 * t))
            perc[start + i] = Float(v * 0.4)
        }
    }
    adversaries.append(("percussive HF hits", perc))

    // Program sweep straight through the tone band (worst case: dwells in
    // every bin briefly). Must be rejected by burst-duration/guard logic.
    let glide: [Float] = (0..<Int(2 * sweepSampleRate)).map { i in
        let t = Double(i) / sweepSampleRate
        let f = 16_000 + 2_000 * t  // 16k -> 20k over 2s
        return Float(0.3 * sin(2 * .pi * f * t))
    }
    adversaries.append(("slow sweep through the band", glide))

    for (name, samples) in adversaries {
        let events = sweepDecode(samples)
        expect(events.isEmpty, "adversary: \(name) fires nothing (got \(events.map(\.logDescription)))")
    }
}
