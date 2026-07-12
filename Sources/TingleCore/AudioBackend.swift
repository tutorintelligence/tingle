import AVFoundation
import CoreAudio
import os

/// Detects the flashed device's tone signaling (single burst = white press,
/// two-tone chirps = mode/FX/handle) on the audio input via an AVAudioEngine
/// tap feeding SymbolDetector. Always pinned to an explicit line-in device
/// by CoreAudio UID — never the system default input.
///
/// Threading: the engine lives on AudioEngineOps.queue, exclusively — a
/// wedged engine (device slept/vanished mid-configuration-change) must never
/// be reachable from the main thread, or the menu freezes behind the engine
/// lock. Public state (isRunning/deviceName/inputFormat) is updated on main.
/// On AVAudioEngineConfigurationChange the engine is abandoned and REBUILT
/// fresh (never restarted): a config change is exactly when the old engine
/// may already be wedged inside AVFAudio.
public final class AudioBackend: TingBackend {
    var onEvent: ((TingEvent) -> Void)?
    /// Fired (main queue) when the chirp SNR crosses into/out of the
    /// too-quiet regime; drives the "raise the volume knob" menu hint.
    var onWeakSignal: ((Bool) -> Void)?
    private var reportedWeakSignal = false
    /// Fired (main queue) when isRunning/deviceName change.
    var onStateChange: (() -> Void)?

    public private(set) var isRunning = false
    private(set) var deviceName = "default input"
    /// The tap's native input format, available once the engine is running.
    public private(set) var inputFormat: AVAudioFormat?

    private let deviceUID: String
    private let frequencies: [Double]
    /// AudioEngineOps.queue only. Optional because it is abandoned and
    /// rebuilt on configuration changes.
    private var engine: AVAudioEngine?
    /// AudioEngineOps.queue-side copy of the running tap format (inputFormat
    /// is the main-thread-facing one), for the config-change health probe.
    private var engineFormat: AVAudioFormat?
    private var tapInstalled = false
    private var configChangeObserver: NSObjectProtocol?
    private var detector: SymbolDetector?
    /// Set before start(): last known good beacon level (dBFS) to seed the
    /// detector's fast re-lock memory.
    var seedBeaconLevelDB: Double?

    /// Thread-safe snapshot of the detector's pilot state for the beacon
    /// scanner (acquisition-in-progress extends the scan dwell; the level
    /// memory is carried into the next backend instance).
    func detectorSnapshot() -> (acquiring: Bool, levelMemoryDB: Double?) {
        detectionQueue.sync { (detector?.acquiring ?? false, detector?.levelMemoryDB) }
    }
    private let detectionQueue = DispatchQueue(label: "tingle.audio.detection")
    /// Set by stop() (any thread), read on AudioEngineOps.queue.
    private let stoppedLock = NSLock()
    private var _stopped = false
    private var stopped: Bool {
        stoppedLock.lock()
        defer { stoppedLock.unlock() }
        return _stopped
    }
    private let log = Logger(subsystem: Log.subsystem, category: "audio")

    /// Secondary consumer of the raw tap buffers (dictation shares this
    /// engine's tap instead of opening a second engine on the same device).
    /// Called synchronously on the tap's audio thread; DSP is unaffected.
    private let consumerLock = NSLock()
    private var _bufferConsumer: ((AVAudioPCMBuffer) -> Void)?
    public var bufferConsumer: ((AVAudioPCMBuffer) -> Void)? {
        get {
            consumerLock.lock()
            defer { consumerLock.unlock() }
            return _bufferConsumer
        }
        set {
            consumerLock.lock()
            _bufferConsumer = newValue
            consumerLock.unlock()
        }
    }

    public init(deviceUID: String, frequencies: [Double]) {
        self.deviceUID = deviceUID
        self.frequencies = frequencies
    }

