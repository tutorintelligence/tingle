import Foundation

/// The signaling alphabet: four linear chirps, two bands x two sweep
/// directions (see docs/CODED_SYMBOLS.md). This is the single source of
/// truth for BOTH sides of the air gap: Flasher writes these exact
/// waveforms to the device's sample slots, and SymbolDetector correlates
/// against the same synthesis. Change anything here and the device must
/// be re-flashed.
public enum SymbolSet {
    public static let sampleRate = 48_000.0
    public static let duration = 0.025         // measured clean through the ting's lo-fi output
    public static let edge = 0.003             // 3ms raised-cosine edges
    public static let amplitude = 0.95

    /// (startHz, endHz) per slot. Up/down in the same band are
    /// near-orthogonal; the two bands are disjoint. Constructionally
    /// orthogonal — never build one symbol from another's material.
    public static let sweeps: [(start: Double, end: Double)] = [
        (16_500, 17_900),   // S0  low band, up
        (17_900, 16_500),   // S1  low band, down
        (18_100, 19_500),   // S2  high band, up
        (19_500, 18_100),   // S3  high band, down
    ]

    // MARK: - Codeword protocol (see DESIGN.md "Signaling protocol")

    /// Device-side inter-symbol spacing: 2 engine ticks (~29ms at fw
    /// 1.0.8's ~70Hz) — one word = 4 symbols ~= 110ms on the wire.
    /// RS[4,2] over GF(4): 16 codewords, minimum Hamming distance 3 —
    /// detects any 2 symbol errors, corrects any 1. Generated as
    /// (m0, m1, m0+m1, m0+2*m1) in GF(4).
    public static let codebook: [[Int]] = [
        [0,0,0,0], [0,1,1,2], [0,2,2,3], [0,3,3,1],
        [1,0,1,1], [1,1,0,3], [1,2,3,2], [1,3,2,0],
        [2,0,2,2], [2,1,3,0], [2,2,0,1], [2,3,1,3],
        [3,0,3,3], [3,1,2,1], [3,2,1,0], [3,3,0,2],
    ]

    /// Message indices into the codebook.
    public enum Message: Int {
        case beaconReleased = 0
        case beaconHeld = 1
        case triggerDown = 2
        case triggerUp = 3
        case white1 = 4, white2 = 5, white3 = 6, white4 = 7
        case mode1 = 8, mode2 = 9, mode3 = 10, mode4 = 11
        case fxChanged = 12
        // 13-15 spare
    }

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
