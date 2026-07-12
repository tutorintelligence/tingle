import AppKit

/// Non-modal replacement for NSAlert.runModal(). A modal session parks the
/// main run loop, which starves the whole event pipeline — dictation,
/// serial polling, menu updates all freeze while the popup sits open
/// (observed with the firmware-upgrade failure alert, 2026-07-11). This
/// floating panel informs without blocking anything.
final class FloatingAlert: NSObject, NSWindowDelegate {
    private static var live: [FloatingAlert] = []
    private let panel: NSPanel
    private let body: NSTextField

    /// `showsOK: false` = a progress card: no confirm button while the
    /// operation runs (an OK on a live progress card invited dismissing
    /// it mid-flash); the title-bar close remains as the escape hatch.
    @discardableResult
    static func show(title: String, text: String, showsOK: Bool = true) -> FloatingAlert {
        let alert = FloatingAlert(title: title, text: text, showsOK: showsOK)
        live.append(alert)
        alert.panel.center()
        alert.panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return alert
    }

    /// Programmatic dismissal — used when the flow the panel is guiding
    /// advances on its own (e.g. the bootloader disk appeared).
    func close() {
        panel.close()
    }

    /// Live progress: swap the body text in place (used by Flash EP and
    /// the firmware flow to stream step updates into one card).
    func update(text: String) {
        body.stringValue = text
    }

    private init(title: String, text: String, showsOK: Bool) {
        let width: CGFloat = 400
        let pad: CGFloat = 20

        body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 12)
        body.preferredMaxLayoutWidth = width - pad * 2
        let bodyHeight = body.sizeThatFits(
            NSSize(width: width - pad * 2, height: .greatestFiniteMagnitude)).height

        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 13)

        let button = NSButton(title: "OK", target: nil, action: #selector(dismiss))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.isHidden = !showsOK

        let height = pad + 22 + 8 + bodyHeight + (showsOK ? 12 + 32 : 6) + pad / 2
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "tingle"
        panel.level = .floating
        panel.isReleasedWhenClosed = false

        super.init()
        button.target = self
        panel.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        heading.frame = NSRect(x: pad, y: height - pad - 22, width: width - pad * 2, height: 22)
        body.frame = NSRect(x: pad, y: height - pad - 22 - 8 - bodyHeight, width: width - pad * 2, height: bodyHeight)
        button.frame = NSRect(x: width - pad - 80, y: pad / 2, width: 80, height: 32)
        content.addSubview(heading)
        content.addSubview(body)
        content.addSubview(button)
        panel.contentView = content
    }

    @objc private func dismiss() {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.live.removeAll { $0 === self }
    }
}
