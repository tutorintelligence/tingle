import AppKit
import os

/// Public entry point: the executable target is a one-liner calling this.
public enum TingleApp {
    /// Held for the process lifetime; the advisory lock it carries enforces
    /// the single-instance rule.
    private static var lockFD: Int32 = -1

    /// Only one tingle may run at a time (dev binary OR installed .app):
    /// two instances would double-type dictation and fight over the serial
    /// port. LaunchServices only dedupes Finder/`open` launches, so a
    /// directly-exec'd dev binary needs its own guard: an advisory flock on
    /// a well-known path, held for the process lifetime.
    private static func exitIfAlreadyRunning() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tingle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("tingle.lock").path
        lockFD = open(path, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else { return }  // can't lock -> don't block launch
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            Logger(subsystem: Log.subsystem, category: "app")
                .error("another tingle instance holds \(path, privacy: .public); exiting")
            exit(0)
        }
    }

    public static func main() {
        // Bundle self-test (used by CI on the assembled .app): verify the
        // device payload is loadable from this build's real resource layout,
        // print its size, and exit — regression guard for the Flash EP
        // crash where a CI-built app couldn't find its resource bundle.
        if ProcessInfo.processInfo.environment["TINGLE_PAYLOAD_CHECK"] != nil {
            do {
                let payload = try Flasher.devicePayload()
                print("payload ok: \(payload.count) bytes")
                exit(0)
            } catch {
                print("payload missing: \(error)")
                exit(1)
            }
        }
        exitIfAlreadyRunning()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}


enum Log {
    static let subsystem = "com.tutorintelligence.tingle"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var configStore: ConfigStore!
    private var actionRunner: ActionRunner!
    private var coordinator: DetectionCoordinator!
    private var dictation: DictationController!
    private var statusItemController: StatusItemController!
    private let userInputMonitor = UserInputMonitor()
    private var permissions: PermissionsMonitor!

    private let log = Logger(subsystem: Log.subsystem, category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        configStore = ConfigStore()
        actionRunner = ActionRunner()
        coordinator = DetectionCoordinator(configStore: configStore)
        dictation = DictationController(
            configStore: configStore,
            coordinator: coordinator,
            actionRunner: actionRunner
        )

        wireTriggerHints(to: coordinator)
        coordinator.onEvent = { [weak self] event in
            guard let self else { return }
            self.handle(event: event)
        }

        // Wire the menu before starting so the initial state change is observed.
        permissions = PermissionsMonitor()
        statusItemController = StatusItemController(
            configStore: configStore, coordinator: coordinator, permissions: permissions)
        userInputMonitor.onUserInput = { [weak self] in
            self?.dictation.contentMoved()
        }
        userInputMonitor.start()
        dictation.onRewriteActive = { [weak self] active in
            self?.statusItemController?.setRewriteActive(active)
        }
        dictation.onStatusChange = { [weak self] text in
            self?.statusItemController?.setDictationStatus(text)
        }
        coordinator.start()
        permissions.startMonitoring()
        // Surface any missing permission NOW, with the system dialogs that
        // deep-link to the right pane — never let the user discover it as a
        // squeeze that types nothing.
        permissions.promptForMissing()

        log.info("tingle started (config at \(ConfigStore.configURL.path, privacy: .public))")
    }

    /// Owns the belief about the handle: edges update it, state-bearing
    /// beacons reconcile it (synthesizing edges lost to decode errors or
    /// backend handovers such as USB plug/unplug). Semantics: piggyback
    /// the device's TRUE state; edges give responsiveness, beacons give
    /// eventual correctness within one heartbeat.
    private var reconciler = TriggerReconciler()
    /// Chatter filter: the trigger switch bounces (rapid down/up within a
    /// tick or two). A reversing edge within this window is mechanical
    /// noise, not a real press/release, and is dropped. Real squeezes last
    /// far longer than switch bounce.
    private var lastTriggerEdgeAt = Date.distantPast
    private let triggerChatterWindow: TimeInterval = 0.09

    func wireTriggerHints(to coordinator: DetectionCoordinator) {
        coordinator.onTriggerHint = { [weak self] held in
            guard let self else { return }
            switch self.reconciler.reconcile(beaconSaysHeld: held) {
            case .none:
                break
            case .synthesizeUp:
                self.log.warning("beacon says released but belief is held — synthesizing missed triggerUp")
                self.handle(event: .triggerUp)
            case .synthesizeDown:
                self.log.warning("beacon says held but belief is released — synthesizing missed triggerDown")
                self.handle(event: .triggerDown)
            }
        }
    }

    private func handle(event: TingEvent) {
        // Any real user gesture invalidates a pending dictation rewrite —
        // especially orange (send): text that may already be submitted
        // must never be edited afterward.
        switch event {
        case .beacon, .beaconHeld, .beaconSensed: break
        default: dictation.cancelPendingRewrite()
        }
        log.info("event: \(event.logDescription, privacy: .public)")

        if event == .triggerDown || event == .triggerUp {
            let now = Date()
            let down = event == .triggerDown
            let decision = TriggerRouting.decide(
                down: down, held: reconciler.held,
                msSinceLastEdge: now.timeIntervalSince(lastTriggerEdgeAt) * 1000,
                chatterMs: triggerChatterWindow * 1000
            )
            if decision.dropAsChatter {
                log.info("trigger chatter dropped (\(event.logDescription, privacy: .public))")
                return
            }
            _ = reconciler.apply(edgeDown: down)   // keep belief in sync for beacon healing
            lastTriggerEdgeAt = now

            // Lifecycle first, UNCONDITIONALLY: a release must always stop
            // dictation (both idempotent) so a session can never wedge past
            // the trigger being let go.
            if decision.releaseHeldKeys { actionRunner.releaseHeldKeys() }
            if decision.stopDictation { dictation.stopDictation() }
            if let held = decision.setHeld { statusItemController.setTriggerHeld(held) }

            // Only a genuine transition fires the mapped action / starts a
            // session (dedup: don't double-fire on a repeated edge).
            guard decision.fireMappedAction else { return }
            if decision.startDictationOnPress, configStore.config.action(for: event) == .dictate {
                dictation.startDictation()
                return
            }
        }

        guard let action = configStore.config.action(for: event) else {
            log.info("no action mapped for \(event.mappingKey ?? "unmappable event", privacy: .public)")
            return
        }

        // dictate only starts on triggerDown (handled above); ignore elsewhere.
        if action == .dictate {
            if event != .triggerDown {
                log.warning("\"dictate\" is only valid on the triggerDown mapping; ignoring on \(event.mappingKey ?? "?", privacy: .public)")
            }
            return
        }

        if action == .eraseDictation {
            dictation.eraseLastSession()
            return
        }

        // A typing action while dictation is live changes the text field
        // under the typer; freeze what's on screen first so corrections
        // can't backspace over it (the overwrite bug).
        switch action {
        case .keystroke, .keyHold:
            dictation.contentMoved()
        default:
            break
        }

        actionRunner.run(action)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave a keyHold key stuck down when quitting.
        actionRunner?.releaseHeldKeys()
        coordinator?.stop()
    }
}
