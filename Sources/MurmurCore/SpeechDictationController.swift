import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import Speech

/// The permission checks and prompts the dictation flow needs, as a record of capabilities so tests
/// can run without a microphone and without ever showing a system prompt.
struct Permissions {
    var isMicrophoneAuthorized: () -> Bool
    var requestMicrophoneAccess: (@escaping (Bool) -> Void) -> Void
    var isAccessibilityTrusted: () -> Bool
    var promptForAccessibility: () -> Void

    static let live = Permissions(
        isMicrophoneAuthorized: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
        requestMicrophoneAccess: { completion in AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion) },
        isAccessibilityTrusted: { AXIsProcessTrusted() },
        promptForAccessibility: {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
    )

    static let granted = Permissions(
        isMicrophoneAuthorized: { true },
        requestMicrophoneAccess: { $0(true) },
        isAccessibilityTrusted: { true },
        promptForAccessibility: {}
    )
}

/// Walkie-talkie dictation: hold the Siri button to record, release to transcribe, insert and send.
///
/// The decisions live in `DictationMachine`; this class is the imperative shell that snapshots
/// context, feeds events in, and executes the effects that come out (engines, clipboard, keystrokes).
final class SpeechDictationController {
    /// Which speech engine presses will get. `preparing` is distinct from "legacy" so an early press
    /// never falls through to the legacy engine and its permission prompt.
    private enum EngineChoice {
        case preparing
        case analyzer(Locale)
        case legacy
    }

    var stateHandler: ((DictationState) -> Void)?

    var isListening: Bool {
        machine.isListening
    }

    /// A take is in progress, including the finalizing window after release.
    var hasActiveTake: Bool {
        machine.hasEngine
    }

    private let locale = Settings.locale
    private let warmer = MicrophoneWarmer()
    private let inserter = TextInserter()
    private let permissions: Permissions
    private let engineFactory: (() -> Result<TranscriptionEngine, DictationFailure>)?
    private var machine = DictationMachine()
    private var engine: TranscriptionEngine?
    private var prewarmedEngine: TranscriptionEngine?
    private var choice: EngineChoice = .preparing
    private var isStarted = false
    /// Bumped by start/stop so callbacks from a previous run are ignored.
    private var generation = 0
    private var pressedAt = Date.distantPast

