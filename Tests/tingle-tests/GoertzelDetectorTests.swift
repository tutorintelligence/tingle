import Foundation
import TingleCore

private let sampleRate = 48_000.0
private let tones = [17_500.0, 18_000.0, 18_500.0, 19_000.0]

private func burst(_ frequency: Double, duration: Double = 0.08, amplitude: Double = 0.3) -> [Float] {
    let n = Int(duration * sampleRate)
    let fade = Int(0.01 * sampleRate)
    return (0..<n).map { i in
        var v = amplitude * sin(2 * .pi * frequency * Double(i) / sampleRate)
        if i < fade { v *= 0.5 * (1 - cos(.pi * Double(i) / Double(fade))) }
        let fromEnd = n - 1 - i
        if fromEnd < fade { v *= 0.5 * (1 - cos(.pi * Double(fromEnd) / Double(fade))) }
        return Float(v)
    }
}

private func silence(_ duration: Double) -> [Float] {
    [Float](repeating: 0, count: Int(duration * sampleRate))
}

private func chirp(_ a: Int, _ b: Int) -> [Float] {
    burst(tones[a]) + silence(0.05) + burst(tones[b])
}

private func decode(_ samples: [Float]) -> [TingEvent] {
    var detector = GoertzelDetector(configuration: .init(sampleRate: sampleRate, targetFrequencies: tones))
    var events: [TingEvent] = []
    var index = 0
    while index < samples.count {
        let end = min(index + 4800, samples.count)
        events += detector.process(samples: Array(samples[index..<end]))
        index = end
    }
    return events
}

/// Acquisition prelude: two cadence-consistent beacons lock the decoder
/// (the first is provisional and unemitted by design). Same amplitude as
/// the content under test — self-calibration means the whole device is
/// loud or quiet together.
private func prime(amplitude: Double = 0.3) -> [Float] {
    // Three beacons: cold acquisition demands periodic x3 (the first two
    // stay provisional and unemitted).
    silence(0.5)
        + burst(tones[1], amplitude: amplitude) + silence(0.05) + burst(tones[3], amplitude: amplitude)
        + silence(1.72)
        + burst(tones[1], amplitude: amplitude) + silence(0.05) + burst(tones[3], amplitude: amplitude)
        + silence(1.72)
        + burst(tones[1], amplitude: amplitude) + silence(0.05) + burst(tones[3], amplitude: amplitude)
        + silence(0.4)
}

private func isBeaconVariant(_ e: TingEvent) -> Bool { e == .beacon || e == .beaconHeld || e == .beaconSensed }

/// Decode after priming, returning only user-facing events.
private func decodeUser(_ samples: [Float], amplitude: Double = 0.3) -> [TingEvent] {
    decode(prime(amplitude: amplitude) + samples).filter { !isBeaconVariant($0) }
}

