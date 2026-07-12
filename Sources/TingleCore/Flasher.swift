import AppKit
import AVFoundation
import os

/// FLASH EP: writes mode-tone WAVs plus the tingle event engine (main.py — the
/// ting executes /fat/main.py at boot, see DESIGN.md "key discovery") to the
/// TINGDISK volume, with backup of what was there, cleans up AppleDouble junk,
/// and ejects. "Restore stock" deletes the overrides instead — without
/// main.py and 1-4.wav the device is 100% stock.
enum Flasher {
    static let volumeURL = URL(fileURLWithPath: "/Volumes/TINGDISK", isDirectory: true)

    private static let sampleFileNames = ["1.wav", "2.wav", "3.wav", "4.wav"]
    /// Everything FLASH EP can touch (and therefore backs up / restores).
    private static let managedFileNames = ["1.wav", "2.wav", "3.wav", "4.wav", "main.py", "config.json"]
    private static let log = Logger(subsystem: Log.subsystem, category: "flasher")

    enum FlasherError: LocalizedError {
        case volumeNotMounted
        case bufferAllocationFailed
        case wrongFrequencyCount
        case payloadMissing
        case ejectFailed(String)

        var errorDescription: String? {
            switch self {
            case .volumeNotMounted:
                return "TINGDISK is not mounted."
            case .ejectFailed(let detail):
                return "Could not eject TINGDISK: \(detail)"
            case .bufferAllocationFailed:
                return "Could not allocate the audio buffer for tone generation."
            case .wrongFrequencyCount:
                return "Config must define exactly 4 tone frequencies."
            case .payloadMissing:
                return "The tingle_main.py device payload is missing from the app's resources."
            }
        }
    }

