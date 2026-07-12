import AVFoundation
import Foundation

/// Assembles the "Copy diagnostics" report — everything needed to triage
/// a support report without screen-sharing. Privacy: dictation content is
/// logged at .info, which macOS does NOT persist, so the `log show` section
/// can only ever contain warnings/errors (device names, signal levels,
/// state transitions — no transcript text). The config section is the
/// user's own file.
public enum Diagnostics {
    public struct Snapshot {
        public var appVersion: String
        public var buildMode: String
        public var macOSVersion: String
        public var backendState: String
        public var weakSignal: Bool
        public var micGranted: Bool
        public var accessibilityGranted: Bool
        public var rewriteModelAvailable: Bool
        public var pinnedInputUID: String?
        public var lastBeaconLevelDB: Double?
        public var micMode: String
        public var inputDevices: [String]
        public var transitions: [(at: Date, line: String)]
        public var configText: String

        public init(appVersion: String, buildMode: String, macOSVersion: String,
                    backendState: String, weakSignal: Bool, micGranted: Bool,
                    accessibilityGranted: Bool, rewriteModelAvailable: Bool,
                    pinnedInputUID: String?, lastBeaconLevelDB: Double?,
                    micMode: String, inputDevices: [String],
                    transitions: [(at: Date, line: String)],
                    configText: String) {
            self.appVersion = appVersion
            self.buildMode = buildMode
            self.macOSVersion = macOSVersion
            self.backendState = backendState
            self.weakSignal = weakSignal
            self.micGranted = micGranted
            self.accessibilityGranted = accessibilityGranted
            self.rewriteModelAvailable = rewriteModelAvailable
            self.pinnedInputUID = pinnedInputUID
            self.lastBeaconLevelDB = lastBeaconLevelDB
            self.micMode = micMode
            self.inputDevices = inputDevices
            self.transitions = transitions
            self.configText = configText
        }
    }

    public static func report(_ s: Snapshot, recentLog: String) -> String {
        let stamp = ISO8601DateFormatter()
        var out = """
        === tingle diagnostics \(stamp.string(from: Date())) ===
        tingle \(s.appVersion) (\(s.buildMode)), macOS \(s.macOSVersion)
        state: \(s.backendState)\(s.weakSignal ? "  [WEAK SIGNAL — raise ting volume knob]" : "")
        permissions: mic \(s.micGranted ? "granted" : "MISSING"), accessibility \(s.accessibilityGranted ? "granted" : "MISSING")
        rewrite model: \(s.rewriteModelAvailable ? "available" : "unavailable (Apple Intelligence off or unsupported)")
        pinned input: \(s.pinnedInputUID ?? "none (auto-discovery)")
        last beacon lock level: \(s.lastBeaconLevelDB.map { String(format: "%.1f dBFS", $0) } ?? "never locked")
        mic mode (Control Center): \(s.micMode)
        input devices: \(s.inputDevices.isEmpty ? "none" : s.inputDevices.joined(separator: ", "))
        """
        out += "\n\n--- recent state transitions ---\n"
        if s.transitions.isEmpty {
            out += "(none this session)\n"
        }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        for t in s.transitions.suffix(30) {
            out += "\(timeFmt.string(from: t.at))  \(t.line)\n"
        }
        out += "\n--- config.toml ---\n\(s.configText)\n"
        out += "\n--- warnings/errors (last 30m) ---\n\(recentLog.isEmpty ? "(none)" : recentLog)\n"
        return out
    }

    /// The user's Control Center mic-mode selection. Mic modes only apply
    /// to apps adopting the voice-processing audio unit — tingle never
    /// does, so Voice Isolation should be inert here — but if ultrasonics
    /// ever vanish while this reads non-standard, that assumption broke.
    public static func currentMicMode() -> String {
        switch AVCaptureDevice.preferredMicrophoneMode {
        case .standard: return "Standard"
        case .voiceIsolation: return "Voice Isolation (should be inert for tingle's raw capture)"
        case .wideSpectrum: return "Wide Spectrum"
        @unknown default: return "unknown"
        }
    }

    /// Persisted unified-log lines (warning+error only — info, where
    /// dictation text lives, never persists). Runs `log show`; slow-ish
    /// (~1-3s), call off the main thread.
    public static func recentPersistedLog() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", "30m", "--style", "compact",
            "--predicate", "subsystem == \"com.tutorintelligence.tingle\"",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return "(log show failed: \(error.localizedDescription))"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        // Keep the tail — recent lines matter most.
        let lines = text.split(separator: "\n").filter { !$0.hasPrefix("Timestamp") }
        return lines.suffix(120).joined(separator: "\n")
    }
}
