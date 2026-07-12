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
        title: "    Shown as granted but broken? Repair…",
        action: #selector(repairAccessibilityPermission),
        keyEquivalent: ""
    )
    private let inputDeviceItem = NSMenuItem(title: "Input device", action: nil, keyEquivalent: "")
    private let flashItem = NSMenuItem(title: "Flash EP…", action: #selector(flashEP), keyEquivalent: "")
    private let restoreItem = NSMenuItem(title: "Restore stock", action: #selector(restoreStock), keyEquivalent: "")
    private let firmwareItem = NSMenuItem(title: "Upgrade ting firmware…", action: #selector(upgradeFirmware), keyEquivalent: "")
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

        firmwareItem.target = self
        menu.addItem(firmwareItem)

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

    /// Progress goes to the floating card; here we only track busy state
    /// (drives the yellow icon and greys the disk items).
    func setFlashStatus(_ text: String?) {
        flashStatus = text
        refreshIcon()
        updateTingleiskItems()
    }

    private func setFirmwareStatus(_ text: String?) {
        setFlashStatus(text)
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
        // Firmware: show what we know. tingle can't read the running
        // version off the device (USB reports only "1.00"), so the source
        // of truth is the version this app last flashed.
        if !isFlashing {
            let flashed = UserDefaults.standard.string(forKey: "lastFlashedFirmware")
            if flashed == FirmwareUpgrader.version {
                firmwareItem.title = "ting firmware \(FirmwareUpgrader.version) (latest)"
                firmwareItem.isEnabled = false
            } else {
                firmwareItem.title = "Upgrade ting firmware to \(FirmwareUpgrader.version)…"
                firmwareItem.isEnabled = true
            }
        } else {
            firmwareItem.isEnabled = false
        }
    }

    @objc private func flashEP() {
        runFlasherOperation(.flash(frequencies: configStore.config.toneFrequencies), title: "Flash EP")
    }

    @objc private func restoreStock() {
        runFlasherOperation(.restore, title: "Restore stock")
    }

    /// The bootloader ritual card; closed automatically once the TING
    /// BOOT disk shows up (or the flow ends).
    private var firmwareInstructions: FloatingAlert?

    @objc private func upgradeFirmware() {
        // Same live-status plumbing as Flash EP, but the operation also
        // spans the guided bootloader dance and firmware write. A one-line
        // menu ticker can't teach a four-step ritual, so a floating card
        // carries the steps until the boot disk appears.
        firmwareInstructions?.close()
        firmwareInstructions = FloatingAlert.show(
            title: "Put the ting in firmware mode",
            text: """
            1.  Take off the ting's lower lid. Keep USB connected.
            2.  Squeeze the handle — and KEEP IT SQUEEZED through every \
            step until this card disappears.
            3.  Still squeezing, double-click the small button above the \
            USB port.
            4.  A disk named TING BOOT appears and tingle does the rest — \
            you can let go when this card closes.
            """)
        setFirmwareStatus("Firmware upgrade: starting…")
        FirmwareUpgrader.upgrade(
            frequencies: configStore.config.toneFrequencies
        ) { [weak self] step in
            self?.setFirmwareStatus(step)
            self?.log.info("Firmware upgrade: \(step, privacy: .public)")
            if step.hasPrefix("Writing firmware") {
                // Bootloader found: the ritual is over, swap the card for
                // live progress.
                self?.firmwareInstructions?.close()
                self?.firmwareInstructions = nil
                self?.flashProgress?.close()
                self?.flashProgress = FloatingAlert.show(title: "Upgrading firmware", text: step)
            } else {
                self?.flashProgress?.update(text: step)
            }
        } completion: { [weak self] result in
            guard let self else { return }
            self.firmwareInstructions?.close()
            self.firmwareInstructions = nil
            self.flashProgress?.close()
            self.flashProgress = nil
            self.statusItem.menu?.cancelTracking()
            self.setFirmwareStatus(nil)
            self.updateTingleiskItems()
            switch result {
            case .success(let message):
                FloatingAlert.show(
                    title: "Firmware upgrade complete",
                    text: message
                        + "\n\nNow power-cycle the ting: press the small button above "
                        + "the USB-C port, then push the handle to start it.")
            case .failure(let error):
                self.log.error("Firmware upgrade failed: \(String(describing: error))")
                self.presentError("Firmware upgrade failed", error)
            }
        }
    }

    /// Disk work runs on a background queue. The menu auto-closes the
    /// moment the item is clicked, so progress streams into a floating
    /// card (plus the log); the menu item just greys out.
    private var flashProgress: FloatingAlert?

    private func runFlasherOperation(_ operation: Flasher.Operation, title: String) {
        setFlashStatus("\(title): starting…")
        flashProgress?.close()
        flashProgress = FloatingAlert.show(title: title, text: "Starting…")
        Flasher.run(operation) { [weak self] step in
            self?.setFlashStatus(step)
            self?.flashProgress?.update(text: step)
            self?.log.info("\(title, privacy: .public): \(step, privacy: .public)")
        } completion: { [weak self] result in
            guard let self else { return }
            self.flashProgress?.close()
            self.flashProgress = nil
            self.statusItem.menu?.cancelTracking()
            self.setFlashStatus(nil)
            self.updateTingleiskItems()
            switch result {
            case .success(let message):
                FloatingAlert.show(
                    title: "\(title) complete",
                    text: message
                        + "\n\nNow power-cycle the ting: press the small button above "
                        + "the USB-C port, then push the handle to start it.")
            case .failure(let error):
                self.log.error("\(title, privacy: .public) failed: \(String(describing: error))")
                self.presentError("\(title) failed", error)
            }
        }
    }

    private func presentError(_ title: String, _ error: Error) {
        FloatingAlert.show(title: title, text: error.localizedDescription)
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
            FloatingAlert.show(
                title: "Launch at Login unavailable",
                text: "Launch at Login requires tingle to run as a bundled .app "
                    + "(it is currently running as a bare development binary).\n\n\(error.localizedDescription)")
        }
        updateLaunchAtLoginState()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
