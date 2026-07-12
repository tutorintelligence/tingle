import AVFoundation
import CoreAudio
import os

/// Detects the flashed device's tone signaling (single burst = white press,
/// two-tone chirps = mode/FX/handle) on the audio input via an AVAudioEngine
/// tap feeding GoertzelDetector. Always pinned to an explicit line-in device
/// by CoreAudio UID — never the system default input.
final class AudioBackend: TingBackend {
    var onEvent: ((TingEvent) -> Void)?
    /// Fired (main queue) when the chirp SNR crosses into/out of the
    /// too-quiet regime; drives the "raise the volume knob" menu hint.
    var onWeakSignal: ((Bool) -> Void)?
    private var reportedWeakSignal = false
    /// Fired (main queue) when isRunning/deviceName change.
    var onStateChange: (() -> Void)?

    private(set) var isRunning = false
    private(set) var deviceName = "default input"
    /// The tap's native input format, available once the engine is running.
    private(set) var inputFormat: AVAudioFormat?

    private let deviceUID: String
    private let frequencies: [Double]
    private let engine = AVAudioEngine()
    private var detector: GoertzelDetector?
    private let detectionQueue = DispatchQueue(label: "tingle.audio.detection")
    private var tapInstalled = false
    private var stopped = false
    private let log = Logger(subsystem: Log.subsystem, category: "audio")

    /// Secondary consumer of the raw tap buffers (dictation shares this
    /// engine's tap instead of opening a second engine on the same device).
    /// Called synchronously on the tap's audio thread; DSP is unaffected.
    private let consumerLock = NSLock()
    private var _bufferConsumer: ((AVAudioPCMBuffer) -> Void)?
    var bufferConsumer: ((AVAudioPCMBuffer) -> Void)? {
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

    init(deviceUID: String, frequencies: [Double]) {
        self.deviceUID = deviceUID
        self.frequencies = frequencies
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                guard granted else {
                    self.log.error("microphone permission denied; audio backend idle")
                    self.onStateChange?()
                    return
                }
                self.startEngine()
            }
        }
    }

    func stop() {
        stopped = true
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        isRunning = false
    }

    // MARK: - Engine

    private func startEngine() {
        guard !frequencies.isEmpty else {
            log.error("no tone frequencies configured; audio backend idle")
            onStateChange?()
            return
        }

        // Pin the input device. Pinning is mandatory: on failure the backend
        // stays stopped — NEVER a silent fallback to the default/built-in mic.
        guard Self.pinInputDevice(uid: deviceUID, on: engine) else {
            log.error("cannot pin input device \(self.deviceUID, privacy: .public); audio backend stopped")
            onStateChange?()
            return
        }

        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log.error("no usable audio input device; audio backend idle")
            onStateChange?()
            return
        }
        inputFormat = format

        detector = GoertzelDetector(
            configuration: .init(sampleRate: format.sampleRate, targetFrequencies: frequencies)
        )

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
                    let weak = margin < 6
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
            onStateChange?()
            return
        }

        isRunning = true
        // Human-readable name of the pinned device for the status line
        // (kAudioObjectPropertyName — never CoreAudio aggregate internals).
        deviceName = Self.currentInputDeviceName(of: engine) ?? deviceUID
        log.info("audio backend listening on \(self.deviceName, privacy: .public) at \(format.sampleRate)Hz")
        onStateChange?()
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
