import Foundation
import os

/// An event-detection backend. Callbacks are delivered on the main queue.
protocol TingBackend: AnyObject {
    /// Called when a ting gesture is detected (see TingEvent).
    var onEvent: ((TingEvent) -> Void)? { get set }
    func start()
    func stop()
}

enum BackendState: Equatable {
    case idle
    /// No eligible line-in capture device exists; the audio backend stays
    /// stopped rather than silently falling back to the default mic.
    case noInputDevice
    /// Auto-discovery: listening for the beacon on a candidate device.
    case searching(deviceName: String)
    /// Auto-discovery: locked onto a device with a fresh beacon.
    case tingDetected(deviceName: String)
    /// Auto-discovery: locked, but the beacon went quiet.
    case tingStale(deviceName: String, secondsSinceHeard: Int)
    /// Manual override: pinned to a specific device (no beacon gating).
    case listeningAudio(deviceName: String)
    case connectedSerial

    var menuDescription: String {
        switch self {
        case .idle:
            return "Idle"
        case .noInputDevice:
            return "No line-in device found"
        case .searching(let deviceName):
            return "Searching for ting… (trying \(deviceName))"
        case .tingDetected(let deviceName):
            return "ting on \(deviceName)"
        case .tingStale(_, let seconds):
            return "ting not detected (last heard \(seconds)s ago)"
        case .listeningAudio(let deviceName):
            return "Listening (audio: \(deviceName))"
        case .connectedSerial:
            return "Connected (USB serial)"
        }
    }
}

/// Picks the active backend: serial when the ting's CDC device is present
/// (richer + exact), audio otherwise. Re-evaluates on a 2s poll.
/// TODO: replace polling with IOKit attach/detach notifications.
final class DetectionCoordinator {
    var onEvent: ((TingEvent) -> Void)?
    /// Live handle state carried by beacons (true = held). Used to
    /// synthesize trigger edges lost to audio decode errors.
    var onTriggerHint: ((Bool) -> Void)?
    var onStateChange: ((BackendState) -> Void)?
    /// Battery voltage from the serial backend; nil when serial disconnects.
    var onBattery: ((Double?) -> Void)?

    private(set) var state: BackendState = .idle {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }

    private let configStore: ConfigStore
    private var serial: SerialBackend?
    private var audio: AudioBackend?
    private var pollTimer: Timer?
    private var noCandidateDevice = false
    /// Beacon auto-discovery state (only driven while in automatic mode,
    /// i.e. config.audioInputDeviceUID == nil). The locked device lives here
    /// in-memory for the session — it is never written to config.
    private var scanner = BeaconScanner(now: DetectionCoordinator.now())
    private let log = Logger(subsystem: Log.subsystem, category: "coordinator")

    /// UID of the device the audio backend is (or was last) pinned to.
    private(set) var currentAudioDeviceUID: String?