    /// The device event engine shipped as main.py. Bundled via Package.swift
    /// resources from Sources/TingleCore/Resources/tingle_main.py, which must
    /// be kept byte-identical with the source of truth at device/tingle_main.py.
    ///
    /// Deliberately NOT Bundle.module: SwiftPM's generated accessor for
    /// executable targets only checks the .app ROOT and the absolute build
    /// directory baked in at compile time — and it fatalErrors when both
    /// miss. A CI-built .app keeps the bundle in Contents/Resources and has
    /// a nonexistent /Users/runner build path, so clicking Flash EP crashed
    /// the whole app (2026-07-11). Resolve the bundle ourselves, gracefully.
    public static func devicePayload() throws -> Data {
        // resourceURL covers the installed .app (Contents/Resources);
        // bundleURL covers the bare dev binary (.build/debug/).
        for dir in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            let resourceBundle = dir.appendingPathComponent("tingle_TingleCore.bundle")
            if let bundle = Bundle(url: resourceBundle),
               let url = bundle.url(forResource: "tingle_main", withExtension: "py"),
               let data = try? Data(contentsOf: url) {
                return data
            }
        }
        throw FlasherError.payloadMissing
    }

    static var isTingleiskMounted: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: volumeURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - Entry points

    enum Operation {
        case flash(frequencies: [Double])
        case restore
    }

    /// Run a disk operation on a background queue with live progress
    /// callbacks (both closures called on the main queue). The menu action
    /// must NOT call the throwing entry points directly — disk I/O plus the
    /// eject retry loop can take several seconds and would freeze the UI.
    static func run(
        _ operation: Operation,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let report: (String) -> Void = { text in DispatchQueue.main.async { progress(text) } }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let doneMessage: String
                switch operation {
                case .flash(let frequencies):
                    try flashEP(frequencies: frequencies, progress: report)
                    doneMessage = "The mode tones and the tingle event engine are on the ting."
                case .restore:
                    try restoreStock(progress: report)
                    doneMessage = "The ting is back to stock samples and behavior."
                }
                DispatchQueue.main.async { completion(.success(doneMessage)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Back up the current disk contents, write the 4 tone WAVs and the
    /// event engine (main.py), clean up, eject, and tell the user to
    /// power-cycle.
    static func flashEP(frequencies: [Double], progress: (String) -> Void = { _ in }) throws {
        guard isTingleiskMounted else { throw FlasherError.volumeNotMounted }
        guard frequencies.count == 4 else { throw FlasherError.wrongFrequencyCount }
        let payload = try devicePayload()  // fail before touching the disk

        progress("Backing up disk contents…")
        try backupExisting()

        let fm = FileManager.default
        // Coded chirp symbols from SymbolSet (the config's toneFrequencies
        // are ignored — symbol shapes are the air-gap contract between
        // Flasher and SymbolDetector).
        for index in 0..<4 {
            progress("Writing symbol \(index + 1) of 4…")
            let url = volumeURL.appendingPathComponent("\(index + 1).wav")
            try? fm.removeItem(at: url)
            try writeSymbolWAV(symbol: index, to: url)
            let sweep = SymbolSet.sweeps[index]
            log.info("wrote \(url.lastPathComponent, privacy: .public) chirp \(Int(sweep.start))->\(Int(sweep.end))Hz")
        }

        progress("Writing event engine (main.py)…")
        let mainPyURL = volumeURL.appendingPathComponent("main.py")
        try? fm.removeItem(at: mainPyURL)
        try payload.write(to: mainPyURL)
        log.info("wrote main.py event engine (\(payload.count) bytes)")

        // TODO: also ship a config.json with dry-bus FX presets so symbols
        // bypass the active FX preset; today the device config.json is left alone
        // (pitch-shifting presets like PIXIE/ROBOT mangle the tones — see
        // DESIGN.md "Known limitation").

        removeAppleDoubleFiles()
        progress("Ejecting TINGDISK…")
        try eject()
    }

    /// Back up, then delete everything tingle shipped — sample overrides and
    /// main.py — returning the device to 100% stock behavior (the firmware
    /// falls back to its ROM samples and its own /rom/main.py).
    static func restoreStock(progress: (String) -> Void = { _ in }) throws {
        guard isTingleiskMounted else { throw FlasherError.volumeNotMounted }

        progress("Backing up disk contents…")
        try backupExisting()

        let fm = FileManager.default
        for name in sampleFileNames + ["main.py"] {
            try? fm.removeItem(at: volumeURL.appendingPathComponent(name))
        }
        removeAppleDoubleFiles()
        progress("Ejecting TINGDISK…")
        try eject()
    }

    // MARK: - Tone generation

    /// Write a mono 16-bit WAV containing one coded chirp symbol from
    /// SymbolSet — the exact waveform SymbolDetector correlates against.
    /// Duration stays 80ms: the event engine triggers a chirp's second
    /// burst ~114ms after the first (fw 1.0.8 ticks), relying on the
    /// sample having finished.
    static func writeSymbolWAV(symbol: Int, to url: URL) throws {
        // Assembled by hand as Data (RIFF header + 16-bit PCM) rather than
        // via AVAudioFile: no file handle stays open on the volume, so the
        // eject that follows can't hit fBsyErr from our own writer.
        let sampleRate = SymbolSet.sampleRate
        var pcm = Data(capacity: SymbolSet.frameCount * 2)
        for value in SymbolSet.pcm(symbol: symbol) {
            var sample = value.littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }

        var wav = Data()
        func append(_ string: String) { wav.append(contentsOf: string.utf8) }
        func append32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + pcm.count)); append("WAVE")
        append("fmt "); append32(16)
        append16(1)                              // PCM
        append16(1)                              // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * 2)         // byte rate
        append16(2)                              // block align
        append16(16)                             // bits per sample
        append("data"); append32(UInt32(pcm.count))
        wav.append(pcm)

        try wav.write(to: url)
    }

    // MARK: - Volume housekeeping

    /// Copy existing 1–4.wav + main.py + config.json into
    /// ~/Library/Application Support/tingle/backup/<date>/.
    private static func backupExisting() throws {
        let fm = FileManager.default
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")

        let backupDir = ConfigStore.directoryURL
            .appendingPathComponent("backup", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)

        var copied = 0
        for name in managedFileNames {
            let source = volumeURL.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            if copied == 0 {
                try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            }
            try fm.copyItem(at: source, to: backupDir.appendingPathComponent(name))
            copied += 1
        }
        if copied > 0 {
            log.info("backed up \(copied) file(s) to \(backupDir.path, privacy: .public)")
        }
    }

    /// macOS litters FAT volumes with AppleDouble ._* files; delete them from
    /// the root before ejecting (firmware ignores them, but keep it tidy).
    private static func removeAppleDoubleFiles() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: volumeURL.path) else { return }
        for name in names where name.hasPrefix("._") {
            try? fm.removeItem(at: volumeURL.appendingPathComponent(name))
        }
    }

    private static func eject() throws {
        // Freshly written files leave the volume briefly "busy" (OSStatus
        // -47, fBsyErr) — Spotlight/fseventsd touch new files. Retry.
        guard isTingleiskMounted else { return }
        // NSWorkspace's unmountAndEjectDevice reliably reports fBsyErr
        // (-47) on this device even when the unmount phase succeeds — and
        // the ting re-mounts itself moments later, defeating "volume gone"
        // checks. diskutil handles the same device flawlessly, so use it.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["eject", volumeURL.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if task.terminationStatus != 0 && isTingleiskMounted {
            log.error("diskutil eject failed: \(output, privacy: .public)")
            throw FlasherError.ejectFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        log.info("ejected TINGDISK via diskutil")
    }

}