    /// `engineFactory` and `permissions` are seams for tests: a fake engine, no microphone, no prompts.
    init(
        engineFactory: (() -> Result<TranscriptionEngine, DictationFailure>)? = nil,
        permissions: Permissions = .live
    ) {
        self.engineFactory = engineFactory
        self.permissions = permissions
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        generation += 1
        let run = generation

        log(.dictation, "on; hold Siri button to talk, release to send. locale=\(locale.identifier)")
        log(.dictation, "input device preference: \(Settings.inputDeviceName ?? "system default")")
        permissions.requestMicrophoneAccess { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.generation == run else { return }
                log(.dictation, "microphone authorization=\(granted ? "granted" : "denied")")
                self.microphoneSettingsChanged()
            }
        }
        prepareEngine(run: run)
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        generation += 1
        send(.cancelRequested)
        prewarmedEngine?.cancel()
        prewarmedEngine = nil
        warmer.stop()
    }

    func handle(button: RemoteButton, isPressed: Bool) {
        guard button == .siri else {
            return
        }
        send(isPressed ? .pressed : .released)
    }

    func cancel() {
        send(.cancelRequested)
    }

    /// Applies the microphone choice and keep-warm setting; also rebuilds the prewarmed session on the new device.
    func microphoneSettingsChanged() {
        guard isStarted else {
            return
        }

        if Settings.keepMicWarm, permissions.isMicrophoneAuthorized() {
            warmer.start(deviceName: Settings.inputDeviceName)
        } else {
            warmer.stop()
        }

        if !machine.hasEngine {
            prewarmedEngine?.cancel()
            prewarmedEngine = nil
            prewarmNextEngine()
        }
    }

    // MARK: - Machine plumbing

    private func send(_ event: DictationEvent) {
        let context = DictationContext(
            microphoneAuthorized: permissions.isMicrophoneAuthorized(),
            accessibilityTrusted: permissions.isAccessibilityTrusted(),
            dryRun: Settings.dryRun,
            insertion: Settings.insertion,
            submission: Settings.submission
        )
        machine.handle(event, context: context).forEach(perform)
    }

    private func perform(_ effect: DictationEffect) {
        switch effect {
        case .beginEngine:
            pressedAt = Date()
            beginEngine()
        case .finishEngine:
            log(.dictation, String(format: "released after %.1fs; finalizing", Double(pressedAt.millisecondsAgo) / 1000))
            guard let engine else {
                send(.engineFailed(.audioEngine("no engine to finish")))
                return
            }
            engine.finish { [weak self] transcript in
                guard let self, self.engine === engine else { return }
                self.send(.engineFinished(transcript: transcript))
            }
        case .cancelEngine:
            engine?.cancel()
        case .retireEngine:
            engine = nil
        case .prewarmNextEngine:
            prewarmNextEngine()
        case .requestMicrophoneAccess:
            permissions.requestMicrophoneAccess { _ in }
        case .requestAccessibility:
            permissions.promptForAccessibility()
        case .copyToClipboard(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .insert(let text, let method, let submission):
            inserter.insert(text, via: method, then: submission) { [weak self] in
                self?.send(.insertionFinished)
            }
        case .report(let state):
            stateHandler?(state)
        case .log(let message):
            log(.dictation, message)
        }
    }

    private func beginEngine() {
        let engine: TranscriptionEngine
        switch makeEngine() {
        case .success(let made):
            engine = made
        case .failure(let failure):
            send(.engineFailed(failure))
            return
        }

        self.engine = engine
        log(.dictation, "\(engine.name) listening… (engine ready \(pressedAt.millisecondsAgo)ms after press)")
        engine.begin { [weak self] event in
            guard let self, self.engine === engine else { return }
            if case .listening(let device) = event {
                log(.dictation, "capturing from \(device) after \(self.pressedAt.millisecondsAgo)ms")
            }
            self.send(DictationEvent(event))
        }
    }

    // MARK: - Engine selection

    private func prepareEngine(run: Int) {
        guard #available(macOS 26, *), Settings.preferAnalyzerEngine else {
            choice = .legacy
            log(.dictation, "engine=SFSpeechRecognizer")
            requestLegacyAuthorization()
            return
        }

        Task { @MainActor [weak self] in
            let supported = await AnalyzerEngine.prepare(locale: Settings.locale)
            guard let self, self.generation == run else { return }
            if let supported {
                self.choice = .analyzer(supported)
                log(.dictation, "engine=SpeechAnalyzer (on-device) locale=\(supported.identifier)")
                self.prewarmNextEngine()
            } else {
                self.choice = .legacy
                log(.dictation, "SpeechAnalyzer unavailable for \(self.locale.identifier); falling back to SFSpeechRecognizer")
                self.requestLegacyAuthorization()
            }
        }
    }

    private func requestLegacyAuthorization() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                log(.dictation, "speech authorization=\(LegacyRecognizerEngine.describe(status))")
            }
        }
    }

    /// Keeps one analysis session started and waiting so the next press only has to open the mic.
    private func prewarmNextEngine() {
        guard isStarted, prewarmedEngine == nil, #available(macOS 26, *), case .analyzer(let locale) = choice else {
            return
        }
        let next = AnalyzerEngine(locale: locale, inputDeviceName: Settings.inputDeviceName)
        next.prewarm()
        prewarmedEngine = next
    }

    private func makeEngine() -> Result<TranscriptionEngine, DictationFailure> {
        if let engineFactory {
            return engineFactory()
        }

        switch choice {
        case .preparing:
            return .failure(.engineNotReady)
        case .analyzer(let locale):
            guard #available(macOS 26, *) else {
                return .failure(.engineNotReady)
            }
            if let ready = prewarmedEngine as? AnalyzerEngine {
                prewarmedEngine = nil
                if ready.isUsable {
                    return .success(ready)
                }
                log(.dictation, "prewarmed session had ended; starting a fresh one")
                ready.cancel()
            }
            return .success(AnalyzerEngine(locale: locale, inputDeviceName: Settings.inputDeviceName))
        case .legacy:
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                requestLegacyAuthorization()
                return .failure(.speechNotAuthorized)
            }
            return .success(LegacyRecognizerEngine(
                locale: locale,
                inputDeviceName: Settings.inputDeviceName,
                onDevice: Settings.onDeviceRecognition
            ))
        }
    }
}