    private static func now() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }

    /// The audio backend when it is actually running, for tap sharing
    /// (dictation piggybacks on its input tap instead of opening a second
    /// engine on the same device). nil in serial mode.
    var runningAudioBackend: AudioBackend? {
        guard let audio, audio.isRunning else { return nil }
        return audio
    }

    init(configStore: ConfigStore) {
        self.configStore = configStore
        configStore.addObserver { [weak self] in self?.configDidChange() }
    }

    func start() {
        evaluate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        // Unplug/replug of audio hardware: re-evaluate promptly.
        AudioDeviceCatalog.onDevicesChanged(queue: .main) { [weak self] in
            self?.audioDevicesChanged()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopSerial()
        stopAudio()
        state = .idle
    }

    // MARK: - Backend selection

    private func evaluate() {
        if let path = Self.findSerialDevicePath() {
            guard serial == nil else { return }
            log.info("ting CDC device at \(path, privacy: .public); switching to serial backend")
            stopAudio()
            startSerial(path: path)
        } else {
            if serial != nil {
                log.info("serial device gone; falling back to audio backend")
                stopSerial()
            }
            evaluateAudio()
            refreshState()
        }
    }

    /// Audio-mode driver: manual pin when a UID is configured, otherwise
    /// beacon auto-discovery (scan ranked candidates, lock on beacon, track
    /// freshness, rescan on loss).
    private func evaluateAudio() {
        // Manual override: pin exactly the configured device.
        if let pinnedUID = PinnedInput.uid {
            noCandidateDevice = false
            if audio == nil {
                startAudioBackend(uid: pinnedUID)
            }
            return
        }

        // Automatic (beacon detection).
        let candidates = InputDeviceSelector.candidates(from: AudioDeviceCatalog.systemInputDevices())
        guard !candidates.isEmpty else {
            if !noCandidateDevice {
                log.warning("no eligible line-in input devices; audio backend not started")
            }
            noCandidateDevice = true
            stopAudio()
            currentAudioDeviceUID = nil
            return
        }
        noCandidateDevice = false

        switch scanner.tick(now: Self.now(), candidateCount: candidates.count) {
        case .stay:
            break
        case .switchCandidate(let index):
            log.info("beacon scan: trying \(candidates[index].name, privacy: .public)")
            stopAudio()
            startAudioBackend(uid: candidates[index].uid)
        case .resumeScan:
            log.warning("beacon lost for good; resuming device scan")
            stopAudio()
            startAudioBackend(uid: candidates[0].uid)
        }

        // Ensure a backend is running on whatever the scanner points at.
        if audio == nil {
            let uid: String
            if let index = scanner.scanIndex(candidateCount: candidates.count) {
                uid = candidates[index].uid
            } else if let locked = currentAudioDeviceUID,
                      candidates.contains(where: { $0.uid == locked }) {
                uid = locked   // locked device (session memory, not config)
            } else {
                scanner.deviceLost(now: Self.now())
                uid = candidates[0].uid
            }
            startAudioBackend(uid: uid)
        }
    }

    /// The ting enumerates as /dev/cu.usbmodemEPTXP* (see DESIGN.md).
    static func findSerialDevicePath() -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.usbmodemEPTXP") }
            .sorted()
            .first
            .map { "/dev/\($0)" }
    }

    private func startSerial(path: String) {
        let backend = SerialBackend(path: path)
        backend.onEvent = { [weak self] event in self?.handleBackendEvent(event, viaAudio: false) }
        // Poll-header state: authoritative held-state every ~150ms —
        // feeds the same reconciler healing as audio beacons, but faster.
        backend.onStateHint = { [weak self] held in self?.onTriggerHint?(held) }
        backend.onBattery = { [weak self] volts in self?.onBattery?(volts) }
        backend.onDisconnect = { [weak self] in
            guard let self else { return }
            self.log.warning("serial backend disconnected")
            self.stopSerial()
            // Don't immediately retry (a wedged port would spin); the 2s
            // evaluate() poll picks the right backend on the next tick.
            self.refreshState()
        }
        serial = backend
        backend.start()
        state = .connectedSerial
    }

    private func stopSerial() {
        guard let serial else { return }
        serial.onDisconnect = nil
        serial.stop()
        self.serial = nil
        onBattery?(nil)
    }

    private func startAudioBackend(uid: String) {
        currentAudioDeviceUID = uid
        let backend = AudioBackend(deviceUID: uid, frequencies: configStore.config.toneFrequencies)
        backend.onEvent = { [weak self] event in self?.handleBackendEvent(event, viaAudio: true) }
        backend.onStateChange = { [weak self] in self?.refreshState() }
        audio = backend
        backend.start()
    }

    private func stopAudio() {
        audio?.stop()
        audio = nil
    }

    /// Central event intake from either backend. Any decoded event proves
    /// the ting is alive on the current input; beacons are consumed here
    /// (internal liveness signal) and never routed to actions.
    private func handleBackendEvent(_ event: TingEvent, viaAudio: Bool) {
        if serial == nil, PinnedInput.uid == nil {
            let wasLocked = scanner.isLocked
            let candidates = InputDeviceSelector.candidates(from: AudioDeviceCatalog.systemInputDevices())
            switch scanner.heard(now: Self.now(), candidateCount: candidates.count) {
            case .switchCandidate(let index) where index < candidates.count:
                // Suspect hear (lower-ranked jack; could be crossbleed):
                // audition the top candidate before committing.
                log.info("beacon on \(self.audio?.deviceName ?? "?", privacy: .public); verifying \(candidates[index].name, privacy: .public) first")
                stopAudio()
                startAudioBackend(uid: candidates[index].uid)
            default:
                if !wasLocked, let audio {
                    log.info("beacon heard; locked onto \(audio.deviceName, privacy: .public)")
                }
            }
        }
        refreshState()
        // Trigger-state hints fire only from STATE-BEARING beacons: all
        // chirp-decoded beacons carry state; serial ones only on payloads
        // that append the state token (a stateless line must never be
        // read as "released").
        if event == .beacon {
            if viaAudio || serial?.payloadSendsBeaconState == true {
                onTriggerHint?(false)
            }
            return
        }
        if event == .beaconHeld {
            onTriggerHint?(true)
            return
        }
        onEvent?(event)
    }

    private func audioDevicesChanged() {
        log.info("audio device list changed; re-evaluating")
        guard serial == nil else { return }
        // If the active device vanished, stop and (in auto mode) resume
        // scanning immediately — never a silent default-mic fallback.
        if audio != nil, let uid = currentAudioDeviceUID, AudioBackend.deviceID(forUID: uid) == nil {
            log.warning("active input device disappeared; stopping audio backend")
            stopAudio()
            if PinnedInput.uid == nil {
                scanner.deviceLost(now: Self.now())
            }
        }
        evaluate()
    }

    private func refreshState() {
        let now = Self.now()
        if serial != nil {
            state = .connectedSerial
        } else if let audio, audio.isRunning {
            if PinnedInput.uid != nil {
                // Manual override: no beacon gating on the status line.
                state = .listeningAudio(deviceName: audio.deviceName)
            } else if scanner.isLocked, let lastHeard = scanner.lastHeard {
                if scanner.isStale(now: now) {
                    state = .tingStale(
                        deviceName: audio.deviceName,
                        secondsSinceHeard: Int(now - lastHeard)
                    )
                } else {
                    state = .tingDetected(deviceName: audio.deviceName)
                }
            } else {
                state = .searching(deviceName: audio.deviceName)
            }
        } else if audio == nil, noCandidateDevice {
            state = .noInputDevice
        } else {
            state = .idle
        }
    }

    /// The menu changed the pinned input (PinnedInput lives outside the
    /// user's TOML so their comments survive) — same restart as a config
    /// reload.
    func inputSelectionChanged() {
        configDidChange()
    }

    private func configDidChange() {
        log.info("config changed")
        // The audio backend bakes in device UID + frequencies; restart it.
        // A mode flip (manual <-> automatic) also resets the scan.
        if serial == nil {
            stopAudio()
            scanner = BeaconScanner(now: Self.now())
            evaluate()
        }
    }
}