func runGoertzelDetectorTests() {
    // Acquisition itself: unlocked decoders emit NOTHING — not for user
    // chirps, not even for the first (provisional) beacon.
    expectEqual(decode(silence(0.5) + chirp(0, 2) + silence(1)),
                [], "detector: unlocked — trigger chirp suppressed")
    expectEqual(decode(silence(0.5) + burst(tones[1]) + silence(1)),
                [], "detector: unlocked — lone tone suppressed")
    expectEqual(decode(prime()), [.beacon],
                "detector: three periodic beacons lock; first two provisional")

    // Two level-matched pops must NOT lock (the -58dB false-lock class):
    // aperiodic third pop keeps it provisional forever.
    let pop = burst(tones[1], amplitude: 0.01) + silence(0.05) + burst(tones[3], amplitude: 0.01)
    expectEqual(decode(silence(0.5) + pop + silence(1.4) + pop + silence(3.9) + pop + silence(1)),
                [], "detector: aperiodic beacon-shaped pops never lock")

    // Sleep/wake lifecycle: pilot loss unlocks (muting line noise while
    // the ting sleeps — the 22:01-22:06 phantom-white incident); a single
    // returning beacon at the remembered level fast re-locks.
    expectEqual(decode(prime() + silence(8) + burst(tones[1], amplitude: 0.02) + silence(1)),
                [.beacon],
                "detector: unlocked after pilot loss — noise-level lone tone suppressed")
    expectEqual(decode(prime() + silence(8) + chirp(1, 3) + silence(0.3) + chirp(0, 2) + silence(1)),
                [.beacon, .beacon, .triggerDown],
                "detector: fast re-lock on one returning beacon, then events flow")

    expectEqual(decodeUser(burst(tones[1]) + silence(1)),
                [.whitePress(mode: 2)], "detector: single tone = white press")
    expectEqual(decodeUser(chirp(3, 0) + silence(1)),
                [.modeChanged(mode: 4)], "detector: mode chirp with wraparound")
    expectEqual(decodeUser(chirp(2, 1) + silence(1)),
                [.fxChanged(preset: nil)], "detector: fx chirp")
    expectEqual(decodeUser(chirp(0, 2) + silence(1)),
                [.triggerDown], "detector: trigger down pair")
    expectEqual(decodeUser(chirp(2, 0) + silence(1)),
                [.triggerUp], "detector: trigger up pair")
    expectEqual(decode(prime() + chirp(1, 3) + silence(1)).suffix(1).map { $0 },
                [.beacon], "detector: released beacon")
    expectEqual(decode(prime() + chirp(3, 1) + silence(1)).suffix(1).map { $0 },
                [.beaconHeld], "detector: held beacon")
    expectEqual(decodeUser(chirp(1, 3) + silence(0.25) + chirp(0, 2) + silence(1)),
                [.triggerDown], "detector: beacon never enters refractory")

    let clipped = burst(tones[0], amplitude: 1.2).map { max(-1, min(1, $0)) }
    expectEqual(decodeUser(clipped + silence(1)),
                [.whitePress(mode: 1)], "detector: clipped tone still detected")

    expectEqual(decodeUser(burst(tones[2], duration: 0.6) + silence(1)),
                [], "detector: sustained program audio rejected")

    let noise = (0..<48_000).map { _ in Float.random(in: -0.05...0.05) }
    expectEqual(decodeUser(noise), [], "detector: noise alone fires nothing (locked)")
    expectEqual(decode(noise), [], "detector: noise alone fires nothing (unlocked)")

    expectEqual(decodeUser(chirp(0, 1) + silence(0.45) + chirp(1, 2) + silence(1)),
                [.modeChanged(mode: 1), .modeChanged(mode: 2)],
                "detector: rapid repeated chirps all decode (refractory)")

    // Volume-level robustness (regression for fw 1.0.8's rebalanced output:
    // -35dBFS beacons fragmented into phantom whites and lost triggers).

    expectEqual(decodeUser(chirp(0, 2).map { $0 * 0.02 } + silence(1), amplitude: 0.006),
                [.triggerDown], "detector: quiet (-34dB) trigger pair still decodes")

    // A mid-burst amplitude dip must not split one burst into fragments.
    var dipped = burst(tones[1], amplitude: 0.03)
    let dipStart = Int(0.035 * sampleRate), dipEnd = Int(0.05 * sampleRate)
    for i in dipStart..<dipEnd { dipped[i] *= 0.4 }
    expectEqual(decodeUser(dipped + silence(1), amplitude: 0.03),
                [.whitePress(mode: 2)],
                "detector: quiet burst with mid-dip holds together (hysteresis)")

    // Beacon-cadence rescue: after two beacons establish the heartbeat, a
    // lone beacon-lead tone arriving on schedule is a degraded beacon
    // carrying state — NOT a phantom white press (which fires the summon
    // action). Off-cadence lone tones still decode as white presses.
    let cadence = silence(0.5) + chirp(1, 3) + silence(1.72) + chirp(1, 3) + silence(1.72) + chirp(1, 3) + silence(1.72)
    expectEqual(decode(cadence + burst(tones[3]) + silence(1)),
                [.beacon, .beaconSensed],
                "detector: lone beacon-slot tone on cadence = presence, state unknown")
    expectEqual(decode(cadence + burst(tones[1]) + silence(1)),
                [.beacon, .beaconSensed],
                "detector: lone released-lead tone on cadence = presence, state unknown")
    expectEqual(decode(cadence + silence(0.6) + burst(tones[1]) + silence(1)),
                [.beacon, .whitePress(mode: 2)],
                "detector: lone tone OFF beacon cadence stays a white press")
    expectEqual(decode(cadence + burst(tones[0]) + silence(1)),
                [.beacon, .whitePress(mode: 1)],
                "detector: non-beacon-lead lone tone on cadence stays a white press")

    // Phantom-pair regression (2026-07-11, second wave): the ting's lo-fi
    // output stage sheds faint 17.5k intermod artifacts alongside beacons;
    // one surviving the duration filter must not hijack the beacon's first
    // tone into modeChanged (this erased 209 chars of a real dictation).
    let weakSpur = burst(tones[0], amplitude: 0.008)   // ~31dB below the chirps
    expectEqual(decode(cadence + weakSpur + silence(0.02) + chirp(1, 3) + silence(1)),
                [.beacon, .beacon],
                "detector: weak artifact cannot pair with a real beacon tone")
    expectEqual(decode(cadence + weakSpur + silence(0.05) + weakSpur + silence(1)),
                [.beacon],
                "detector: two weak artifacts cannot form a phantom white press")
    // Real user chirps (beacon-loud) still classify normally after beacons.
    expectEqual(decode(cadence + chirp(0, 2) + silence(1)),
                [.beacon, .triggerDown],
                "detector: beacon-loud trigger pair unaffected by the gate")
}
