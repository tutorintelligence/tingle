import Foundation

/// Pure state machine for beacon-based auto-discovery of the ting's audio
/// input (device beacon = chirp pair (1,3) / "EVT beacon", every ~2s while
/// its chirp queue is idle).
///
/// Scanning: dwell on each ranked candidate device for `dwellSeconds` (two
/// beacon periods + margin) until a beacon (or any decoded event) arrives,
/// then lock. Locked: track freshness — no beacon for `staleSeconds` (3
/// missed) shows "ting not detected"; after `rescanSeconds` more, resume
/// scanning from the top candidate. Any decoded event counts as liveness.
///
/// The caller supplies time and the candidate count; this type performs no
/// I/O so the transitions are unit-testable.
public struct BeaconScanner: Equatable {
    public struct Timing: Equatable {
        /// Listen time per candidate. Must exceed WORST-CASE acquisition:
        /// engine spin-up (~0.5s) + up to one full beacon period waiting
        /// for the first beacon (2s) + two more periods for the 3-beacon
        /// pilot lock (4s) + decode margin. The old 5s dwell (6s effective
        /// on the 2s driver poll) was commensurate with the 2s beacon
        /// period, so an unlucky phase repeated identically every rotation
        /// — wake-from-sleep took 30-60s while the ting's clock drift
        /// slowly walked the phase (observed 2026-07-12).
        public var dwellSeconds: TimeInterval = 7
        /// Extra dwell granted while a pilot acquisition is in progress
        /// (provisional beacons arriving): never rotate away mid-lock.
        public var acquisitionHoldSeconds: TimeInterval = 8
        /// Locked → stale after this long without a beacon/event (3 missed).
        public var staleSeconds: TimeInterval = 6
        /// Stale for this much longer → resume scanning.
        public var rescanSeconds: TimeInterval = 15

        public init() {}
    }

    public enum Phase: Equatable {
        case scanning(index: Int, since: TimeInterval)
        /// A beacon arrived on a lower-ranked candidate. Chirps bleed across
        /// jacks on multi-input boxes (Cubilux MIC IN hears Line IN's tones),
        /// so before committing, audition the top-ranked candidate for one
        /// dwell; hear it there → lock the top, silence → fall back.
        case verifyingTop(fallbackIndex: Int, since: TimeInterval)
        case locked(lastHeard: TimeInterval)
    }

    public enum Decision: Equatable {
        case stay
        /// Move the audio backend to the candidate at this index.
        case switchCandidate(index: Int)
        /// Lock lost for good; restart scanning from the top candidate.
        case resumeScan
    }

    public let timing: Timing
    public private(set) var phase: Phase

    public init(timing: Timing = Timing(), now: TimeInterval) {
        self.timing = timing
        self.phase = .scanning(index: 0, since: now)
    }

    public var isLocked: Bool {
        if case .locked = phase { return true }
        return false
    }

    /// While scanning/verifying, the candidate index currently being
    /// listened to (clamped to the live candidate list).
    public func scanIndex(candidateCount: Int) -> Int? {
        guard candidateCount > 0 else { return nil }
        switch phase {
        case .scanning(let index, _): return min(index, candidateCount - 1)
        case .verifyingTop: return 0
        case .locked: return nil
        }
    }

    public var lastHeard: TimeInterval? {
        guard case .locked(let lastHeard) = phase else { return nil }
        return lastHeard
    }

    public func isStale(now: TimeInterval) -> Bool {
        guard case .locked(let lastHeard) = phase else { return false }
        return now - lastHeard >= timing.staleSeconds
    }

    /// A beacon — or any decoded ting event — arrived on the current device.
    /// Returns a device switch when the hear is suspect (crossbleed check).
    public mutating func heard(now: TimeInterval, candidateCount: Int) -> Decision {
        switch phase {
        case .scanning(let index, _) where index > 0 && candidateCount > 1:
            phase = .verifyingTop(fallbackIndex: index, since: now)
            return .switchCandidate(index: 0)
        case .scanning, .verifyingTop, .locked:
            phase = .locked(lastHeard: now)
            return .stay
        }
    }

    /// The device being scanned/locked disappeared; restart scanning now.
    public mutating func deviceLost(now: TimeInterval) {
        phase = .scanning(index: 0, since: now)
    }

    /// Periodic driver tick. Returns what the audio plumbing should do.
    /// `acquiring` = the detector is mid-acquisition on the current device
    /// (provisional beacons arriving) — extends the dwell so the scan
    /// never rotates away one beacon short of a lock.
    public mutating func tick(now: TimeInterval, candidateCount: Int, acquiring: Bool = false) -> Decision {
        switch phase {
        case .scanning(let index, let since):
            guard candidateCount > 0 else { return .stay }
            if index >= candidateCount {
                // Candidate list shrank under us; restart at the top.
                phase = .scanning(index: 0, since: now)
                return .switchCandidate(index: 0)
            }
            let limit = acquiring
                ? timing.dwellSeconds + timing.acquisitionHoldSeconds
                : timing.dwellSeconds
            if now - since >= limit {
                let next = (index + 1) % candidateCount
                phase = .scanning(index: next, since: now)
                return .switchCandidate(index: next)
            }
            return .stay
        case .verifyingTop(let fallbackIndex, let since):
            if now - since >= timing.dwellSeconds {
                // Top candidate stayed silent: the original hear was real.
                let index = min(fallbackIndex, max(candidateCount - 1, 0))
                phase = .locked(lastHeard: now)
                return .switchCandidate(index: index)
            }
            return .stay
        case .locked(let lastHeard):
            if now - lastHeard >= timing.staleSeconds + timing.rescanSeconds {
                phase = .scanning(index: 0, since: now)
                return .resumeScan
            }
            return .stay
        }
    }
}
