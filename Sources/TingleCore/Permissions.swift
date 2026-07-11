import AppKit
import AVFoundation
import ApplicationServices
import os

/// Watches the two permissions tingle cannot work without — microphone
/// (chirp detection + dictation) and accessibility (typing + summon) — and
/// drives the "needs attention" UX: the menu bar badge, the fix-it menu
/// items, and the launch-time prompts.
///
/// Until Developer ID signing lands, every ad-hoc rebuild of the .app is a
/// new TCC identity: permissions silently evaporate after an update and the
/// old Accessibility row goes stale (checked, but dead). This class exists
/// so that state is always loud and one click from fixed.
final class PermissionsMonitor {
    enum MicState {
        case granted
        case denied      // denied or restricted: only Settings can fix it
        case undetermined
    }

    private(set) var mic: MicState
    private(set) var axTrusted: Bool
    var allGranted: Bool { mic == .granted && axTrusted }

    /// Fired on the main thread whenever either permission flips.
    var onChange: (() -> Void)?

    private var timer: Timer?
    private let log = Logger(subsystem: Log.subsystem, category: "permissions")

    init() {
        mic = Self.readMic()
        axTrusted = AXIsProcessTrusted()
        noteGrant()
    }

    /// Remember that this bundle id has held the AX grant at least once —
    /// the marker that later distinguishes "stale row after an update"
    /// from "never asked".
    private func noteGrant() {
        if axTrusted { UserDefaults.standard.set(true, forKey: "axEverGranted") }
    }

    func startMonitoring() {
        // Accessibility grants broadcast a distributed notification, so the
        // menu/icon heal the instant the user flips the toggle. The timer
        // backstops that and covers microphone, which has no notification.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(accessibilityChanged),
            name: NSNotification.Name("com.apple.accessibility.api"),
            object: nil
        )
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func accessibilityChanged() {
        // TCC broadcasts before the new state is readable; settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        let newMic = Self.readMic()
        let newAX = AXIsProcessTrusted()
        guard newMic != mic || newAX != axTrusted else { return }
        log.info("permissions changed: mic \(String(describing: newMic), privacy: .public) ax \(newAX)")
        mic = newMic
        axTrusted = newAX
        noteGrant()
        DispatchQueue.main.async { self.onChange?() }
    }

    // MARK: - Prompting

    /// Launch-time flow: surface the system dialog for anything missing so
    /// the user never has to discover a silent failure later. The mic
    /// dialog is Apple's request sheet; the accessibility one carries an
    /// "Open System Settings" button that lands on the exact pane.
    func promptForMissing() {
        if mic == .undetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.refresh()
            }
        }
        if !axTrusted {
            // Ad-hoc rebuilds orphan the Accessibility row: Settings shows
            // tingle checked, AXIsProcessTrusted() says no. If we ever held
            // the grant, untrusted-now can only mean that stale row — so
            // repair silently (reset + fresh prompt) instead of hoping the
            // user discovers the menu item. Once per version, so a genuine
            // manual revoke costs at most one extra prompt per update.
            let d = UserDefaults.standard
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            if Bundle.main.bundleIdentifier == "com.tutorintelligence.tingle",
               d.bool(forKey: "axEverGranted"),
               d.string(forKey: "axAutoRepairVersion") != version {
                d.set(version, forKey: "axAutoRepairVersion")
                log.info("stale accessibility row (granted before, untrusted now) — auto-repairing")
                repairAccessibility {}
            } else {
                promptAccessibility()
            }
        }
    }

    func promptAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    /// Menu action for the mic item: request if never asked (one click =
    /// the actual grant dialog), otherwise deep-link to the pane where the
    /// existing denial can be flipped.
    func fixMicrophone() {
        switch mic {
        case .undetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.refresh()
            }
        case .denied:
            Self.openPrivacyPane("Privacy_Microphone")
        case .granted:
            break
        }
    }

    func fixAccessibility() {
        promptAccessibility()
        Self.openPrivacyPane("Privacy_Accessibility")
    }

    /// After an ad-hoc rebuild the Accessibility list often shows tingle
    /// checked while AXIsProcessTrusted() is false — the row belongs to the
    /// previous signature. tccutil deletes the stale row; the re-prompt
    /// then registers a fresh, working one.
    func repairAccessibility(completion: @escaping () -> Void) {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            fixAccessibility()
            completion()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.log.info("tccutil reset Accessibility exited \(proc.terminationStatus)")
                self?.promptAccessibility()
                self?.refresh()
                completion()
            }
        }
        do {
            try process.run()
        } catch {
            log.error("tccutil launch failed: \(String(describing: error))")
            fixAccessibility()
            completion()
        }
    }

    static func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func readMic() -> MicState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }
}
