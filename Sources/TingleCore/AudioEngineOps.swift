import AVFoundation
import Foundation
import os

/// Serial home for ALL AVAudioEngine lifecycle work in the process
/// (AudioBackend and WarmCapture both funnel through it).
///
/// Two invariants, both learned from a production freeze (2026-07: the
/// EP-2350's capture device slept mid-session and AVFAudio's internal
/// IOUnitConfigurationChanged thread wedged on a semaphore while holding
/// the engine lock; the main thread then blocked forever behind that lock
/// and the menu froze):
///
/// 1. The main thread NEVER calls into an AVAudioEngine. Every start/stop/
///    tap/property call runs on this queue, and nothing may `sync` onto
///    this queue from the main thread.
/// 2. A single shared queue (not per-engine) keeps strict ordering: an old
///    engine is fully disposed before a successor starts on the same
///    device — two live engines racing one device can wedge both.
public enum AudioEngineOps {
    public static let queue = DispatchQueue(label: "tingle.audio.engine")

    private static let log = Logger(subsystem: Log.subsystem, category: "audio")

    /// Run possibly-wedging engine work (removeTap/stop/isRunning) on a
    /// detached throwaway thread, waiting at most `timeout`. Healthy engines
    /// answer in milliseconds, preserving dispose-before-restart ordering;
    /// an engine wedged inside a device configuration change never returns —
    /// the wait times out and the engine is abandoned, leaking one thread
    /// instead of freezing this queue (and with it every future engine
    /// rebuild). Never wait unboundedly on, or restart, an engine whose
    /// device may have vanished.
    ///
    /// Returns true if `work` completed within the timeout. On false, any
    /// value `work` was meant to produce must not be trusted.
    @discardableResult
    public static func bounded(timeout: TimeInterval = 2.0, _ work: @escaping () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            work()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            log.error("audio engine call exceeded \(timeout, format: .fixed(precision: 1))s; abandoning wedged engine (device likely vanished mid-configuration-change)")
            return false
        }
        return true
    }

    /// AVAudioEngine posts one spurious configuration-change notification
    /// right after an engine whose AUHAL was re-pinned away from the default
    /// device starts (tingle always pins). Distinguish that from a real
    /// device change, which leaves the engine stopped (or wedged): healthy
    /// means still running with the same input format. The probe is bounded
    /// — a wedged engine can't answer and correctly reads unhealthy.
    public static func stillHealthy(_ engine: AVAudioEngine, sampleRate: Double, channelCount: UInt32) -> Bool {
        var running = false
        var format: AVAudioFormat?
        let responsive = bounded(timeout: 0.5) {
            running = engine.isRunning
            format = engine.inputNode.inputFormat(forBus: 0)
        }
        guard responsive, running, let format else { return false }
        return format.sampleRate == sampleRate && format.channelCount == channelCount
    }
}
