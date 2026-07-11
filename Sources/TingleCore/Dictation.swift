import AppKit
import AVFoundation
import Speech
import os

/// Live dictation driven by the ting's handle: triggerDown starts a
/// SpeechAnalyzer/SpeechTranscriber session on the audio input (the ting's
/// mic arrives on the same input device tingle already listens to), text is
/// typed into the frontmost app AS the user speaks (volatile hypotheses with
/// backspace corrections — see TranscriptTyper), and triggerUp finalizes.
///
/// The speech stack requires macOS 26 (Tahoe); everything is availability-
/// gated so the app still runs (sans dictation) on the macOS 13 target.
final class DictationController {
    /// Menu status override; nil = not dictating. Delivered on the main queue.
    /// ("Preparing speech model…", "Dictating…", "Inserted N words")
    var onStatusChange: ((String?) -> Void)?

    private let configStore: ConfigStore
    private let coordinator: DetectionCoordinator
    private let actionRunner: ActionRunner
    private var session: AnyObject?
    private var warnedUnsupportedOS = false
    private var statusGeneration = 0
    private let log = Logger(subsystem: Log.subsystem, category: "dictation")

    /// Completed takes, newest last — repeated green presses peel them
    /// back one at a time. Also drives the between-takes leading space.
    private struct LastSession {
        let characterCount: Int
        let lastCharacter: Character?
        let bundleID: String?
        let endedAt: Date
    }
    /// Completed takes, newest last — repeated green presses peel them
    /// back one at a time (cap 10).
    private var takeStack: [LastSession] = []
    private var lastSession: LastSession? { takeStack.last }
    private var sessionStartedAt = Date.distantPast
    /// An erase arrived while the just-released session was still
    /// finalizing — the user means THAT take; erase it when it finishes.
    private var pendingErase = false
    /// True between stopDictation() and the session's completion.
    private var isFinalizing = false

    init(configStore: ConfigStore, coordinator: DetectionCoordinator, actionRunner: ActionRunner) {
        self.configStore = configStore
        self.coordinator = coordinator
        self.actionRunner = actionRunner
    }

    /// Called on triggerDown when the mapping is {"type": "dictate"}.
    func startDictation() {
        guard #available(macOS 26, *) else {
            log.error("dictate action requires macOS 26 (SpeechAnalyzer)")
            if !warnedUnsupportedOS {
                warnedUnsupportedOS = true
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "Dictation requires macOS 26"
                alert.informativeText = "The \"dictate\" action uses Apple's SpeechAnalyzer, "
                    + "which is available on macOS 26 (Tahoe) and later. "
                    + "Map triggerDown to a keyHold/keystroke/shell action instead."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            return
        }

        if session != nil {
            // Sessions can wedge during STARTUP (model download, analyzer
            // start, audio attach) where the finish-timeout can't reach.
            // Never let a zombie brick squeezing: force-abandon after 10s.
            guard Date().timeIntervalSince(sessionStartedAt) > 4 else {
                log.warning("triggerDown ignored: a dictation session is already active")
                return
            }
            log.error("abandoning wedged dictation session (age \(Int(Date().timeIntervalSince(self.sessionStartedAt)))s)")
            if let stuck = session as? DictationSession {
                stuck.onStatus = nil
                stuck.onFinished = nil
                stuck.stop()
            }
            session = nil
            onStatusChange?(nil)
        }
        sessionStartedAt = Date()
        guard actionRunner.ensureAccessibility() else {
            log.error("Accessibility not granted; dictation cannot type into the frontmost app")
            NSSound.beep()
            flashStatus("⚠️ Accessibility needed — open the tingle menu")
            return
        }
        // Same loud-failure rule for the microphone. .notDetermined falls
        // through: the session's requestAccess shows the system dialog.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied
            || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
            log.error("Microphone denied; dictation cannot capture audio")
            NSSound.beep()
            flashStatus("⚠️ Microphone access needed — open the tingle menu")
            return
        }

