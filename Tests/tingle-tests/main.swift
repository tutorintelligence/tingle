import Foundation
import TingleCore

// Offline decode harness: `swift run tingle-tests --decode file.wav`
// prints the event timeline (with timestamps and burst diagnostics) for
// any mono 16-bit recording — turns field recordings into test fixtures
// and makes "what does the decoder hear?" a one-liner.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--decode" {
    let path = CommandLine.arguments[2]
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        print("cannot read \(path)"); exit(1)
    }
    guard let fmtRange = data.range(of: Data("fmt ".utf8)),
          let dataRange = data.range(of: Data("data".utf8)) else {
        print("not a RIFF wav"); exit(1)
    }
    let channels = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: fmtRange.lowerBound + 10, as: UInt16.self) })
    let rate = Double(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: fmtRange.lowerBound + 12, as: UInt32.self) })
    let payload = data.dropFirst(dataRange.lowerBound + 8)
    var samples = [Float]()
    payload.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        let n = buf.count / 2 / channels
        for i in 0..<n {  // channel 0 only
            samples.append(Float(buf.loadUnaligned(fromByteOffset: i * 2 * channels, as: Int16.self)) / 32768.0)
        }
    }
    print("decoding \(path): \(String(format: "%.1f", Double(samples.count) / rate))s, \(channels)ch @ \(Int(rate))Hz")
    guard rate == SymbolSet.sampleRate else { print("the symbol decoder requires 48kHz WAVs"); exit(1) }
    var detector = SymbolDetector()
    var index = 0
    let chunk = Int(rate / 10)
    while index < samples.count {
        let end = min(index + chunk, samples.count)
        let events = detector.process(samples: Array(samples[index..<end]))
        let t = Double(index) / rate
        for line in detector.drainDiagnostics() {
            print(String(format: "  %7.2fs  . %@", t, line))
        }
        for event in events {
            print(String(format: "  %7.2fs  * %@", t, event.logDescription))
        }
        index = end
    }
    if let margin = detector.signalMarginDB {
        print(String(format: "avg detection margin: %.1f dB%@", margin, margin < 6 ? "  (WEAK — raise the ting volume knob)" : ""))
    }
    exit(0)
}

// Rewrite eval harness: `swift run tingle-tests --rewrite-eval file.txt`
// runs each =====-separated dictation through the REAL on-device model
// with the shipped prompt (requires Apple Intelligence; local tool, not
// CI). This is how the prompt gets tuned against actual dictations.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--rewrite-eval" {
    let raw = (try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)) ?? ""
    let cases = raw.components(separatedBy: "\n=====\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    var config = RewriteConfig()
    config.enabled = true
    config.technicalFormatting = true
    let instructions = RewritePrompt.instructions(config: config, vocabulary: TingConfig.default.effectiveVocabulary)
    let model = FoundationRewriteModel()
    guard model.isAvailable else { print("Foundation model unavailable (Apple Intelligence off?)"); exit(1) }
    let sema = DispatchSemaphore(value: 0)
    Task {
        for (i, text) in cases.enumerated() {
            guard RewritePrompt.eligible(text) else { print("[\(i)] SKIP (size)"); continue }
            let t0 = Date()
            do {
                let stripped = RewritePrompt.stripFillers(text)
                let out = RewritePrompt.postProcess(try await model.rewrite(stripped, instructions: instructions))
                let ok = RewritePrompt.acceptable(input: text, output: out)
                print("[\(i)] \(String(format: "%.2f", Date().timeIntervalSince(t0)))s \(ok ? "" : "REJECTED-BY-GATE")")
                print("  IN : \(text.prefix(400))")
                print("  OUT: \(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))")
            } catch {
                print("[\(i)] ERROR \(error)")
            }
        }
        sema.signal()
    }
    sema.wait()
    exit(0)
}

// Minimal dependency-free test harness: XCTest is unavailable under bare
// CommandLineTools, and tests that only run in CI can't drive a
// data-driven local loop. Run: swift run tingle-tests
var failures = 0
var passes = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String,
            file: StaticString = #filePath, line: UInt = #line) {
    if condition() {
        passes += 1
    } else {
        failures += 1
        print("FAIL  \(label)  (\(file):\(line))")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
    if a == b {
        passes += 1
    } else {
        failures += 1
        print("FAIL  \(label): \(a) != \(b)  (\(file):\(line))")
    }
}

runTranscriptTyperTests()
// --decode-wav <file.wav> [channel]: run the PRODUCTION SymbolDetector over
// a raw line-in recording and print every decode with timestamps — for
// diagnosing field captures against known ground truth.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--decode-wav" {
    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let channel = CommandLine.arguments.count >= 4 ? Int(CommandLine.arguments[3])! : 0
    // minimal RIFF parse: find 'data' chunk, assume 16-bit PCM
    let bytes = [UInt8](data)
    var offset = 12
    var pcmStart = 0, pcmLen = 0
    var channels = 1
    while offset + 8 < bytes.count {
        let id = String(bytes: bytes[offset..<offset+4], encoding: .ascii)!
        let size = Int(bytes[offset+4]) | Int(bytes[offset+5]) << 8 | Int(bytes[offset+6]) << 16 | Int(bytes[offset+7]) << 24
        if id == "fmt " { channels = Int(bytes[offset+10]) | Int(bytes[offset+11]) << 8 }
        if id == "data" { pcmStart = offset + 8; pcmLen = size; break }
        offset += 8 + size + (size & 1)
    }
    print("channels=\(channels) pcmBytes=\(pcmLen)")
    var samples: [Float] = []
    samples.reserveCapacity(pcmLen / (2 * channels))
    var i = pcmStart + channel * 2
    while i + 1 < pcmStart + pcmLen {
        let v = Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i+1]) << 8)
        samples.append(Float(v) / 32768.0)
        i += 2 * channels
    }
    print("samples=\(samples.count) (\(Double(samples.count)/48000.0)s)")
    var detector = SymbolDetector()
    var clock = 0
    for start in stride(from: 0, to: samples.count, by: 4096) {
        let chunk = Array(samples[start..<min(start + 4096, samples.count)])
        let events = detector.process(samples: chunk)
        clock = start + chunk.count
        let t = Double(clock) / 48000.0
        for line in detector.drainDiagnostics() {
            print(String(format: "%7.2fs  %@", t, line))
        }
        for event in events {
            print(String(format: "%7.2fs  EVENT %@", t, event.logDescription))
        }
    }
    exit(0)
}

// --dump-flash-bytes <dir>: write the exact bytes Flash EP ships (WAVs +
// config.json) for independent cross-checking against the on-device copies.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--dump-flash-bytes" {
    let dir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for i in 0..<4 {
        try! Flasher.symbolWAV(symbol: i).write(to: dir.appendingPathComponent("\(i + 1).wav"))
    }
    try! Flasher.configJSON().write(to: dir.appendingPathComponent("config.json"))
    print("dumped flash bytes to \(dir.path)")
    exit(0)
}

runConfigTests()
runTriggerReconcilerTests()
runTriggerRoutingTests()
runBatteryEstimateTests()
runReplacementTests()
runWhiteFallbackTests()
runSymbolDetectorTests()
runBeaconScannerTests()
runGuardrailTests()
runRewriteTests()
runFlasherTests()
runAudioEngineOpsTests()
runAudioHardwareTests()

print(failures == 0 ? "OK — \(passes) assertions passed"
                    : "FAILED — \(failures) failures, \(passes) passed")
exit(failures == 0 ? 0 : 1)
