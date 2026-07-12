import Foundation
import TingleCore

// Regression tests for the 2026-07 production freeze: the capture device
// slept mid-session, AVFAudio wedged inside IOUnitConfigurationChanged
// holding the engine lock, and the main thread froze behind it. The fix's
// contract: engine work is bounded (a wedged engine is abandoned, never
// waited on), and backend stop() never blocks the calling thread.
func runAudioEngineOpsTests() {
    // Healthy work completes within the timeout and reports success.
    do {
        var ran = false
        let start = Date()
        let completed = AudioEngineOps.bounded(timeout: 2.0) { ran = true }
        expect(completed, "bounded reports completion for fast work")
        expect(ran, "bounded runs the work")
        expect(Date().timeIntervalSince(start) < 1.0, "bounded returns promptly for fast work")
    }

    // Wedged work (simulating an engine stuck in a configuration-change
    // semaphore wait) times out: the caller proceeds instead of hanging.
    do {
        let wedge = DispatchSemaphore(value: 0)
        let start = Date()
        let completed = AudioEngineOps.bounded(timeout: 0.3) { wedge.wait() }
        let elapsed = Date().timeIntervalSince(start)
        expect(!completed, "bounded reports timeout for wedged work")
        expect(elapsed >= 0.3, "bounded waits the full timeout before abandoning")
        expect(elapsed < 2.0, "bounded abandons wedged work instead of hanging")
        wedge.signal()   // release the throwaway thread
    }

    // stop() must return immediately even when the engine queue is busy
    // (e.g. disposing a wedged engine) — this is the exact call the
    // DetectionCoordinator makes from the main thread, and it blocking is
    // the menu freeze. The engine queue is deliberately jammed here.
    do {
        let jam = DispatchSemaphore(value: 0)
        AudioEngineOps.queue.async { jam.wait() }
        let backend = AudioBackend(deviceUID: "tingle-test-nonexistent-device", frequencies: [17_500])
        let start = Date()
        backend.stop()
        let elapsed = Date().timeIntervalSince(start)
        expect(elapsed < 0.2, "AudioBackend.stop() never blocks the caller (took \(elapsed)s)")
        expect(!backend.isRunning, "stop() flips isRunning immediately")
        jam.signal()   // unjam the shared queue for any later tests
        AudioEngineOps.queue.sync {}   // drain before moving on
    }
}
