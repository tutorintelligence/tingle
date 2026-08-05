import Foundation
import TingleCore

func runFlasherTests() {
    // --- write verification (the safety net that turns a bad flash into a
    // loud error instead of a silent dead device) ---
    let a = Data([1, 2, 3, 4])
    expect(Flasher.verificationMismatch(label: "main.py", expected: a, actual: a) == nil,
           "flasher: identical bytes verify clean")
    // truncation — the exact failure mode this device hit (4096 of 11548)
    let truncated = Data([1, 2, 3])
    if let reason = Flasher.verificationMismatch(label: "main.py", expected: a, actual: truncated) {
        expect(reason.contains("4 bytes") && reason.contains("3"),
               "flasher: truncation reports both sizes")
    } else {
        expect(false, "flasher: truncation must be caught")
    }
    // same length, different content
    expect(Flasher.verificationMismatch(label: "1.wav", expected: a, actual: Data([1, 2, 3, 9])) != nil,
           "flasher: content mismatch caught")
    // empty read-back (write silently produced nothing)
    expect(Flasher.verificationMismatch(label: "main.py", expected: a, actual: Data()) != nil,
           "flasher: empty read-back caught")

    // --- dry-bus config.json ---
    let cfg = Flasher.configJSON()
    guard let obj = try? JSONSerialization.jsonObject(with: cfg) as? [String: Any] else {
        expect(false, "flasher: config.json is valid JSON"); return
    }
    let presets = obj["presets"] as? [[String: Any]] ?? []
    expect(presets.count == 4, "flasher: four presets (orange cycles 0-3)")
    // EVERY preset must be dry SAMPLE-only — one non-dry preset the orange
    // button can land on reintroduces the chirp-mangling bug.
    for p in presets {
        let effects = (p["list"] as? [[String: Any]] ?? []).compactMap { $0["effect"] as? String }
        expect(effects == ["SAMPLE"], "flasher: preset \(p["pos"] ?? "?") is dry SAMPLE-only")
    }
    let samples = obj["samples"] as? [[String: Any]] ?? []
    expect(samples.count == 4, "flasher: four sample slots")
    for (i, smp) in samples.enumerated() {
        expect(smp["file"] as? String == "\(i + 1).wav", "flasher: sample \(i) -> \(i + 1).wav")
    }
    // pure ASCII (serial-write deploys drop non-ASCII)
    expect(cfg.allSatisfy { $0 < 128 }, "flasher: config.json is pure ASCII")

    // --- per-device firmware bookkeeping (a global flag once marked a
    // new device as upgraded because a DIFFERENT ting had been) ---
    Prefs.setLastFlashedFirmware("9.9.9", serial: "TESTSERIALA")
    expect(Prefs.lastFlashedFirmware(serial: "TESTSERIALA") == "9.9.9",
           "prefs: firmware flag roundtrips per serial")
    expect(Prefs.lastFlashedFirmware(serial: "TESTSERIALB") == nil,
           "prefs: a different serial is unknown")
    expect(Prefs.lastFlashedFirmware(serial: nil) == nil,
           "prefs: no serial means unknown firmware")
    Prefs.suite.removeObject(forKey: "lastFlashedFirmware.TESTSERIALA")

    // --- firmware flow copy: the hold reminder is on EVERY progress card
    // (a bare step line left the user guessing whether to let go) ---
    for step in ["Writing firmware…", "Waiting for the ting to come back…",
                 "Reinstalling the tingle payload…", "Writing symbol 1 of 4…"] {
        let text = FirmwareUpgrader.progressText(step: step)
        expect(text.contains(FirmwareUpgrader.holdReminder),
               "firmware: hold reminder present on '\(step)'")
        expect(text.contains(step), "firmware: step text preserved on '\(step)'")
    }
    expect(FirmwareUpgrader.holdReminder.contains("DO NOT RELEASE"),
           "firmware: reminder states the do-not-release rule")
    expect(FirmwareUpgrader.holdReminder.allSatisfy { $0.isASCII },
           "firmware: reminder is ASCII")

    // --- symbol WAV shape (25ms mono 16-bit @48k = 44 header + 2400 pcm) ---
    let wav = Flasher.symbolWAV(symbol: 0)
    expect(wav.count == 2444, "flasher: symbol WAV is 2444 bytes")
    expect(wav.prefix(4) == Data("RIFF".utf8) && wav[8..<12] == Data("WAVE".utf8),
           "flasher: symbol WAV has RIFF/WAVE header")
}
