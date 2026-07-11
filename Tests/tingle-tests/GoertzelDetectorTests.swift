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

func runGoertzelDetectorTests() {
    expectEqual(decode(silence(0.5) + burst(tones[1]) + silence(1)),
                [.whitePress(mode: 2)], "detector: single tone = white press")
    expectEqual(decode(silence(0.5) + chirp(3, 0) + silence(1)),
                [.modeChanged(mode: 4)], "detector: mode chirp with wraparound")
    expectEqual(decode(silence(0.5) + chirp(2, 1) + silence(1)),
                [.fxChanged(preset: nil)], "detector: fx chirp")
    expectEqual(decode(silence(0.5) + chirp(0, 2) + silence(1)),
                [.triggerDown], "detector: trigger down pair")
    expectEqual(decode(silence(0.5) + chirp(2, 0) + silence(1)),
                [.triggerUp], "detector: trigger up pair")
    expectEqual(decode(silence(0.5) + chirp(1, 3) + silence(1)),
                [.beacon], "detector: released beacon")
    expectEqual(decode(silence(0.5) + chirp(3, 1) + silence(1)),
                [.beaconHeld], "detector: held beacon")
    expectEqual(decode(silence(0.5) + chirp(1, 3) + silence(0.25) + chirp(0, 2) + silence(1)),
                [.beacon, .triggerDown], "detector: beacon never enters refractory")

    let clipped = burst(tones[0], amplitude: 1.2).map { max(-1, min(1, $0)) }
    expectEqual(decode(silence(0.5) + clipped + silence(1)),
                [.whitePress(mode: 1)], "detector: clipped tone still detected")

    expectEqual(decode(silence(0.5) + burst(tones[2], duration: 0.6) + silence(1)),
                [], "detector: sustained program audio rejected")

    let noise = (0..<48_000).map { _ in Float.random(in: -0.05...0.05) }
    expectEqual(decode(noise), [], "detector: noise alone fires nothing")

    expectEqual(decode(silence(0.5) + chirp(0, 1) + silence(0.45) + chirp(1, 2) + silence(1)),
                [.modeChanged(mode: 1), .modeChanged(mode: 2)],
                "detector: rapid repeated chirps all decode (refractory)")
}
