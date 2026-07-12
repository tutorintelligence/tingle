import Foundation
import TingleCore

/// Golden-corpus tests: real line-in recordings from hardware, with pinned
/// expected event sequences. These clips were captured 2026-07-11 during
/// the fw-1.0.8 level regression — beacons at ~-35dBFS with the noise
/// floor close behind. The un-hardened detector fired phantom white
/// presses (self-summoning agent) and dropped beacon halves on exactly
/// this material; the pinned expectations are the hardened behavior.
///
/// To add a fixture: record the line-in (`ffmpeg -f avfoundation -i :N`),
/// trim + mono it, decode with `swift run tingle-tests --decode file.wav`,
/// verify the printed events against what physically happened, then pin.

private let fixturesDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()          // tingle-tests
    .deletingLastPathComponent()          // Tests
    .appendingPathComponent("fixtures")

/// Minimal RIFF reader for the fixtures (16-bit PCM mono).
func loadFixtureWAV(_ name: String) -> [Float]? {
    guard let data = try? Data(contentsOf: fixturesDir.appendingPathComponent(name)) else { return nil }
    guard let fmtRange = data.range(of: Data("fmt ".utf8)),
          let dataRange = data.range(of: Data("data".utf8)) else { return nil }
    let channels = data.withUnsafeBytes { buf in
        buf.loadUnaligned(fromByteOffset: fmtRange.lowerBound + 10, as: UInt16.self)
    }
    guard channels == 1 else { return nil }
    let payload = data.dropFirst(dataRange.lowerBound + 8)
    var samples = [Float]()
    samples.reserveCapacity(payload.count / 2)
    payload.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        let n = buf.count / 2
        for i in 0..<n {
            samples.append(Float(buf.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) / 32768.0)
        }
    }
    return samples
}

func decodeSamples(_ samples: [Float]) -> [TingEvent] {
    var detector = GoertzelDetector(configuration: .init(
        sampleRate: 48_000, targetFrequencies: [17_500, 18_000, 18_500, 19_000]))
    var events: [TingEvent] = []
    var index = 0
    while index < samples.count {
        let end = min(index + 4800, samples.count)
        events += detector.process(samples: Array(samples[index..<end]))
        index = end
    }
    return events
}

func runAudioFixtureTests() {
    // (full beacons, degraded-but-sensed beacons) per fixture: one beacon
    // in the 22s clip loses its first tone to noise and must surface as
    // presence-without-state, never a phantom or a guessed handle state.
    for (name, expectedBeacons, expectedSensed) in [
        ("beacons_quiet_9s.wav", 5, 0),
        ("beacons_quiet_22s.wav", 12, 1),
    ] {
        guard let samples = loadFixtureWAV(name) else {
            expect(false, "fixture \(name) loads")
            continue
        }
        let events = decodeSamples(samples)
        let beacons = events.filter { $0 == .beacon }.count
        let sensed = events.filter { $0 == .beaconSensed }.count
        let phantoms = events.filter { $0 != .beacon && $0 != .beaconHeld && $0 != .beaconSensed }
        expectEqual(beacons, expectedBeacons, "fixture \(name): \(expectedBeacons) full beacons decode")
        expectEqual(sensed, expectedSensed, "fixture \(name): degraded beacons sensed, not guessed")
        expect(phantoms.isEmpty, "fixture \(name): no phantom events (got \(phantoms.map(\.logDescription)))")
    }
}
