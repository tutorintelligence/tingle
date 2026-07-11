import AppKit
import ApplicationServices
import os

/// Executes configured actions: keystrokes and held keys via CGEvent
/// (requires Accessibility) and shell commands via /bin/zsh (fire-and-forget,
/// output logged).
///
/// keyHold actions post key-DOWN only and are tracked as held; the matching
/// key-UP goes out via releaseHeldKeys(), which the app calls when triggerUp
/// fires and on quit. This enables hold-to-dictate hotkeys (e.g. Wispr Flow's
/// hold mode) driven by the ting's handle.
final class ActionRunner {
    private let log = Logger(subsystem: Log.subsystem, category: "actions")
    private var promptedForAccessibility = false
    /// Keys currently held by keyHold actions: key name → (code, flags).
    private var heldKeys: [String: (code: CGKeyCode, flags: CGEventFlags)] = [:]

    func run(_ action: TingAction) {
        switch action {
        case .keystroke(let key, let modifiers):
            postKeystroke(key: key, modifiers: modifiers)
        case .shell(let command):
            runShell(command)
        case .keyHold(let key, let modifiers):
            holdKey(key: key, modifiers: modifiers)
        case .dictate:
            // Routed by AppDelegate to DictationController (triggerDown only);
            // reaching here means it was mapped somewhere invalid and slipped
            // through routing — never expected.
            log.error("dictate action reached ActionRunner; it is only valid on triggerDown")
        case .eraseDictation:
            // Routed by AppDelegate to DictationController — never expected here.
            log.error("eraseDictation action reached ActionRunner; routing bug")
        }
    }

    /// Post key-UP for every key held by a keyHold action. Called when
    /// triggerUp fires and on app termination.
    func releaseHeldKeys() {
        guard !heldKeys.isEmpty else { return }
        for (key, held) in heldKeys {
            postKeyEvent(code: held.code, flags: held.flags, keyDown: false)
            log.info("released held key \(key, privacy: .public)")
        }
        heldKeys.removeAll()
    }

    // MARK: - Keystroke

    private func postKeystroke(key: String, modifiers: [String]) {
        guard let (keyCode, flags) = resolve(key: key, modifiers: modifiers) else { return }
        guard ensureAccessibility() else {
            log.error("Accessibility not granted; dropping keystroke \(key, privacy: .public)")
            return
        }
        postKeyEvent(code: keyCode, flags: flags, keyDown: true)
        postKeyEvent(code: keyCode, flags: flags, keyDown: false)
        log.info("posted keystroke \(key, privacy: .public) modifiers \(modifiers, privacy: .public)")
    }

    private func holdKey(key: String, modifiers: [String]) {
        guard let (keyCode, flags) = resolve(key: key, modifiers: modifiers) else { return }
        guard ensureAccessibility() else {
            log.error("Accessibility not granted; dropping keyHold \(key, privacy: .public)")
            return
        }
        let name = key.lowercased()
        guard heldKeys[name] == nil else {
            log.debug("key \(name, privacy: .public) already held; ignoring")
            return
        }
        postKeyEvent(code: keyCode, flags: flags, keyDown: true)
        heldKeys[name] = (code: keyCode, flags: flags)
        log.info("holding key \(key, privacy: .public) modifiers \(modifiers, privacy: .public)")
    }

    private func resolve(key: String, modifiers: [String]) -> (CGKeyCode, CGEventFlags)? {
        guard let keyCode = Self.keyCodes[key.lowercased()] else {
            log.error("unknown key name \"\(key, privacy: .public)\"")
            return nil
        }
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default:
                log.warning("unknown modifier \"\(modifier, privacy: .public)\" ignored")
            }
        }
        return (keyCode, flags)
    }

    private func postKeyEvent(code: CGKeyCode, flags: CGEventFlags, keyDown: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown) else {
            log.error("failed to create CGEvent for key code \(code)")
            return
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Returns true if the process is trusted for Accessibility. On first
    /// refusal, shows the system prompt (via AXIsProcessTrustedWithOptions).
    /// Also used by DictationController before starting live typing.
    func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !promptedForAccessibility {
            promptedForAccessibility = true
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    // MARK: - Shell

    private func runShell(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let log = self.log
        process.terminationHandler = { proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log.info("shell exited \(proc.terminationStatus): \(output, privacy: .public)")
        }

        do {
            try process.run()
            log.info("launched shell command: \(command, privacy: .public)")
        } catch {
            log.error("failed to launch shell command: \(String(describing: error))")
        }
    }

    // MARK: - Key map (ANSI US virtual key codes)

    static let keyCodes: [String: CGKeyCode] = [
        // Named keys
        "return": 36, "escape": 53, "space": 49, "tab": 48, "delete": 51,
        "left": 123, "right": 124, "down": 125, "up": 126,
        // Letters
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
        "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
        "w": 13, "x": 7, "y": 16, "z": 6,
        // Digits
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        // Function keys
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}
