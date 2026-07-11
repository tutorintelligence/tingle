import Foundation

/// Pure decision for how a trigger edge drives the app. Separates the
/// dictation LIFECYCLE (idempotent, must always run on a real release) from
/// dedup-gated ACTION firing.
///
/// The wedge bug this prevents: gating `stopDictation()` behind a
/// reconciler duplicate-check meant a real release whose "held" belief had
/// already flipped (rapid squeezing + beacon healing) returned early and
/// never stopped the session — leaving it wedged (red icon, no text) until
/// a multi-second force-abandon. A release must ALWAYS stop dictation.
public struct TriggerRouting {
    public struct Decision: Equatable {
        /// Mechanical switch bounce — ignore entirely.
        public var dropAsChatter = false
        /// New held state for the icon (nil = unchanged).
        public var setHeld: Bool?
        /// Always true on a non-chatter release (idempotent safety net).
        public var stopDictation = false
        public var releaseHeldKeys = false
        /// Only on a genuine press transition (never re-starts on a dup).
        public var startDictationOnPress = false
        /// Only on a genuine state change (don't re-fire mapped actions).
        public var fireMappedAction = false
    }

    /// - down: is this a triggerDown (vs triggerUp)?
    /// - held: the reconciler's current belief.
    /// - msSinceLastEdge / chatterMs: bounce filter.
    public static func decide(down: Bool, held: Bool,
                              msSinceLastEdge: Double, chatterMs: Double) -> Decision {
        var d = Decision()
        let isReversal = down != held
        if isReversal && msSinceLastEdge < chatterMs {
            d.dropAsChatter = true
            return d
        }
        d.setHeld = down
        if down {
            d.startDictationOnPress = isReversal
            d.fireMappedAction = isReversal
        } else {
            // Release: stop dictation + release keys UNCONDITIONALLY, even
            // when the reconciler already believed we were up. This is the
            // wedge fix — the session must never outlive the trigger.
            d.stopDictation = true
            d.releaseHeldKeys = true
            d.fireMappedAction = isReversal
        }
        return d
    }
}
