import AppKit
import CoreGraphics

/// Every keyboard/mouse event tingle posts is tagged through its event
/// source so the user-input monitor can tell machine typing from the
/// human's. CGEventSource.userData flows into each posted event's
/// .eventSourceUserData field.
public enum SyntheticEvents {
    public static let marker: Int64 = 0x54_49_4E_47   // "TING"

    public static func source() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = marker
        return source
    }

    public static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}

/// Global monitor for REAL user input — a keydown or click anywhere means
/// the on-screen text can no longer be assumed to end with the last take,
/// so every deferred automatic edit (the rewrite pass, green-button erase)
/// must stand down. tingle's own synthetic events are tagged and ignored.
///
/// Uses the accessibility permission tingle already holds; if it isn't
/// granted the monitor simply never fires, which fails safe (the erase
/// path independently requires accessibility before typing anything).
final class UserInputMonitor {
    var onUserInput: (() -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if let cg = event.cgEvent, SyntheticEvents.isSynthetic(cg) { return }
            DispatchQueue.main.async { self?.onUserInput?() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}