        statusGeneration += 1
        isFinalizing = false
        let newSession = DictationSession(
            deviceUID: PinnedInput.uid,
            vocabulary: configStore.config.vocabulary,
            replacements: configStore.config.replacements,
            audioBackendProvider: { [weak coordinator] in coordinator?.runningAudioBackend },
            prefixSpace: needsLeadingSpace()
        )
        newSession.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.onStatusChange?(text) }
        }
        newSession.onFinished = { [weak self] wordCount, charCount, lastChar in
            DispatchQueue.main.async {
                self?.sessionFinished(wordCount: wordCount, characterCount: charCount, lastCharacter: lastChar)
            }
        }
        session = newSession
        newSession.start()
    }

    /// Called on every triggerUp (no-op when idle). Nothing waits for release
    /// except the final volatile-region flush.
    func stopDictation() {
        guard #available(macOS 26, *), let active = session as? DictationSession else { return }
        isFinalizing = true
        active.stop()
    }

    /// True when a new session should open with a space: same app, recent,
    /// and the previous session ended in a non-whitespace character.
    private func needsLeadingSpace() -> Bool {
        guard let last = lastSession,
              Date().timeIntervalSince(last.endedAt) < 60,
              last.bundleID == NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let lastChar = last.lastCharacter,
              !lastChar.isWhitespace, !lastChar.isNewline
        else { return false }
        return true
    }

    /// eraseDictation action: scrap the last take — post exactly as many
    /// backspaces as the last session typed, if we're still in the same app
    /// and it was recent. No-op while a session is active (the green button
    /// physically can't fire then anyway — the handle blocks it).
    func eraseLastSession() {
        if session != nil {
            if isFinalizing {
                // The user just released and wants THAT take gone; it is
                // still finalizing — erase it the moment it completes.
                pendingErase = true
                return
            }
            // A session is actively CAPTURING (chirp-queue latency can
            // deliver a green pressed before the squeeze after the new
            // session already started): the user meant the previous take.
            // Fall through and erase lastSession; never touch the live one.
        }
        guard let last = takeStack.last, last.characterCount > 0 else {
            log.info("eraseDictation: nothing to erase")
            flashStatus("Nothing to erase")
            return
        }
        guard Date().timeIntervalSince(last.endedAt) < 300,
              last.bundleID == NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            log.info("eraseDictation: last take too old or different app; ignoring")
            flashStatus("Nothing recent to erase")
            return
        }
        guard actionRunner.ensureAccessibility() else { return }
        DictationKeystrokes.post(.init(backspaces: last.characterCount, append: ""))
        log.info("erased last take (\(last.characterCount) characters, \(self.takeStack.count - 1) more on the stack)")
        takeStack.removeLast()
        flashStatus(takeStack.isEmpty ? "Erased last take" : "Erased last take (press again for previous)")
    }

    /// Show a transient status line for 3s (gesture feedback must always be
    /// visible — an invisible no-op reads as "the gesture didn't work").
    private func flashStatus(_ text: String) {
        onStatusChange?(text)
        statusGeneration += 1
        let generation = statusGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.statusGeneration == generation else { return }
            self.onStatusChange?(nil)
        }
    }

    /// A keystroke/keyHold action is about to type while dictation is live:
    /// the field is changing under the typer, so freeze what's on screen —
    /// corrections must not backspace over it (the overwrite bug).
    func externalTypingWillOccur() {
        guard #available(macOS 26, *), let active = session as? DictationSession else { return }
        active.freezeVolatile()
    }

    private func sessionFinished(wordCount: Int, characterCount: Int, lastCharacter: Character?) {
        session = nil
        isFinalizing = false

        // Micro-sessions (rapid squeezes, e.g. the erase gesture) typed
        // nothing: keep the previous take's memory intact and skip the
        // "Inserted N words" flash — but ALWAYS clear the "Dictating…"
        // status override or it sticks forever.
        if characterCount == 0 {
            onStatusChange?(nil)
            statusGeneration += 1
            if pendingErase {
                pendingErase = false
                eraseLastSession()
            }
            return
        }

        takeStack.append(LastSession(
            characterCount: characterCount,
            lastCharacter: lastCharacter,
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            endedAt: Date()
        ))
        if takeStack.count > 10 { takeStack.removeFirst() }
        if pendingErase {
            pendingErase = false
            eraseLastSession()
            return
        }
        onStatusChange?("Inserted \(wordCount) word\(wordCount == 1 ? "" : "s")")
        statusGeneration += 1
        let generation = statusGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.statusGeneration == generation else { return }
            self.onStatusChange?(nil)
        }
    }
}

