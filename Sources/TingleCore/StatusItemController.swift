import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement
import SwiftUI
import os

/// Owns the NSStatusItem and its menu; reflects coordinator state, gates the
/// TINGDISK items on volume mounts, surfaces permission problems, offers
/// input-device selection, and hosts the settings window.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let configStore: ConfigStore
    private let coordinator: DetectionCoordinator
    private let permissions: PermissionsMonitor

    private let statusItem: NSStatusItem
    private let statusLineItem = NSMenuItem(title: BackendState.idle.menuDescription, action: nil, keyEquivalent: "")
    private let batteryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let micPermissionItem = NSMenuItem(
        title: "⚠️ Grant microphone access…",
        action: #selector(fixMicrophonePermission),
        keyEquivalent: ""
    )
    private let axPermissionItem = NSMenuItem(
        title: "⚠️ Grant accessibility access…",
        action: #selector(fixAccessibilityPermission),
        keyEquivalent: ""
    )
    private let axRepairItem = NSMenuItem(
        title: "    Listed but not working? Repair…",
        action: #selector(repairAccessibilityPermission),
        keyEquivalent: ""
    )
    private let inputDeviceItem = NSMenuItem(title: "Input device", action: nil, keyEquivalent: "")
    private let flashItem = NSMenuItem(title: "Flash EP…", action: #selector(flashEP), keyEquivalent: "")
    private let restoreItem = NSMenuItem(title: "Restore stock", action: #selector(restoreStock), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let updater = Updater()

    private let log = Logger(subsystem: Log.subsystem, category: "menu")

    init(configStore: ConfigStore, coordinator: DetectionCoordinator, permissions: PermissionsMonitor) {
        self.configStore = configStore
        self.coordinator = coordinator
        self.permissions = permissions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        permissions.onChange = { [weak self] in
            self?.updatePermissionItems()
            self?.refreshIcon()
        }

        if let button = statusItem.button {
            button.image = MenuBarIcon.image(dictating: false, dot: .none)
            button.toolTip = "tingle"
        }

        statusItem.menu = buildMenu()
        subscribeToCoordinator()
        observeVolumeMounts()
        updateTingleiskItems()
        updatePermissionItems()
        rebuildInputDeviceSubmenu()
        registerLaunchAtLoginOnFirstRun()
        updateLaunchAtLoginState()
    }

    /// Refresh the dynamic bits every time the menu opens (device list,
    /// permission state, volume mounts can all change behind our back).
    func menuWillOpen(_ menu: NSMenu) {
        updateTingleiskItems()
        updatePermissionItems()
        rebuildInputDeviceSubmenu()
        updateLaunchAtLoginState()
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)

        batteryItem.isEnabled = false
        batteryItem.isHidden = true
        menu.addItem(batteryItem)

        // Permission problems (hidden while everything is granted).
        micPermissionItem.target = self
        micPermissionItem.isHidden = true
        menu.addItem(micPermissionItem)
        axPermissionItem.target = self
        axPermissionItem.isHidden = true
        menu.addItem(axPermissionItem)
        axRepairItem.target = self
        axRepairItem.isHidden = true
        menu.addItem(axRepairItem)

        inputDeviceItem.submenu = NSMenu()
        menu.addItem(inputDeviceItem)

        flashItem.target = self
        menu.addItem(flashItem)

        restoreItem.target = self
        menu.addItem(restoreItem)

        menu.addItem(.separator())

        // All configuration is the JSON file (live-reloaded on save);
        // this opens it in the default editor.
        let editConfigItem = NSMenuItem(title: "Edit config…", action: #selector(openConfigFile), keyEquivalent: ",")
        editConfigItem.target = self
        menu.addItem(editConfigItem)

        // Version + updates are always visible (discoverability); the
        // check is only actionable in the installed .app — Sparkle cannot
        // update a bare dev binary.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let versionItem = NSMenuItem(
            title: "tingle \(version ?? "dev build")", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        if updater.isActive {
            updateItem.target = self
        } else {
            updateItem.isEnabled = false
            updateItem.title = "Check for Updates… (installed app only)"
        }
        menu.addItem(updateItem)

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        return menu
    }

    /// While non-nil, overrides the backend state on the status line
    /// ("Preparing speech model…", "Dictating…", "Inserted N words").
    private var dictationStatus: String?
    private var lastBackendState: BackendState = .idle

    /// True while the handle is physically squeezed (triggerDown..triggerUp).
    private var triggerHeld = false
    /// Non-nil while a Flash EP / Restore stock operation runs; overrides
    /// everything on the status line and shows the dimmed-grille/yellow icon.
    private var flashStatus: String?

    func setDictationStatus(_ text: String?) {
        dictationStatus = text
        refreshStatusLine()
        refreshIcon()
    }

    func setTriggerHeld(_ held: Bool) {
        triggerHeld = held
        refreshIcon()
    }

    func setFlashStatus(_ text: String?) {
        flashStatus = text
        // Progress lives on the (disabled) Flash EP item itself. Plain
        // title changes don't repaint while the menu is open; assigning
        // attributedTitle forces the redraw.
        let title = text ?? "Flash EP…"
        flashItem.title = title
        if text != nil {
            flashItem.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        } else {
            flashItem.attributedTitle = nil
        }
        refreshIcon()
        updateTingleiskItems()
    }

    var isFlashing: Bool { flashStatus != nil }

    private func refreshStatusLine() {
        statusLineItem.title = dictationStatus ?? lastBackendState.menuDescription
    }

    private func refreshIcon() {
        let attention = !permissions.allGranted
        if flashStatus != nil {
            statusItem.button?.image = MenuBarIcon.image(
                dictating: false, dot: .busy, dimmed: true, needsAttention: attention)
            return
        }
        // Red/filled tracks the PHYSICAL squeeze only — status text like
        // "Inserted N words" lingers for a few seconds and must not read
        // as active dictation.
        let dictating = triggerHeld
        let dot: MenuBarIcon.Dot
        if dictating {
            dot = .active
        } else {
            switch lastBackendState {
            case .connectedSerial, .tingDetected, .listeningAudio:
                dot = .present
            case .searching, .tingStale:
                dot = .searching
            case .idle, .noInputDevice:
                dot = .none
            }
        }
        statusItem.button?.image = MenuBarIcon.image(
            dictating: dictating, dot: dot, needsAttention: attention)
    }

    private func subscribeToCoordinator() {
        coordinator.onStateChange = { [weak self] state in
            guard let self else { return }
            self.lastBackendState = state
            self.refreshStatusLine()
            self.refreshIcon()
            if state != .connectedSerial {
                self.batteryItem.isHidden = true
            }
        }
        coordinator.onBattery = { [weak self] volts in
            guard let self else { return }
            if let volts {
                self.batteryItem.title = String(
                    format: "ting battery: %.2f V (~%d%%)",
                    volts, BatteryEstimate.percent(packVolts: volts)
                )
                self.batteryItem.isHidden = false
            } else {
                self.batteryItem.isHidden = true
            }
        }
    }

    // MARK: - Input device selection

    /// Rebuild the "Input device" submenu: "Automatic (beacon detection)" is
    /// the default; specific devices are a manual override that pins the UID
    /// in config. Only eligible line-in candidates are listed (see
    /// InputDeviceSelector).
    private func rebuildInputDeviceSubmenu() {
        let submenu = inputDeviceItem.submenu ?? NSMenu()
        submenu.removeAllItems()
        submenu.autoenablesItems = false

        let configuredUID = PinnedInput.uid

        let autoItem = NSMenuItem(
            title: "Automatic (beacon detection)",
            action: #selector(selectAutomaticInput),
            keyEquivalent: ""
        )
        autoItem.target = self
        autoItem.state = configuredUID == nil ? .on : .off
        submenu.addItem(autoItem)
        submenu.addItem(.separator())

        let candidates = InputDeviceSelector.candidates(from: AudioDeviceCatalog.systemInputDevices())
        if candidates.isEmpty {
            let empty = NSMenuItem(title: "No line-in devices found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for device in candidates {
                let item = NSMenuItem(title: device.name, action: #selector(selectInputDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.uid
                item.state = device.uid == configuredUID ? .on : .off
                submenu.addItem(item)
            }
        }
        inputDeviceItem.submenu = submenu
    }

    @objc private func selectAutomaticInput() {
        log.info("input device set to automatic (beacon detection)")
        // null UID = automatic; the config observer resets the scan.
        PinnedInput.uid = nil
        coordinator.inputSelectionChanged()
        rebuildInputDeviceSubmenu()
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        log.info("input device pinned: \(sender.title, privacy: .public) (\(uid, privacy: .public))")
        // Persist; the config observer restarts the audio backend live.
        PinnedInput.uid = uid
        coordinator.inputSelectionChanged()
        rebuildInputDeviceSubmenu()
    }

    // MARK: - Permission visibility

    private func updatePermissionItems() {
        permissions.refresh()
        switch permissions.mic {
        case .granted:
            micPermissionItem.isHidden = true
        case .undetermined:
            micPermissionItem.isHidden = false
            micPermissionItem.title = "⚠️ Grant microphone access…"
        case .denied:
            micPermissionItem.isHidden = false
            micPermissionItem.title = "⚠️ Microphone denied — open Settings…"
        }
        axPermissionItem.isHidden = permissions.axTrusted
        // The repair path (tccutil reset) only makes sense for the bundled
        // app: the dev binary's accessibility grant belongs to the terminal.
        axRepairItem.isHidden = permissions.axTrusted
            || Bundle.main.bundleIdentifier != "com.tutorintelligence.tingle"
    }

    @objc private func fixMicrophonePermission() {
        permissions.fixMicrophone()
    }

    @objc private func fixAccessibilityPermission() {
        permissions.fixAccessibility()
    }

    @objc private func repairAccessibilityPermission() {
        axRepairItem.isEnabled = false
        permissions.repairAccessibility { [weak self] in
            self?.axRepairItem.isEnabled = true
            self?.updatePermissionItems()
        }
    }

    // MARK: - TINGDISK

    private func observeVolumeMounts() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(volumesDidChange),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(volumesDidChange),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
    }

    @objc private func volumesDidChange(_ notification: Notification) {
        updateTingleiskItems()
    }

    private func updateTingleiskItems() {
        let available = Flasher.isTingleiskMounted && !isFlashing
        flashItem.isEnabled = available
        restoreItem.isEnabled = available
    }

    @objc private func flashEP() {
        runFlasherOperation(.flash(frequencies: configStore.config.toneFrequencies), title: "Flash EP")
    }

    @objc private func restoreStock() {
        runFlasherOperation(.restore, title: "Restore stock")
    }

    /// Disk work runs on a background queue; progress streams into the
    /// status line (and the log), and the finale is a regular alert.
    private func runFlasherOperation(_ operation: Flasher.Operation, title: String) {
        setFlashStatus("\(title): starting…")
        Flasher.run(operation) { [weak self] step in
            self?.setFlashStatus(step)
            self?.log.info("\(title, privacy: .public): \(step, privacy: .public)")
        } completion: { [weak self] result in
            guard let self else { return }
            self.statusItem.menu?.cancelTracking()
            self.setFlashStatus(nil)
            self.updateTingleiskItems()
            switch result {
            case .success(let message):
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "\(title) complete"
                alert.informativeText = message
                    + "\n\nNow power-cycle the ting: press the small button above "
                    + "the USB-C port, then push the handle to start it."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            case .failure(let error):
                self.log.error("\(title, privacy: .public) failed: \(String(describing: error))")
                self.presentError("\(title) failed", error)
            }
        }
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Config file

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func openConfigFile() {
        NSWorkspace.shared.open(ConfigStore.configURL)
    }

    // MARK: - Launch at Login

    private func updateLaunchAtLoginState() {
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// A menu bar utility that isn't running is doing nothing: the
    /// installed app defaults launch-at-login ON at first launch (macOS
    /// posts its own "added as login item" notice). One-shot — after this,
    /// only the user's menu toggle changes it. Never for the dev binary
    /// (SMAppService needs a bundled .app).
    private func registerLaunchAtLoginOnFirstRun() {
        guard Bundle.main.bundleIdentifier == "com.tutorintelligence.tingle",
              !UserDefaults.standard.bool(forKey: "launchAtLoginConfigured") else { return }
        UserDefaults.standard.set(true, forKey: "launchAtLoginConfigured")
        do {
            try SMAppService.mainApp.register()
            log.info("launch at login enabled by default on first run")
        } catch {
            log.error("first-run SMAppService register failed: \(String(describing: error))")
        }
        updateLaunchAtLoginState()
    }

    @objc private func toggleLaunchAtLogin() {
        // SMAppService needs a bundled .app; running as a bare SwiftPM binary
        // during development this will throw — surface it gracefully.
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                log.info("launch at login disabled")
            } else {
                try service.register()
                log.info("launch at login enabled")
            }
        } catch {
            log.error("SMAppService register/unregister failed: \(String(describing: error))")
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Launch at Login unavailable"
            alert.informativeText = "Launch at Login requires tingle to run as a bundled .app "
                + "(it is currently running as a bare development binary).\n\n\(error.localizedDescription)"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        updateLaunchAtLoginState()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