// MARK: - Engines

/// What an engine reports while a take is in progress. `finish` delivers the transcript separately.
enum EngineEvent: Equatable {
    case listening(device: String)
    case partial(String)
    case failed(DictationFailure)
}

extension DictationEvent {
    init(_ event: EngineEvent) {
        switch event {
        case .listening(let device):
            self = .engineListening(device: device)
        case .partial(let text):
            self = .enginePartial(text)
        case .failed(let failure):
            self = .engineFailed(failure)
        }
    }
}

protocol TranscriptionEngine: AnyObject {
    var name: String { get }
    /// Starts capture and recognition. Events arrive on the main queue.
    func begin(onEvent: @escaping (EngineEvent) -> Void)
    /// Stops capture and delivers the final transcript on the main queue exactly once.
    func finish(completion: @escaping (String) -> Void)
    func cancel()
}

/// SFSpeechRecognizer path, used on macOS 13–15 or when SpeechAnalyzer has no model for the locale.
final class LegacyRecognizerEngine: TranscriptionEngine {
    let name = "SFSpeechRecognizer"

    private let recognizer: SFSpeechRecognizer?
    private let inputDeviceName: String?
    private let onDevice: Bool
    private let capture = AudioCapture()
    private let finished = OneShotCompletion<String>()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onEvent: ((EngineEvent) -> Void)?
    private var transcript = ""
    /// The recognizer stopped on its own before release; `finish` then resolves immediately.
    private var endedEarly = false

    init(locale: Locale, inputDeviceName: String?, onDevice: Bool) {
        recognizer = SFSpeechRecognizer(locale: locale)
        self.inputDeviceName = inputDeviceName
        self.onDevice = onDevice
    }

    func begin(onEvent: @escaping (EngineEvent) -> Void) {
        self.onEvent = onEvent
        guard let recognizer, recognizer.isAvailable else {
            onEvent(.failed(.recognizerUnavailable))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if onDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        do {
            try capture.start(deviceName: inputDeviceName) { buffer in
                request.append(buffer)
            }
        } catch let error as AudioCapture.CaptureError {
            onEvent(.failed(error == .noInput ? .noInputDevice : .audioEngine(error.localizedDescription)))
            return
        } catch {
            onEvent(.failed(.audioEngine(error.localizedDescription)))
            return
        }
        onEvent(.listening(device: capture.deviceDescription + (request.requiresOnDeviceRecognition ? ", on-device" : ", server")))

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.onEvent?(.partial(self.transcript))
                    if result.isFinal {
                        self.sessionEnded(reason: "final")
                    }
                }
                if let error {
                    log(.dictation, "recognition ended: \(error.localizedDescription)")
                    self.sessionEnded(reason: "error")
                }
            }
        }
    }

    func finish(completion: @escaping (String) -> Void) {
        capture.stop()
        request?.endAudio()
        if endedEarly {
            log(.dictation, "finalized (session had already ended)")
            completion(transcript)
            return
        }
        finished.arm(completion, timeout: 2.5) { [weak self] in
            self?.resolve(reason: "timeout")
        }
    }

    func cancel() {
        finished.disarm()
        onEvent = nil
        capture.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
    }

    private func sessionEnded(reason: String) {
        if finished.isPending {
            resolve(reason: reason)
            return
        }
        guard !endedEarly else {
            return
        }
        endedEarly = true
        capture.stop()
        if transcript.isEmpty {
            onEvent?(.failed(.sessionEnded))
        }
    }

    private func resolve(reason: String) {
        guard finished.isPending else {
            return
        }
        task?.cancel()
        task = nil
        log(.dictation, "finalized (\(reason))")
        finished.fire(transcript)
    }

    static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .authorized:
            return "authorized"
        @unknown default:
            return "unknown"
        }
    }
}

