import Foundation
import TingleCore

func runBeaconScannerTests() {
    let timing = BeaconScanner.Timing()

    // The dwell must fit WORST-CASE pilot acquisition regardless of beacon
    // phase: engine spin-up (~0.5s) + up to one beacon period waiting for
    // the first beacon (2s) + two more periods (4s) + decode margin. The
    // regression: a 5s dwell (6s effective on the 2s driver poll) was both
    // too short for the worst phase AND commensurate with the 2s beacon
    // period, so the losing phase repeated identically every rotation —
    // 30-60s wakes while clock drift crawled the phase (2026-07-12).
    expect(timing.dwellSeconds >= 0.5 + 2.0 + 4.0 + 0.3,
           "scanner: dwell fits worst-case 3-beacon acquisition")

    // Rotation at dwell expiry when nothing is happening.
    var s = BeaconScanner(now: 0)
    expectEqual(s.tick(now: timing.dwellSeconds - 0.1, candidateCount: 2), .stay,
                "scanner: stays within dwell")
    expectEqual(s.tick(now: timing.dwellSeconds + 0.1, candidateCount: 2),
                .switchCandidate(index: 1), "scanner: rotates after dwell")

    // Acquisition hold: provisional beacons arriving on the current device
    // extend the dwell — never rotate away one beacon short of a lock.
    s = BeaconScanner(now: 0)
    expectEqual(s.tick(now: timing.dwellSeconds + 0.1, candidateCount: 2, acquiring: true),
                .stay, "scanner: acquisition holds the dwell open")
    expectEqual(s.tick(now: timing.dwellSeconds + timing.acquisitionHoldSeconds - 0.1,
                       candidateCount: 2, acquiring: true),
                .stay, "scanner: hold persists while acquiring")

    // ...but the hold is capped, so a noise source that keeps producing
    // provisional-but-never-locking beacons cannot pin the scan forever.
    expectEqual(s.tick(now: timing.dwellSeconds + timing.acquisitionHoldSeconds + 0.1,
                       candidateCount: 2, acquiring: true),
                .switchCandidate(index: 1), "scanner: acquisition hold is capped")

    // A hold that ends without a lock resumes normal rotation timing.
    s = BeaconScanner(now: 0)
    _ = s.tick(now: 2, candidateCount: 2, acquiring: true)
    expectEqual(s.tick(now: timing.dwellSeconds + 0.1, candidateCount: 2, acquiring: false),
                .switchCandidate(index: 1),
                "scanner: rotation resumes when acquisition stops")

    // End-to-end wake simulation at the WORST rotation phase: the ting
    // (device 0, Line IN — ranking puts it on top) wakes right AFTER the
    // scan rotated away to device 1. The scan must come back and lock in
    // that single dwell: first beacon up to 2s after arrival, two more
    // periods to lock, acquisition hold covering the overrun.
    s = BeaconScanner(now: 0)
    var currentIndex = 0
    var switchedAt = 0.0
    let wakeAt = timing.dwellSeconds + 2.1          // just left device 0
    var now = 0.0
    var lockedAt: Double?
    while now < 60 {
        now += 2                                     // 2s driver poll
        let hearing = currentIndex == 0 && now >= wakeAt
        let firstBeacon = max(switchedAt, wakeAt) + 1.9   // worst in-dwell phase
        let acquiring = hearing && now >= firstBeacon
        if hearing, now >= firstBeacon + 4.0 {       // third beacon decoded
            _ = s.heard(now: now, candidateCount: 2)
            lockedAt = now
            break
        }
        switch s.tick(now: now, candidateCount: 2, acquiring: acquiring) {
        case .switchCandidate(let index):
            currentIndex = index
            switchedAt = now
        case .stay, .resumeScan:
            break
        }
    }
    expect(s.isLocked, "scanner: worst-phase wake locks")
    if let lockedAt {
        expect(lockedAt - wakeAt <= 2 * timing.dwellSeconds + 8,
               "scanner: worst-phase wake locks within one rotation (took \(lockedAt - wakeAt)s from wake)")
    }

    runCampingTests()
}

/// Camping: when a lock goes quiet (ting asleep), sit on the locked device
/// with capture running instead of rotating — rotation blinked the macOS
/// mic indicator every dwell, all night (Josh, 2026-07-12).
private func runCampingTests() {
    let timing = BeaconScanner.Timing()
    let quiet = timing.staleSeconds + timing.rescanSeconds

    // Lock on device 0, go quiet: camps there instead of rescanning.
    var s = BeaconScanner(now: 0)
    _ = s.heard(now: 1, candidateCount: 2)
    expect(s.isLocked, "camp: locked on first heard")
    expectEqual(s.tick(now: 1 + quiet + 1, candidateCount: 2), .stay,
                "camp: quiet lock camps with NO device switch")
    expect(s.isCamping, "camp: camping after quiet lock")
    expectEqual(s.scanIndex(candidateCount: 2), 0, "camp: stays on the locked device")

    // The icon-solid property: an hour of camping produces zero switches
    // until the sweep interval elapses, and every sweep is bounded.
    var now = 1 + quiet + 1
    var switches = 0
    let start = now
    while now < start + 3600 {
        now += 2
        if case .switchCandidate = s.tick(now: now, candidateCount: 2) { switches += 1 }
        // re-camp instantly counts through; heard() not called (still asleep)
    }
    let sweeps = Int(3600 / timing.campSweepSeconds)
    // Each 2-candidate sweep = out to the other jack + back home.
    expect(switches <= sweeps * 2 + 2,
           "camp: an hour asleep causes at most \(sweeps) sweeps (\(switches) switches)")
    expect(switches >= 2, "camp: the jack-swap escape hatch does sweep")

    // A wake beacon during camping locks immediately, no rotation.
    s = BeaconScanner(now: 0)
    _ = s.heard(now: 1, candidateCount: 2)
    _ = s.tick(now: 1 + quiet + 1, candidateCount: 2)
    expect(s.isCamping, "camp: camping before wake")
    expectEqual(s.heard(now: 1 + quiet + 5, candidateCount: 2), .stay,
                "camp: wake beacon locks in place")
    expect(s.isLocked, "camp: locked after wake beacon")

    // Never-locked quiet start still uses the rotation (no camp target).
    s = BeaconScanner(now: 0)
    var sawRotation = false
    for t in stride(from: 2.0, to: 40, by: 2) {
        if case .switchCandidate = s.tick(now: t, candidateCount: 2) { sawRotation = true }
    }
    expect(sawRotation, "camp: initial discovery still rotates")

    // A sweep hearing beacons on a lower-ranked jack still runs the
    // crossbleed audit before locking.
    s = BeaconScanner(now: 0)
    // lock on index 1 via verify-timeout: scan 0 -> rotate to 1 -> heard.
    _ = s.tick(now: timing.dwellSeconds + 0.1, candidateCount: 2)   // -> index 1
    expectEqual(s.heard(now: timing.dwellSeconds + 2, candidateCount: 2),
                .switchCandidate(index: 0), "camp: hear on low rank audits top")
}
