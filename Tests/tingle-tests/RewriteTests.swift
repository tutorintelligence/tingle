import Foundation
import TingleCore

func runRewriteTests() {
    // stripFillers: deterministic, tidy commas, keeps real words.
    expectEqual(RewritePrompt.stripFillers("Um, I think, uh, this works."),
                "I think, this works.", "rewrite: fillers stripped with comma cleanup")
    expectEqual(RewritePrompt.stripFillers("The drum is near the umbrella"),
                "The drum is near the umbrella", "rewrite: filler strip is token-bounded")
    expectEqual(RewritePrompt.stripFillers("Okay. Um, so it works. Er, mostly."),
                "Okay. so it works. mostly.", "rewrite: leading fillers after sentence ends")

    // postProcess: preamble and quote stripping.
    expectEqual(RewritePrompt.postProcess("Sure, here's the cleaned version:\nHello world."),
                "Hello world.", "rewrite: preamble stripped")
    expectEqual(RewritePrompt.postProcess("\"Hello world.\""),
                "Hello world.", "rewrite: wrapping quotes stripped")

    // acceptable: rejects answers/hallucinations, passes edits.
    expect(!RewritePrompt.acceptable(input: "why does the trigger lag so much on mash",
                                     output: "I understand your frustration. We are working on improving responsiveness."),
           "rewrite: gate rejects the model answering the text")
    expect(RewritePrompt.acceptable(input: "so the trigger lags on mash and that feels bad",
                                    output: "The trigger lags on mash, and that feels bad."),
           "rewrite: gate passes a faithful edit")
    expect(!RewritePrompt.acceptable(input: "short take here", output: ""),
           "rewrite: gate rejects empty output")

    // eligibility band
    expect(!RewritePrompt.eligible("too short"), "rewrite: tiny takes skipped")
    expect(RewritePrompt.eligible("this take has enough words to be worth a polish"),
           "rewrite: normal takes eligible")

    // instruction assembly reflects switches
    var c = RewriteConfig()
    c.enabled = true
    c.technicalFormatting = true
    let inst = RewritePrompt.instructions(config: c, vocabulary: ["TOML", "Codex"])
    expect(inst.contains("dash dash force"), "rewrite: technicalFormatting fragment present")
    expect(inst.contains("TOML, Codex"), "rewrite: vocabulary injected")
    c.correctVocabulary = false
    expect(!RewritePrompt.instructions(config: c, vocabulary: ["TOML"]).contains("TOML"),
           "rewrite: vocabulary omitted when disabled")

    expect(RewritePrompt.postProcess("that test is **fucked** beyond repair") == "that test is fucked beyond repair",
           "rewrite: postProcess strips markdown emphasis")

    // Profanity is never censored: exact-token backstop against the
    // model's safety training, which sometimes silently swaps a swear
    // word for a tame one (passes every statistical check).
    expect(RewritePrompt.gate(
        input: "this fucking parser breaks on every damn input",
        output: "This failing parser breaks on every single input.") != nil,
        "rewrite: gate rejects silent profanity substitution")
    expect(RewritePrompt.gate(
        input: "the build is fucked again, what the hell",
        output: "The build is fucked again, what the hell.") == nil,
        "rewrite: gate passes preserved profanity")
    expect(RewritePrompt.gate(
        input: "this shit is shit",
        output: "This shit is broken.") != nil,
        "rewrite: gate rejects partial censorship (count drop)")
    expect(RewritePrompt.gate(
        input: "clean text with no swearing at all here",
        output: "Clean text with no swearing at all here.") == nil,
        "rewrite: gate ignores profanity rule on clean text")

    // Refusal boilerplate is rejected even when it embeds a revised
    // transcript (which defeats word retention)...
    expect(RewritePrompt.gate(
        input: "why is this limit so damn low, fill me in on what is going on here",
        output: "I apologize, but I cannot comply with your request to edit the transcript as it contains explicit language. Here's a revised version of the transcript: why is this limit so low, fill me in on what is going on here") != nil,
        "rewrite: gate rejects refusal with embedded revision")
    // ...but the SPEAKER dictating refusal-sounding text stays editable.
    expect(RewritePrompt.gate(
        input: "and then the model said i cannot comply with your request, which is hilarious",
        output: "And then the model said, I cannot comply with your request, which is hilarious.") == nil,
        "rewrite: gate allows refusal phrases the speaker dictated")

    runRewriteEditTests()
}

/// What a text field does with the posted edit: the cursor is at the end,
/// so backspaces eat from the tail, then the append is typed. Any edit
/// RewritePrompt.edit produces must reconstruct the target through THIS
/// model — that is the invariant the first live test broke (a common
/// suffix was kept in place, but backspaces cannot reach past it).
private func simulateField(_ old: String, _ edit: TranscriptTyper.Edit) -> String {
    String(Array(old).dropLast(edit.backspaces)) + edit.append
}

private func expectEdit(_ old: String, _ new: String, _ label: String) {
    let edit = RewritePrompt.edit(from: old, to: new)
    expect(simulateField(old, edit) == new, "rewrite edit reconstructs: \(label)")
    expect(edit.backspaces <= Array(old).count, "rewrite edit bounded: \(label)")
}

func runRewriteEditTests() {
    // THE live bug: change strictly in the middle, identical head and
    // tail. The suffix-aware diff deleted 2 chars at the cursor and
    // typed the middle there; prefix-only must delete back through the
    // tail (14 backspaces) and retype it.
    let old = "so basically the the decoder needs a pilot lock"
    let new = "so basically the decoder needs a pilot lock"
    expectEdit(old, new, "mid-text dedup")
    let bugEdit = RewritePrompt.edit(from: old, to: new)
    expect(bugEdit.backspaces == Array(old).count - "so basically the".count - 1,
           "rewrite edit deletes through the unchanged tail")

    // Change at the very end — minimal backspaces, no over-deletion.
    expectEdit("send it to jane", "send it to Jane.", "tail-only change")
    let tail = RewritePrompt.edit(from: "send it to jane", to: "send it to Jane.")
    expect(tail.backspaces == 4, "rewrite edit tail change is minimal")

    // No change — must be a no-op, not a full retype.
    let noop = RewritePrompt.edit(from: "unchanged text", to: "unchanged text")
    expect(noop.backspaces == 0 && noop.append.isEmpty, "rewrite edit no-op")

    // Head change — nothing in common, full clear + retype.
    expectEdit("Um so the plan", "So the plan", "head change")

    // Multiple scattered changes (real model behavior: punctuation +
    // capitalization all over) — single prefix cut still reconstructs.
    expectEdit(
        "okay so um i think the symbol detector uh needs a level floor and also the beacon period is like three point two seconds",
        "Okay, so I think the SymbolDetector needs a level floor, and the beacon period is 3.2 seconds.",
        "scattered edits")

    // Unicode/grapheme safety: emoji and combining marks count as one
    // backspace each in a Cocoa text field.
    expectEdit("cafe\u{301} rocket \u{1F680} go", "cafe\u{301} rocket \u{1F680} go now", "grapheme append")
    expectEdit("we ship \u{1F680}\u{1F680} tmrw", "we ship \u{1F680} tomorrow", "grapheme mid-change")

    // Empty target (model gate should prevent this upstream, but the
    // edit itself must still be well-formed).
    let clear = RewritePrompt.edit(from: "abc", to: "")
    expect(clear.backspaces == 3 && clear.append.isEmpty, "rewrite edit clear")
}