/// SpeechAnalyzer path (macOS 26+): fully on-device, no length limit, better models.
///
/// Lifecycle is one value: `created → preparing → ready → capturing → finishing → retired`, with
/// `ended` for a session that stopped on its own. Every `await` in setup re-checks it.
@available(macOS 26, *)
final class AnalyzerEngine: TranscriptionEngine {
    private enum Lifecycle: Equatable {
        case created
        case preparing
        case ready
        case capturing
        case finishing
        case retired
        case ended
    }

    let name = "SpeechAnalyzer"

    /// A take that fed less audio than this has nothing to transcribe; waiting for the analyzer to
    /// finalize silence would only block the next press for seconds.
    static let minimumAudioSeconds: TimeInterval = 0.15

    private let locale: Locale
    private let inputDeviceName: String?
    private let capture = AudioCapture()
    private let finished = OneShotCompletion<String>()
    private var lifecycle: Lifecycle = .created
    private var analyzer: SpeechAnalyzer?
    private var feeder: AudioFeeder?
    private var resultsTask: Task<Void, Never>?
    private var setupTask: Task<Void, Error>?
    private var onEvent: ((EngineEvent) -> Void)?
    private var transcript = TranscriptAssembler()

    init(locale: Locale, inputDeviceName: String?) {
        self.locale = locale
        self.inputDeviceName = inputDeviceName
    }

    /// A prewarmed engine that can still take a press.
    var isUsable: Bool {
        switch lifecycle {
        case .created, .preparing, .ready:
            return true
        case .capturing, .finishing, .retired, .ended:
            return false
        }
    }

