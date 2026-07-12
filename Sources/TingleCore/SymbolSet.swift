import Foundation

/// The v2 signaling alphabet: four linear chirps, two bands x two sweep
/// directions (see docs/CODED_SYMBOLS.md). This is the single source of
/// truth for BOTH sides of the air gap: Flasher writes these exact
/// waveforms to the device's sample slots, and SymbolDetector correlates
/// against the same synthesis. Change anything here and the device must
/// be re-flashed.
public enum SymbolSet {
    public static let sampleRate = 48_000.0
    public static let duration = 0.08          // 80ms
    public static let edge = 0.005             // 5ms raised-cosine edges
    public static let amplitude = 0.95

    /// (startHz, endHz) per slot. Up/down in the same band are
    /// near-orthogonal at time-bandwidth 80; the two bands are disjoint.
    public static let sweeps: [(start: Double, end: Double)] = [
        (16_750, 17_750),   // S0  low band, up
        (17_750, 16_750),   // S1  low band, down
        (18_250, 19_250),   // S2  high band, up
        (19_250, 18_250),   // S3  high band, down
    ]

    public static var frameCount: Int { Int(duration * sampleRate) }

    /// Unit-amplitude chirp with raised-cosine edges. The instantaneous
    /// frequency sweeps linearly start -> end; phase is its integral.
    public static func samples(symbol: Int) -> [Double] {
        let (f0, f1) = sweeps[symbol]
        let n = frameCount
        let fade = Int(edge * sampleRate)
        var out = [Double](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(n)
            let f = f0 + (f1 - f0) * t
            phase += 2.0 * .pi * f / sampleRate
            var v = sin(phase)
            if i < fade { v *= 0.5 * (1 - cos(.pi * Double(i) / Double(fade))) }
            let fromEnd = n - 1 - i
            if fromEnd < fade { v *= 0.5 * (1 - cos(.pi * Double(fromEnd) / Double(fade))) }
            out[i] = v
        }
        return out
    }

    /// 16-bit PCM at flash amplitude — the bytes that go into slot WAVs.
    public static func pcm(symbol: Int) -> [Int16] {
        samples(symbol: symbol).map { Int16(max(-32768, min(32767, ($0 * amplitude * 32767).rounded()))) }
    }
}