    public func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                guard granted else {
                    self.log.error("microphone permission denied; audio backend idle")
                    self.onStateChange?()
                    return
                }
                AudioEngineOps.queue.async { self.startEngine() }
            }
        }
    }

    /// Non-blocking: state flips immediately; the engine is torn down on
    /// AudioEngineOps.queue with a bounded wait. The caller (main thread)
    /// must never block behind a possibly-wedged engine.
    public func stop() {
        stoppedLock.lock()
        _stopped = true
        stoppedLock.unlock()
        isRunning = false
        AudioEngineOps.queue.async { self.teardownEngine() }
    }

    // MARK: - Engine (AudioEngineOps.queue only)

    private func startEngine() {
        guard !stopped, engine == nil else { return }
        guard !frequencies.isEmpty else {
            log.error("no tone frequencies configured; audio backend idle")
            DispatchQueue.main.async { self.onStateChange?() }
            return
        }

        let engine = AVAudioEngine()

        // Pin the input device. Pinning is mandatory: on failure the backend
        // stays stopped — NEVER a silent fallback to the default/built-in mic.
        guard Self.pinInputDevice(uid: deviceUID, on: engine) else {
            log.error("cannot pin input device \(self.deviceUID, privacy: .public); audio backend stopped")
            DispatchQueue.main.async { self.onStateChange?() }
            return
        }

        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log.error("no usable audio input device; audio backend idle")
            DispatchQueue.main.async { self.onStateChange?() }
            return
        }

        // The symbol decoder is built for exactly 48kHz (its heterodyne carriers
        // are integer fractions of the sample rate). Devices have always
        // run 48k here; refuse anything else loudly rather than decode
        // garbage. (A rate converter is a known TODO.)
        guard format.sampleRate == SymbolSet.sampleRate else {
            log.error("input device at \(format.sampleRate)Hz — the symbol decoder requires 48000Hz; not decoding")
            detectionQueue.async { self.detector = nil }
            return
        }
        // Fresh detector, serialized with the tap's processing blocks so a
        // rebuild never races mid-burst DSP. Seed the previous lock's level
        // so wake-from-sleep can fast re-lock on a single beacon (device
        // switches used to discard that memory, forcing the slow 3-beacon
        // acquisition into every scan dwell).
        var detector = SymbolDetector()
        if let seed = seedBeaconLevelDB { detector.seedRememberedLevel(seed) }
        detectionQueue.async { self.detector = detector }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            self.bufferConsumer?(buffer)
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            self.detectionQueue.async {
                guard self.detector != nil else { return }
                let fired = self.detector!.process(samples: samples)
                // Burst-level diagnostics (debug) so a listening-but-not-
                // detecting session is diagnosable from Console.
                for line in self.detector!.drainDiagnostics() {
                    self.log.debug("\(line, privacy: .public)")
                }
                // Chronic thin detection margins = the ting's volume knob is
                // too low for reliable decode. Surface it instead of letting
                // the user discover it as phantom presses and lag.
                if let margin = self.detector!.signalMarginDB {
                    // signalMarginDB here is correlation-quality scaled
                    // ~0..40 (0.45 threshold ~= 18); chronically under 22
                    // means marginal decodes -> tell the user.
                    let weak = margin < 22
                    if weak != self.reportedWeakSignal {
                        self.reportedWeakSignal = weak
                        if weak {
                            self.log.error("weak chirp signal (avg margin \(String(format: "%.1f", margin), privacy: .public)dB) — ting volume knob likely too low")
                        } else {
                            self.log.info("chirp signal healthy again (avg margin \(String(format: "%.1f", margin), privacy: .public)dB)")
                        }
                        DispatchQueue.main.async { self.onWeakSignal?(weak) }
                    }
                }
                for event in fired {
                    self.log.info("audio event: \(event.logDescription, privacy: .public)")
                    DispatchQueue.main.async { self.onEvent?(event) }
                }
            }
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            log.error("failed to start audio engine: \(String(describing: error))")
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            DispatchQueue.main.async { self.onStateChange?() }
            return
        }

        self.engine = engine
        self.engineFormat = format
        observeConfigurationChanges(of: engine)

        // Human-readable name of the pinned device for the status line
        // (kAudioObjectPropertyName — never CoreAudio aggregate internals).
        let name = Self.currentInputDeviceName(of: engine) ?? deviceUID
        log.info("audio backend listening on \(name, privacy: .public) at \(format.sampleRate)Hz")
        DispatchQueue.main.async {
            guard !self.stopped else { return }
            self.inputFormat = format
            self.deviceName = name
            self.isRunning = true
            self.onStateChange?()
        }
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Posted from AVFAudio's internal thread, potentially mid-
            // configuration-change with the engine lock held (and, when the
            // device vanished, already wedged on its internal semaphore).
            // Touching the engine or blocking here can deadlock — hop to
            // the engine queue and do nothing else.
            guard let self else { return }
            self.log.warning("audio engine configuration changed; probing engine health")
            AudioEngineOps.queue.async { self.handleConfigurationChange(of: engine) }
        }
    }

    private func handleConfigurationChange(of changed: AVAudioEngine) {
        guard changed === engine, !stopped else { return }
        // Spurious post-start notification (see AudioEngineOps.stillHealthy):
        // the engine is fine — rebuilding here would loop forever, since
        // every rebuild posts another one.
        let healthy: Bool
        if let probe = _testHealthProbeOverride {
            _testHealthProbeOverride = nil   // one-shot, or the rebuild's own
                                             // spurious notification re-fires it
            healthy = probe()
        } else if let format = engineFormat {
            healthy = AudioEngineOps.stillHealthy(changed, sampleRate: format.sampleRate, channelCount: format.channelCount)
        } else {
            healthy = false
        }
        if healthy {
            log.info("engine survived the configuration change; keeping it")
            return
        }
        teardownEngine()
        DispatchQueue.main.async {
            self.isRunning = false
            self.inputFormat = nil
            self.onStateChange?()
        }
        // Let CoreAudio settle, then rebuild fresh — IF the device still
        // exists. If it vanished, stay stopped: DetectionCoordinator's
        // device-list hook rescans (never a silent default-mic fallback).
        AudioEngineOps.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.stopped, self.engine == nil else { return }
            guard Self.deviceID(forUID: self.deviceUID) != nil else {
                self.log.warning("input device \(self.deviceUID, privacy: .public) gone after configuration change; awaiting device rescan")
                return
            }
            self.log.info("rebuilding audio engine after configuration change")
            self.startEngine()
        }
    }

    private func teardownEngine() {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        guard let engine else { return }
        self.engine = nil
        self.engineFormat = nil
        let removeTap = tapInstalled
        tapInstalled = false
        AudioEngineOps.bounded {
            if removeTap { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
    }

    // MARK: - Test seams

    /// Hardware integration tests only (see AudioHardwareTests). Replaces
    /// the next config-change health probe exactly once; returning false
    /// forces the teardown-and-rebuild path deterministically — the real
    /// wedge cannot be simulated on a healthy device.
    public var _testHealthProbeOverride: (() -> Bool)?

    /// Hardware integration tests only: post the configuration-change
    /// notification for the live engine, as AVFAudio would on a device
    /// change.
    public func _testPostConfigurationChange() {
        AudioEngineOps.queue.async { [self] in
            guard let engine else { return }
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        }
    }

    // MARK: - CoreAudio helpers

    /// Pin an engine's input AUHAL to the device with the given UID.
    /// Returns false if the UID does not resolve or the property set fails.
    @discardableResult
    static func pinInputDevice(uid: String, on engine: AVAudioEngine) -> Bool {
        guard let deviceID = deviceID(forUID: uid), let audioUnit = engine.inputNode.audioUnit else {
            return false
        }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }

    /// Resolve a CoreAudio device UID to its AudioDeviceID.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Name of the device the engine's input AUHAL is currently bound to.
    static func currentInputDeviceName(of engine: AVAudioEngine) -> String? {
        guard let audioUnit = engine.inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { namePointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &nameSize, namePointer)
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
