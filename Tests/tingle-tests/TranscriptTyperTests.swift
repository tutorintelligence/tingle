import Foundation
import TingleCore

func runTranscriptTyperTests() {
    do { // growing hypothesis types deltas only
        var typer = TranscriptTyper()
        expectEqual(typer.update(hypothesis: "hel", isFinal: false),
                    .init(backspaces: 0, append: "hel"), "typer: first delta")
        expectEqual(typer.update(hypothesis: "hello wor", isFinal: false),
                    .init(backspaces: 0, append: "lo wor"), "typer: growth delta")
    }
    do { // revision backspaces to divergence point only
        var typer = TranscriptTyper()
        _ = typer.update(hypothesis: "their", isFinal: false)
        expectEqual(typer.update(hypothesis: "there", isFinal: false),
                    .init(backspaces: 2, append: "re"), "typer: revision")
    }
    do { // corrections never reach committed text
        var typer = TranscriptTyper()
        _ = typer.update(hypothesis: "first segment.", isFinal: true)
        let edit = typer.update(hypothesis: "totally different", isFinal: false)
        expectEqual(edit.backspaces, 0, "typer: committed text is untouchable")
    }
    do { // freezeVolatile protects screen text after external typing
        var typer = TranscriptTyper()
        _ = typer.update(hypothesis: "draft words", isFinal: false)
        typer.freezeVolatile()
        let edit = typer.update(hypothesis: "new start", isFinal: false)
        expectEqual(edit.backspaces, 0, "typer: freeze blocks backspaces")
        expectEqual(edit.append, "new start", "typer: freeze then fresh append")
    }
    do { // between-takes prefix space applied exactly once
        var typer = TranscriptTyper()
        typer.prefixPending = " "
        expectEqual(typer.update(hypothesis: "next", isFinal: false).append, " next",
                    "typer: prefix space once")
        expectEqual(typer.update(hypothesis: "next take", isFinal: false).append, " take",
                    "typer: prefix not repeated")
    }
    do { // prefix skipped when hypothesis opens with punctuation
        var typer = TranscriptTyper()
        typer.prefixPending = " "
        expectEqual(typer.update(hypothesis: ", and", isFinal: false).append, ", and",
                    "typer: no prefix before punctuation")
    }
    do { // erase math: committedText.count == exactly what was typed
        var typer = TranscriptTyper()
        typer.prefixPending = " "
        _ = typer.update(hypothesis: "abc", isFinal: true)
        _ = typer.update(hypothesis: "de", isFinal: false)
        typer.finish()
        expectEqual(typer.committedText.count, 6, "typer: erase character count")
    }
}
