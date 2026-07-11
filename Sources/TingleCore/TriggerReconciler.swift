import Foundation

/// Pure owner of the Mac's belief about the handle ("held"), reconciling
/// two information sources:
///
///   - trigger EDGES (down/up events from either backend) — authoritative
///     but lossy: audio decode errors and backend handovers (USB plug/
///     unplug) can drop them, leaving belief stuck.
///   - state-bearing BEACONS (~2s heartbeat carrying true handle state on
///     both transports) — low-rate but loss-proof.
///
/// When a beacon contradicts the belief, the reconciler emits the missing
/// edge so downstream (dictation, icon) always converges on the device's
/// truth within one beacon period. This is "piggyback the true state"
/// semantics with edge-level responsiveness.
public struct TriggerReconciler {
    public private(set) var held = false

    public init() {}

    public enum Synthesis: Equatable {
        case none
        case synthesizeDown
        case synthesizeUp
    }

    /// An authoritative edge arrived; belief follows it directly.
    /// Returns false for redundant edges (already in that state) so
    /// callers can drop duplicates.
    public mutating func apply(edgeDown: Bool) -> Bool {
        guard edgeDown != held else { return false }
        held = edgeDown
        return true
    }

    /// A state-bearing beacon arrived. If it contradicts belief, the
    /// caller must inject the returned synthetic edge through the normal
    /// event path (which will call apply(edgeDown:) and flip belief).
    public func reconcile(beaconSaysHeld: Bool) -> Synthesis {
        if beaconSaysHeld == held { return .none }
        return beaconSaysHeld ? .synthesizeDown : .synthesizeUp
    }
}
