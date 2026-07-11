import AppKit
import os

/// Public entry point: the executable target is a one-liner calling this.
public enum TingleApp {
    public static func main() {
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
        statusItemController = StatusItemController(configStore: configStore, coordinator: coordinator)
        dictation.onStatusChange = { [weak self] text in
            self?.statusItemController?.setDictationStatus(text)
        }
        coordinator.start()

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
        log.info("event: \(event.logDescription, privacy: .public)")

        if event == .triggerDown || event == .triggerUp {
            let now = Date()
            let down = event == .triggerDown
            let isReversal = down != reconciler.held
            if isReversal, now.timeIntervalSince(lastTriggerEdgeAt) < triggerChatterWindow {
                log.info("trigger chatter dropped (\(event.logDescription, privacy: .public) \(Int(now.timeIntervalSince(self.lastTriggerEdgeAt) * 1000))ms after last edge)")
                return
            }
            guard reconciler.apply(edgeDown: down) else { return }   // duplicate
            lastTriggerEdgeAt = now
        }

        // Handle released: let go of any keyHold keys and finalize a live
        // dictation session first (push-to-talk pairing is implicit), then
        // run whatever plain action triggerUp itself maps to.
        if event == .triggerUp {
            actionRunner.releaseHeldKeys()
            dictation.stopDictation()
            statusItemController.setTriggerHeld(false)
        }
        if event == .triggerDown {
            statusItemController.setTriggerHeld(true)
        }

        guard let action = configStore.config.action(for: event) else {
            log.info("no action mapped for \(event.mappingKey ?? "unmappable event", privacy: .public)")
            return
        }

        // dictate is only valid on triggerDown (release pairing is implicit).
        if action == .dictate {
            if event == .triggerDown {
                dictation.startDictation()
            } else {
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
            dictation.externalTypingWillOccur()
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