// MARK: - Session (macOS 26 speech stack)

/// One handle-squeeze worth of live transcription.
///
/// API shape (macOS 26): SpeechTranscriber(locale:...reportingOptions:
/// [.volatileResults]...) is a module of SpeechAnalyzer(modules:); audio is
/// fed as AnalyzerInput buffers through an AsyncStream started with
/// analyzer.start(inputSequence:); hypotheses arrive on transcriber.results
/// (AttributedString text + isFinal); finalizeAndFinishThroughEndOfInput()
/// flushes the tail. On-device models are managed by AssetInventory
/// (assetInstallationRequest(supporting:).downloadAndInstall() on first use).
@available(macOS 26, *)
final class DictationSession {
    var onStatus: ((String?) -> Void)?
    /// (wordCount, characterCount, lastCharacter)
    var onFinished: ((Int, Int, Character?) -> Void)?

    private let deviceUID: String?
    /// Config vocabulary applied as contextual strings (recognition bias).
    private let vocabulary: [String]
    /// Post-recognition corrections applied to FINAL segments only — the
    /// volatile pass shows the raw hypothesis, then the final lands and
    /// the typer's correction dance swaps it on screen.
    private let replacements: [String: String]
    /// Re-queried at attach time (with retries): during a serial->audio
    /// backend flip the backend may be mid-startup, and racing it with a
    /// competing engine on the same device can wedge both.
    private let audioBackendProvider: () -> AudioBackend?
    private weak var attachedBackend: AudioBackend?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Error>?

    // Typing is decoupled from result consumption: the results loop only
    // stores hypotheses (finals queue in order; volatiles replace each other)
    // and the typing worker converges the screen on the LATEST state. Slow
    // CGEvent posting therefore never backpressures the recognizer — the
    // cause of text landing in multi-second batches — and skipping stale
    // volatile revisions also reduces backspace churn.
    // `typer` is touched only on `typeQueue`.
    private var typer = TranscriptTyper()
    private let typeQueue = DispatchQueue(label: "tingle.dictation.typing")
    private let hypoLock = NSLock()
    private var pendingFinals: [String] = []
    private var latestVolatile: String?
    private var typingScheduled = false

    // Audio plumbing (tap thread only, after setup).
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    /// Pre-roll: buffers captured before the analyzer was ready (~2s cap).
    private let pendingLock = NSLock()
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var analyzerReady = false
    private var temporaryEngine: AVAudioEngine?
    private var detachAudio: (() -> Void)?

    // One-shot stop signal; buffered, so a stop that races setup still lands.
    private let stopStream: AsyncStream<Void>
    private let stopSignal: AsyncStream<Void>.Continuation

    private let log = Logger(subsystem: Log.subsystem, category: "dictation")

    init(deviceUID: String?, vocabulary: [String], replacements: [String: String],
         audioBackendProvider: @escaping () -> AudioBackend?, prefixSpace: Bool) {
        self.deviceUID = deviceUID
        self.vocabulary = vocabulary
        self.replacements = replacements
        self.audioBackendProvider = audioBackendProvider
        if prefixSpace { typer.prefixPending = " " }
        (self.stopStream, self.stopSignal) = AsyncStream<Void>.makeStream()
    }

    func start() {
        Task { await self.run() }
    }

    func stop() {
        stopSignal.yield(())
        stopSignal.finish()
    }

    // MARK: Lifecycle

    private func run() async {
        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw DictationError.microphoneDenied
            }

            // Capture FIRST: recognizer setup takes hundreds of ms, and a
            // quick word spoken right after the squeeze must not fall into
            // that dead zone. feed() stashes into a pre-roll until the
            // analyzer is ready, then flushPendingAudio() replays it.
            try await attachAudioSource()

