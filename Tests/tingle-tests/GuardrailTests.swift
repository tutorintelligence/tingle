import CoreGraphics
import Foundation
import TingleCore

func runGuardrailTests() {
    // Erase guard: a take is erasable only while nothing has moved the
    // on-screen text since it ended (real typing, a click, or a keystroke
    // action all count as moves).
    let takeEnd = Date()
    expect(!DictationController.eraseInvalidated(takeEndedAt: takeEnd, lastContentMoveAt: nil),
           "guard: no input ever — erasable")
    expect(!DictationController.eraseInvalidated(
        takeEndedAt: takeEnd, lastContentMoveAt: takeEnd.addingTimeInterval(-10)),
        "guard: input BEFORE the take — erasable")
    expect(DictationController.eraseInvalidated(
        takeEndedAt: takeEnd, lastContentMoveAt: takeEnd.addingTimeInterval(2)),
        "guard: input after the take — blocked")

    // Synthetic tagging: events posted from tingle's tagged source carry
    // the marker; a plain event does not. This is what keeps the user-
    // input monitor from cancelling the rewrite because of tingle's OWN
    // typing (which would make every rewrite cancel itself).
    if let source = SyntheticEvents.source(),
       let tagged = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
        expect(SyntheticEvents.isSynthetic(tagged), "guard: tagged source marks events")
    } else {
        expect(false, "guard: synthetic source construction")
    }
    if let plain = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                           virtualKey: 0, keyDown: true) {
        expect(!SyntheticEvents.isSynthetic(plain), "guard: plain events unmarked")
    }

    // Diagnostics report assembly: every triage-critical fact appears.
    let snapshot = Diagnostics.Snapshot(
        appVersion: "9.9.9", buildMode: "installed app", macOSVersion: "26.5",
        backendState: "ting on CUBILUX Line IN", weakSignal: true,
        micGranted: true, accessibilityGranted: false,
        rewriteModelAvailable: false, pinnedInputUID: nil,
        lastBeaconLevelDB: -7.1, micMode: "Voice Isolation (should be inert for tingle's raw capture)",
        inputDevices: ["Line IN", "MIC IN"],
        transitions: [(Date(), "Searching for ting…")],
        configText: "extraVocabulary = []")
    let report = Diagnostics.report(snapshot, recentLog: "12:00:01 E weak chirp signal")
    for needle in ["9.9.9", "WEAK SIGNAL", "accessibility MISSING", "Voice Isolation",
                   "unavailable (Apple Intelligence off or unsupported)",
                   "-7.1 dBFS", "Line IN, MIC IN", "Searching for ting…",
                   "extraVocabulary = []", "weak chirp signal"] {
        expect(report.contains(needle), "guard: diagnostics report carries '\(needle)'")
    }
}
