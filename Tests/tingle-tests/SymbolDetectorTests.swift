import Foundation
import TingleCore

/// Codeword protocol tests. Signals synthesize from SymbolSet itself
/// (the air-gap contract), timed like the device: symbols every ~29ms.

private let sr = SymbolSet.sampleRate

private func sym(_ s: Int, amplitude: Double = 0.95) -> [Float] {
    SymbolSet.samples(symbol: s).map { Float($0 * amplitude) }
}

private func gap(_ d: Double) -> [Float] { [Float](repeating: 0, count: Int(d * sr)) }

/// One codeword on the wire: 4 symbols at device tick spacing (~29ms).
private func word(_ message: SymbolSet.Message, amplitude: Double = 0.95, spacing: Double = 0.029) -> [Float] {
    var out: [Float] = []
    for (i, s) in SymbolSet.codebook[message.rawValue].enumerated() {
        out += sym(s, amplitude: amplitude)
        if i < 3 { out += gap(spacing - SymbolSet.duration) }
    }
    return out
}

/// Three periodic beacons lock the pilot (first two provisional).
private func prime(amplitude: Double = 0.95) -> [Float] {
    gap(0.5)
        + word(.beaconReleased, amplitude: amplitude) + gap(1.72)
        + word(.beaconReleased, amplitude: amplitude) + gap(1.72)
        + word(.beaconReleased, amplitude: amplitude) + gap(0.4)
}

private func decode(_ samples: [Float]) -> [TingEvent] {
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

private func user(_ samples: [Float]) -> [TingEvent] { decode(samples).filter { !isBeaconish($0) } }

func runSymbolDetectorTests() {
    // Acquisition contract: nothing until three periodic beacons.
    expectEqual(decode(gap(0.5) + word(.triggerDown) + gap(1)), [],
                "decoder: unlocked — trigger word suppressed")
    expectEqual(decode(prime()), [.beacon],
                "decoder: three periodic beacon words lock; first two provisional")

    // Fast re-lock: a detector seeded with the level a previous lock
    // settled at locks on a SINGLE beacon — this memory must survive
    // backend restarts or every wake pays the slow 3-beacon acquisition.
    var harvest = SymbolDetector()
    _ = harvest.process(samples: prime())
    let harvestedLevel = harvest.levelMemoryDB
    expect(harvestedLevel != nil, "decoder: lock leaves a level memory")
    var seeded = SymbolDetector()
    seeded.seedRememberedLevel(harvestedLevel ?? -7)
    _ = seeded.process(samples: gap(0.5) + word(.beaconReleased) + gap(1))
    expect(seeded.locked, "decoder: seeded level fast re-locks on one beacon")

    // The acquiring flag drives the scanner's dwell hold: true after a
    // provisional beacon, false once locked.
    var partial = SymbolDetector()
    _ = partial.process(samples: gap(0.5) + word(.beaconReleased) + gap(1))
    expect(partial.acquiring, "decoder: provisional beacon raises acquiring")
    expect(!harvest.acquiring, "decoder: lock clears acquiring")

    // Every message decodes. (beaconReleased word is FOUR IDENTICAL
    // symbols 29ms apart — exercises the peak-drop tracker.)
    expectEqual(user(prime() + word(.triggerDown) + gap(1)), [.triggerDown], "decoder: trigger down")
    expectEqual(user(prime() + word(.triggerUp) + gap(1)), [.triggerUp], "decoder: trigger up")
    expectEqual(user(prime() + word(.white3) + gap(1)), [.whitePress(mode: 3)], "decoder: white mode 3")
    expectEqual(user(prime() + word(.mode2) + gap(1)), [.modeChanged(mode: 2)], "decoder: mode change")
    expectEqual(user(prime() + word(.fxChanged) + gap(1)), [.fxChanged(preset: nil)], "decoder: fx word")
    expectEqual(decode(prime() + word(.beaconHeld) + gap(1)).suffix(1).map { $0 },
                [.beaconHeld], "decoder: held beacon word")

    // FEC: one corrupted symbol corrects; two kill the word.
    var oneErr: [Float] = []
    let code = SymbolSet.codebook[SymbolSet.Message.triggerDown.rawValue]
    for (i, s) in code.enumerated() {
        oneErr += sym(i == 2 ? (s + 1) % 4 : s)   // corrupt 3rd symbol
        if i < 3 { oneErr += gap(0.029 - SymbolSet.duration) }
    }
    expectEqual(user(prime() + oneErr + gap(1)), [.triggerDown],
                "decoder: single symbol error corrected (d=3 code)")
    var twoErr: [Float] = []
    for (i, s) in code.enumerated() {
        twoErr += sym(i >= 2 ? (s + 1) % 4 : s)   // corrupt 3rd+4th
        if i < 3 { twoErr += gap(0.029 - SymbolSet.duration) }
    }
    expectEqual(user(prime() + twoErr + gap(1)), [],
                "decoder: double symbol error rejected, never miscorrected")

    // Words survive back-to-back (beacon then trigger queued behind).
    expectEqual(user(prime() + word(.beaconReleased) + gap(0.03) + word(.triggerDown) + gap(1)),
                [.triggerDown], "decoder: word right behind a beacon decodes")

    // Deep SNR: quiet device (self-calibrated prime at same amplitude).
    var rng: UInt64 = 7
    func noise(_ n: Int, _ amp: Double) -> [Float] {
        (0..<n).map { _ in
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float((Double(rng >> 11) / Double(UInt64.max >> 11) * 2 - 1) * amp)
        }
    }
    let quiet = prime(amplitude: 0.006) + word(.triggerDown, amplitude: 0.006) + gap(1)
    let noisy = zip(quiet, noise(quiet.count, 0.01)).map(+)
    expectEqual(decode(noisy).filter { !isBeaconish($0) }, [.triggerDown],
                "decoder: trigger decodes at amp 0.006 under 0.01 noise")

    // Adversaries: all must be silent.
    func tone(_ f: Double, dur: Double = 0.08, amp: Double = 0.5) -> [Float] {
        (0..<Int(dur * sr)).map { Float(amp * sin(2 * .pi * f * Double($0) / sr)) }
    }
    expectEqual(user(prime() + tone(18_000) + gap(0.05) + tone(19_000) + gap(1)), [],
                "decoder: plain sine tones fire nothing")
    expectEqual(decode(noise(Int(5 * sr), 0.3)), [], "decoder: loud noise, unlocked: nothing")
    expectEqual(user(prime() + noise(Int(5 * sr), 0.3)), [], "decoder: loud noise, locked: nothing")
    let glide: [Float] = (0..<Int(2 * sr)).map { i in
        let t = Double(i) / sr
        return Float(0.3 * sin(2 * .pi * (16_000 + 2_000 * t) * t))
    }
    expectEqual(user(prime() + glide + gap(1)), [], "decoder: slow glide fires nothing")
    expectEqual(decode(noise(Int(60 * sr), 0.02)), [], "decoder: 60s noise soak never locks")
}
