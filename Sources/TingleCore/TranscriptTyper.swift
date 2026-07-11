import Foundation

/// Pure live-dictation edit engine: tracks what has been typed into the
/// frontmost app so far and, as SpeechTranscriber hypotheses evolve, computes
/// the minimal keystroke edit (backspaces + append) to converge on the new
/// hypothesis — the standard live-dictation correction dance.
///
/// Corrections are strictly bounded to the current volatile region: text
/// committed by earlier finalized results (and anything the user typed before
/// dictation) is never backspaced over.
public struct TranscriptTyper {
    public struct Edit: Equatable {
        public init(backspaces: Int, append: String) { self.backspaces = backspaces; self.append = append }
        public var backspaces: Int
        public var append: String

        public var isEmpty: Bool { backspaces == 0 && append.isEmpty }
        public static let none = Edit(backspaces: 0, append: "")
    }

    /// Text committed by finalized results (never edited again).
    public init() {}
    public private(set) var committedText = ""
    /// What we have typed for the current volatile region.
    public private(set) var volatileTyped = ""
    /// Typed once, immediately before the first non-empty hypothesis — used
    /// for the leading space between consecutive dictation sessions. Skipped
    /// if the first hypothesis opens with closing punctuation.
    public var prefixPending = ""

    /// Feed a new hypothesis for the current volatile region (volatile
    /// results replace each other; a final result commits the region).
    /// Returns the edit to apply to the frontmost app.
    public mutating func update(hypothesis: String, isFinal: Bool) -> Edit {
        let typed = Array(volatileTyped)
        let hypo = Array(hypothesis)

        var common = 0
        while common < min(typed.count, hypo.count), typed[common] == hypo[common] {
            common += 1
        }
        var edit = Edit(
            backspaces: typed.count - common,   // never exceeds the volatile region
            append: String(hypo[common...])
        )
        if !prefixPending.isEmpty, let first = hypothesis.first {
            if !first.isPunctuation {
                committedText += prefixPending
                edit.append = prefixPending + edit.append
            }
            prefixPending = ""
        }

        if isFinal {
            committedText += hypothesis
            volatileTyped = ""
        } else {
            volatileTyped = hypothesis
        }
        return edit
    }

    /// The screen text changed under us (a keystroke/keyHold action typed
    /// while dictating): everything typed so far becomes untouchable —
    /// corrections can no longer safely backspace over it.
    public mutating func freezeVolatile() {
        committedText += volatileTyped
        volatileTyped = ""
    }

    /// End of dictation: whatever volatile text is on screen stays as-is.
    /// (The analyzer's finalization pass normally converts the last volatile
    /// region to a final result before this is called.)
    public mutating func finish() {
        committedText += volatileTyped
        volatileTyped = ""
    }

    /// Words inserted so far (for the "Inserted N words" status line).
    public var wordCount: Int {
        (committedText + volatileTyped)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }
}