    /// Makes sure the on-device model is installed and paged in. Returns the locale the transcriber accepts.
    static func prepare(locale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable else {
            log(.dictation, "SpeechTranscriber is not available on this Mac")
            return nil
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            log(.dictation, "SpeechTranscriber has no locale equivalent to \(locale.identifier)")
            return nil
        }

        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                log(.dictation, "downloading on-device speech model for \(supported.identifier)…")
                try await request.downloadAndInstall()
                log(.dictation, "speech model installed")
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            await analyzer.cancelAndFinishNow()
            log(.dictation, "SpeechAnalyzer warmed up; format=\(format.map { "\(Int($0.sampleRate))Hz x\($0.channelCount)" } ?? "?")")
            return supported
        } catch {
            log(.dictation, "SpeechAnalyzer preparation failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Starts the analysis session and builds the audio graph ahead of the button press.
    func prewarm() {
        guard lifecycle == .created else {
            return
        }
        lifecycle = .preparing
        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.setUpAnalyzer()
        }
    }

    @MainActor
    private func setUpAnalyzer() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run {
                        self?.accept(text: text, isFinal: isFinal)
                    }
                }
            } catch {
                await MainActor.run {
                    log(.dictation, "analyzer results ended: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                self?.resultsEnded()
            }
        }

        do {
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw DictationFailure.noCompatibleFormat
            }
            try Task.checkCancellation()
            try await analyzer.start(inputSequence: stream)
            guard lifecycle == .preparing else {
                // Retired while starting: undo what we just started.
                continuation.finish()
                results.cancel()
                await analyzer.cancelAndFinishNow()
                return
            }
            self.analyzer = analyzer
            resultsTask = results
            feeder = AudioFeeder(continuation: continuation, format: format)
            lifecycle = .ready
        } catch {
            continuation.finish()
            results.cancel()
            lifecycle = .ended
            log(.dictation, "SpeechAnalyzer setup failed: \(error.localizedDescription)")
            throw error
        }

        do {
            try capture.prepare(deviceName: inputDeviceName)
        } catch {
            log(.dictation, "could not pre-build audio graph: \(error.localizedDescription)")
        }
    }

    func begin(onEvent: @escaping (EngineEvent) -> Void) {
        self.onEvent = onEvent

        switch lifecycle {
        case .ready:
            startCapture()
        case .created, .preparing:
            prewarm()
            Task { @MainActor [weak self] in
                guard let self, let setupTask = self.setupTask else { return }
                do {
                    try await setupTask.value
                } catch let failure as DictationFailure {
                    self.onEvent?(.failed(failure))
                    return
                } catch {
                    self.onEvent?(.failed(.analyzerSetup(error.localizedDescription)))
                    return
                }
                guard self.lifecycle == .ready else { return }
                self.startCapture()
            }
        case .capturing, .finishing, .retired, .ended:
            onEvent(.failed(.sessionEnded))
        }
    }

    private func startCapture() {
        guard let feeder else {
            onEvent?(.failed(.analyzerSetup("no audio feeder")))
            return
        }
        lifecycle = .capturing
        do {
            try capture.start(deviceName: inputDeviceName) { buffer in
                feeder.feed(buffer)
            }
            onEvent?(.listening(device: capture.deviceDescription + ", on-device"))
        } catch let error as AudioCapture.CaptureError {
            onEvent?(.failed(error == .noInput ? .noInputDevice : .audioEngine(error.localizedDescription)))
        } catch {
            onEvent?(.failed(.audioEngine(error.localizedDescription)))
        }
    }

    func finish(completion: @escaping (String) -> Void) {
        switch lifecycle {
        case .capturing:
            lifecycle = .finishing
            capture.stop()
            if let feeder {
                feeder.continuation.finish()
                let stats = feeder.snapshot
                let fedSeconds = Double(stats.fedFrames) / feeder.format.sampleRate
                log(.dictation, String(format: "fed %.1fs of audio", fedSeconds))
                if let conversionError = stats.conversionError {
                    log(.dictation, "audio conversion failed: \(conversionError)")
                }
                if fedSeconds < Self.minimumAudioSeconds {
                    log(.dictation, "finalized (no audio)")
                    cancel()
                    completion("")
                    return
                }
            }
            finished.arm(completion, timeout: 5) { [weak self] in
                self?.resolve(reason: "timeout")
            }
            Task { [analyzer] in
                do {
                    try await analyzer?.finalizeAndFinishThroughEndOfInput()
                } catch {
                    await MainActor.run {
                        log(.dictation, "finalize failed: \(error.localizedDescription)")
                    }
                }
            }
        case .ended:
            log(.dictation, "finalized (session had already ended)")
            lifecycle = .retired
            completion(transcript.text)
        case .created, .preparing, .ready:
            // Released before the microphone ever opened: there is nothing to transcribe.
            log(.dictation, "released before capture started")
            cancel()
            completion("")
        case .finishing, .retired:
            break
        }
    }

    func cancel() {
        finished.disarm()
        onEvent = nil
        setupTask?.cancel()
        setupTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        capture.stop()
        feeder?.continuation.finish()
        lifecycle = .retired
        Task { [analyzer] in
            await analyzer?.cancelAndFinishNow()
        }
    }

    private func accept(text: String, isFinal: Bool) {
        transcript.accept(text: text, isFinal: isFinal)
        onEvent?(.partial(transcript.text))
    }

    /// The results stream closed. Expected while finishing; otherwise the session died under us.
    private func resultsEnded() {
        switch lifecycle {
        case .finishing:
            resolve(reason: "results finished")
        case .capturing:
            capture.stop()
            lifecycle = .ended
            if transcript.text.isEmpty {
                onEvent?(.failed(.sessionEnded))
            }
        case .preparing, .ready:
            lifecycle = .ended
        case .created, .retired, .ended:
            break
        }
    }

    private func resolve(reason: String) {
        guard finished.isPending else {
            return
        }
        resultsTask?.cancel()
        resultsTask = nil
        lifecycle = .retired
        log(.dictation, "finalized (\(reason))")
        finished.fire(transcript.text)
    }
}