            let locale = try await resolveLocale()
            let transcriber = SpeechTranscriber(
                locale: locale,
                // Empty is optimal here (verified against the SDK):
                // SpeechTranscriber punctuates automatically and its ONLY
                // TranscriptionOption is .etiquetteReplacements (profanity
                // censoring), which we deliberately leave off — don't bleep
                // engineers dictating code. (.punctuation/.emoji exist only
                // on the lower-accuracy DictationTranscriber.)
                transcriptionOptions: [],
                // fastResults biases the recognizer toward low-latency
                // hypothesis emission — without it, volatile results arrive
                // in multi-second clumps and live typing feels batchy.
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )
            self.transcriber = transcriber

            try await ensureModel(for: transcriber, locale: locale)

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer

            // Bias recognition toward the user's vocabulary (names, jargon).
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings = [.general: vocabulary]
                try await analyzer.setContext(context)
                log.info("dictation vocabulary applied (\(self.vocabulary.count) entries)")
            }

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw DictationError.noAnalyzerFormat
            }
            analyzerFormat = format

            let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
            inputBuilder = builder

            // Consume results WITHOUT typing inline (see typing worker note).
            let sessionStart = Date()
            resultsTask = Task { [weak self] in
                var lastResult = Date()
                for try await result in transcriber.results {
                    let now = Date()
                    var text = String(result.text.characters)
                    if result.isFinal {
                        text = TingConfig.applyReplacements(text, self?.replacements ?? [:])
                    }
                    self?.log.debug("result \(result.isFinal ? "FINAL" : "volatile") \(text.count) chars, +\(Int(now.timeIntervalSince(lastResult) * 1000))ms (t=\(Int(now.timeIntervalSince(sessionStart) * 1000))ms)")
                    lastResult = now
                    self?.enqueue(hypothesis: text, isFinal: result.isFinal)
                }
            }

            try await analyzer.start(inputSequence: inputSequence)
            flushPendingAudio()
            onStatus?("Dictating…")
            log.info("dictation session running")

            // Wait for the handle release (buffered if it already happened).
            for await _ in stopStream { break }

            await finishSession()
        } catch {
            log.error("dictation failed: \(String(describing: error))")
            teardownAudio()
            inputBuilder?.finish()
            resultsTask?.cancel()
            onStatus?(nil)
            let (words, chars, lastChar): (Int, Int, Character?) = typeQueue.sync {
                typer.finish()
                return (typer.wordCount, typer.committedText.count, typer.committedText.last)
            }
            onFinished?(words, chars, lastChar)
        }
    }

    private func finishSession() async {
        teardownAudio()
        inputBuilder?.finish()
        // Finalization can wedge (observed when a session raced a backend
        // flip); race it against a hard timeout so a stuck session can
        // never permanently swallow future squeezes.
        let timedOut = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { [analyzer, resultsTask] in
                do {
                    try await analyzer?.finalizeAndFinishThroughEndOfInput()
                } catch {
                    // logged below via the timeout path being false
                }
                try? await resultsTask?.value
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if timedOut {
            log.error("dictation finalize timed out after 5s; forcing session teardown")
            resultsTask?.cancel()
        }
        let (words, chars, lastChar): (Int, Int, Character?) = typeQueue.sync {
            typer.finish()
            return (typer.wordCount, typer.committedText.count, typer.committedText.last)
        }
        log.info("dictation finished: \(words) words")
        onFinished?(words, chars, lastChar)
    }

    /// Results-loop side: store the hypothesis and kick the typing worker.
    private func enqueue(hypothesis: String, isFinal: Bool) {
        hypoLock.lock()
        if isFinal {
            pendingFinals.append(hypothesis)
            latestVolatile = nil
        } else {
            latestVolatile = hypothesis
        }
        let shouldSchedule = !typingScheduled
        typingScheduled = true
        hypoLock.unlock()
        if shouldSchedule {
            typeQueue.async { [weak self] in self?.drainAndType() }
        }
    }

    /// Typing-worker side: converge the screen on the latest state.
    private func drainAndType() {
        while true {
            hypoLock.lock()
            let finals = pendingFinals
            pendingFinals = []
            let volatileHypo = latestVolatile
            latestVolatile = nil
            if finals.isEmpty && volatileHypo == nil {
                typingScheduled = false
                hypoLock.unlock()
                return
            }
            hypoLock.unlock()
            for final in finals {
                DictationKeystrokes.post(typer.update(hypothesis: final, isFinal: true))
            }
            if let volatileHypo {
                DictationKeystrokes.post(typer.update(hypothesis: volatileHypo, isFinal: false))
            }
        }
    }

    /// See DictationController.externalTypingWillOccur().
    func freezeVolatile() {
        typeQueue.async { [weak self] in self?.typer.freezeVolatile() }
    }

    // MARK: Model / locale

    private func resolveLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if supported.contains(where: { $0.identifier(.bcp47) == current.identifier(.bcp47) }) {
            return current
        }
        if let english = supported.first(where: { $0.identifier(.bcp47) == "en-US" }) {
            log.warning("locale \(current.identifier, privacy: .public) unsupported; falling back to en-US")
            return english
        }
        throw DictationError.unsupportedLocale(current.identifier)
    }

    private func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            return
        }
        // First use on this machine: download the on-device model.
        onStatus?("Preparing speech model…")
        log.info("downloading speech model for \(locale.identifier, privacy: .public)")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: Audio source

    /// Prefer the AudioBackend's already-running engine tap (never open a
    /// second engine on the same device); fall back to a temporary engine
    /// when the audio backend is stopped (serial mode).
    private func attachAudioSource() async throws {
        // Prefer the shared tap; wait out a backend that is still starting
        // (up to ~1s) rather than racing it with a second engine.
        for attempt in 0..<10 {
            guard let backend = audioBackendProvider() else { break }
            if backend.isRunning, backend.inputFormat != nil {
                backend.bufferConsumer = { [weak self] buffer in self?.feed(buffer) }
                attachedBackend = backend
                detachAudio = { [weak backend] in backend?.bufferConsumer = nil }
                log.info("dictation sharing the audio backend's input tap\(attempt > 0 ? " (after \(attempt * 100)ms wait)" : "")")
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Serial mode: the DSP engine is off; use the shared warm capture
        // engine, pinned to the same device the audio backend would use
        // (configured UID or the top line-in candidate — never the
        // default/built-in mic). It stays warm 60s between sessions so
        // consecutive squeezes have no spin-up dead zone.
        let resolvedUID = deviceUID
            ?? InputDeviceSelector.candidates(from: AudioDeviceCatalog.systemInputDevices()).first?.uid
        guard let resolvedUID else { throw DictationError.noInputDevice }
        guard WarmCapture.shared.attach(uid: resolvedUID, consumer: { [weak self] buffer in
            self?.feed(buffer)
        }) else {
            throw DictationError.noInputDevice
        }
        detachAudio = { WarmCapture.shared.detach() }
        log.info("dictation using the warm capture engine")
    }

    /// Tap thread: convert to the analyzer's format and feed the stream —
    /// or stash into the pre-roll while the analyzer is still starting.
    private var _fedCount = 0
    private func feed(_ buffer: AVAudioPCMBuffer) {
        _fedCount += 1
        if _fedCount <= 3 || _fedCount % 50 == 0 {
            log.debug("feed #\(self._fedCount) frames=\(buffer.frameLength) ready=\(self.analyzerReady)")
        }
        pendingLock.lock()
        if !analyzerReady {
            pendingBuffers.append(buffer)
            if pendingBuffers.count > 25 { pendingBuffers.removeFirst() }   // ~2s cap
            pendingLock.unlock()
            return
        }
        pendingLock.unlock()
        convertAndYield(buffer)
    }

    /// Analyzer is live: replay the pre-roll, then feed() goes direct.
    private func flushPendingAudio() {
        pendingLock.lock()
        let stash = pendingBuffers
        pendingBuffers = []
        analyzerReady = true
        pendingLock.unlock()
        log.debug("flushPendingAudio: replaying \(stash.count) pre-roll buffers")
        for buffer in stash { convertAndYield(buffer) }
    }

    private var _yieldCount = 0
    private func convertAndYield(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat, let inputBuilder else {
            log.error("convertAndYield: missing format=\(self.analyzerFormat == nil) builder=\(self.inputBuilder == nil)")
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
        }
        guard let converter else { log.error("convertAndYield: no converter"); return }
        _yieldCount += 1
        if let ch = buffer.floatChannelData?[0] {
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) }
            if _yieldCount <= 5 || _yieldCount % 20 == 0 {
                log.debug("audio buffer #\(self._yieldCount) peak=\(String(format: "%.4f", peak)) (silence≈0)")
            }
        }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0 else {
            if let conversionError {
                log.error("buffer conversion failed: \(String(describing: conversionError))")
            }
            return
        }
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    private func teardownAudio() {
        detachAudio?()
        detachAudio = nil
        temporaryEngine = nil
    }

    enum DictationError: LocalizedError {
        case microphoneDenied
        case unsupportedLocale(String)
        case noAnalyzerFormat
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "Microphone access was denied."
            case .unsupportedLocale(let id): return "No speech model supports locale \(id)."
            case .noAnalyzerFormat: return "SpeechAnalyzer offered no compatible audio format."
            case .noInputDevice: return "No usable audio input device."
            }
        }
    }
}

