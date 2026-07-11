import Foundation
import TingleCore

func runTriggerRoutingTests() {
    let chatter = 90.0

    // Genuine press: start dictation, fire action, hold.
    do {
        let d = TriggerRouting.decide(down: true, held: false, msSinceLastEdge: 500, chatterMs: chatter)
        expect(!d.dropAsChatter, "routing: real press not chatter")
        expect(d.startDictationOnPress, "routing: press starts dictation")
        expect(d.fireMappedAction, "routing: press fires action")
        expectEqual(d.setHeld, true, "routing: press sets held")
        expect(!d.stopDictation, "routing: press does not stop")
    }

    // Genuine release: stop dictation, release keys, fire release action.
    do {
        let d = TriggerRouting.decide(down: false, held: true, msSinceLastEdge: 3000, chatterMs: chatter)
        expect(d.stopDictation, "routing: release stops dictation")
        expect(d.releaseHeldKeys, "routing: release frees keys")
        expectEqual(d.setHeld, false, "routing: release clears held")
        expect(!d.startDictationOnPress, "routing: release never starts")
    }

    // THE WEDGE FIX: a release whose held-belief already flipped to false
    // (desynced by rapid squeezing / beacon healing) MUST still stop
    // dictation — the old dedup dropped it and the session wedged.
    do {
        let d = TriggerRouting.decide(down: false, held: false, msSinceLastEdge: 3000, chatterMs: chatter)
        expect(!d.dropAsChatter, "routing: desynced release is not chatter")
        expect(d.stopDictation, "routing: desynced release STILL stops dictation (wedge fix)")
        expect(!d.fireMappedAction, "routing: desynced release doesn't re-fire the mapped action")
    }

    // A duplicate press (held already true) must NOT restart a session.
    do {
        let d = TriggerRouting.decide(down: true, held: true, msSinceLastEdge: 3000, chatterMs: chatter)
        expect(!d.startDictationOnPress, "routing: duplicate press doesn't restart")
        expect(!d.fireMappedAction, "routing: duplicate press doesn't re-fire")
    }

    // Chatter: a fast reversal is bounce — drop it entirely.
    do {
        let d = TriggerRouting.decide(down: false, held: true, msSinceLastEdge: 20, chatterMs: chatter)
        expect(d.dropAsChatter, "routing: fast reversal is chatter")
        expect(!d.stopDictation, "routing: chatter changes nothing")
    }

    // A same-direction 'duplicate' arriving fast is NOT chatter (chatter is
    // only a reversal); it still must drive the idempotent stop on release.
    do {
        let d = TriggerRouting.decide(down: false, held: false, msSinceLastEdge: 20, chatterMs: chatter)
        expect(!d.dropAsChatter, "routing: non-reversal is never chatter")
        expect(d.stopDictation, "routing: fast desynced release still stops")
    }
}