// MARK: - Warm capture engine (serial mode)

/// In serial mode each dictation session used to build and tear down its
/// own AVAudioEngine — every squeeze risked the engine spin-up dead zone
/// (~1 in 3 quick single words lost). The engine now stays warm for 60s
/// after the last session, so consecutive dictations attach instantly.
final class WarmCapture {
    static let shared = WarmCapture()

    private var engine: AVAudioEngine?
    private var uid: String?
    private let lock = NSLock()
    private var consumer: ((AVAudioPCMBuffer) -> Void)?
    private var idleTeardown: DispatchWorkItem?
    private let log = Logger(subsystem: Log.subsystem, category: "warmcapture")

    /// Attach a buffer consumer, starting (or reusing) the engine pinned to
    /// the given device. Returns false if the engine could not start.
    func attach(uid resolvedUID: String, consumer newConsumer: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
        idleTeardown?.cancel()
        idleTeardown = nil

        if let engine, uid == resolvedUID, engine.isRunning {
            lock.lock(); consumer = newConsumer; lock.unlock()
            return true
        }
        stopEngine()

        let newEngine = AVAudioEngine()
        guard AudioBackend.pinInputDevice(uid: resolvedUID, on: newEngine) else { return false }
        let tapFormat = newEngine.inputNode.inputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0 else { return false }
        newEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let sink = self.consumer
            self.lock.unlock()
            sink?(buffer)
        }
        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            log.error("warm capture engine failed to start: \(String(describing: error))")
            return false
        }
        lock.lock(); consumer = newConsumer; lock.unlock()
        engine = newEngine
        uid = resolvedUID
        log.info("warm capture engine started on \(resolvedUID, privacy: .public)")
        return true
    }

    /// Detach the consumer; the engine idles for 60s in case another
    /// session follows, then tears down (clears the mic-in-use indicator).
    func detach() {
        lock.lock(); consumer = nil; lock.unlock()
        let work = DispatchWorkItem { [weak self] in self?.stopEngine() }
        idleTeardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        uid = nil
        log.info("warm capture engine stopped")
    }
}

// MARK: - Live keystroke output

/// Posts TranscriptTyper edits as CGEvents: backspaces to erase the divergent
/// tail of the volatile region, then the new text as unicode keyboard events
/// (keyboardSetUnicodeString supports arbitrary strings without touching the
/// clipboard — better than paste for live streaming; chunked ~20 UTF-16 units
/// per event at grapheme boundaries).
///
/// A char-by-char virtual-keycode alternative exists (mapping characters
/// through the active keyboard layout), but unicode events are layout-
/// independent and handle any script.
enum DictationKeystrokes {
    private static let backspaceKeyCode: CGKeyCode = 51
    private static let maxUTF16PerEvent = 20

    static func post(_ edit: TranscriptTyper.Edit) {
        guard !edit.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)

        for _ in 0..<edit.backspaces {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: false)
            else { continue }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }

        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            chunk.removeAll(keepingCapacity: true)
        }
        for character in edit.append {
            let units = Array(String(character).utf16)
            if chunk.count + units.count > maxUTF16PerEvent {
                flush()
            }
            chunk.append(contentsOf: units)
        }
        flush()
    }
}
