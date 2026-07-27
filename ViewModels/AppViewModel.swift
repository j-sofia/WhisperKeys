import AppKit
import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var activity: AppActivity = .idle
    @Published private(set) var modelInstallationProgress: Double?
    @Published private(set) var modelInstallationStatus: String?

    let settings: AppSettings
    let permissions: PermissionManager
    let debugLog: DebugLogStore
    let modelStore: ModelStore

    private let recorder: AudioRecorder
    private let recognizer: SpeechRecognizing
    private let typingEngine: TypingEngine
    private let shortcutMonitor: GlobalShortcutMonitor
    private let requestMicrophonePermission: () async -> Bool
    private let accessibilityPermissionState: () -> PermissionState
    private let startSound = NSSound(named: NSSound.Name("Tink"))
    private let stopSound = NSSound(named: NSSound.Name("Pop"))
    private var transcriptionTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var hasStartedInitialModelInstallation = false
    private var liveTypedText = ""
    private var previousLiveHypothesis = ""
    private var typingBatchID: UUID?
    private var pauseRolloverTask: Task<Void, Never>?
    private var pausedSegmentTypingBatchID: UUID?
    private var defersNextSegmentTyping = false
    private var pendingLivePause = false
    private var isShuttingDown = false

    init() {
        self.settings = AppSettings()
        self.permissions = PermissionManager()
        self.recorder = AudioRecorder()
        self.recognizer = WhisperKitSpeechRecognizer()
        self.typingEngine = TypingEngine()
        self.shortcutMonitor = GlobalShortcutMonitor()
        self.debugLog = DebugLogStore()
        self.modelStore = ModelStore()
        self.requestMicrophonePermission = { [permissions] in
            await permissions.requestMicrophone()
        }
        self.accessibilityPermissionState = { [permissions] in permissions.accessibility }

        configureCallbacks()
    }

    init(
        settings: AppSettings,
        permissions: PermissionManager,
        recorder: AudioRecorder,
        recognizer: SpeechRecognizing,
        typingEngine: TypingEngine,
        shortcutMonitor: GlobalShortcutMonitor,
        debugLog: DebugLogStore,
        modelStore: ModelStore,
        requestMicrophonePermission: (() async -> Bool)? = nil,
        accessibilityPermissionState: (() -> PermissionState)? = nil
    ) {
        self.settings = settings
        self.permissions = permissions
        self.recorder = recorder
        self.recognizer = recognizer
        self.typingEngine = typingEngine
        self.shortcutMonitor = shortcutMonitor
        self.debugLog = debugLog
        self.modelStore = modelStore
        self.requestMicrophonePermission = requestMicrophonePermission ?? { [permissions] in
            await permissions.requestMicrophone()
        }
        self.accessibilityPermissionState = accessibilityPermissionState ?? { [permissions] in
            permissions.accessibility
        }

        configureCallbacks()
    }

    private func configureCallbacks() {
        typingEngine.onCompleted = { [weak self] batchID in
            guard let self else { return }
            if self.pausedSegmentTypingBatchID == batchID {
                self.pausedSegmentTypingBatchID = nil
                self.resumeNextSegmentTyping()
            }
            guard self.activity == .typing, self.typingBatchID == batchID else { return }
            self.typingBatchID = nil
            self.activity = .idle
        }
        typingEngine.onTyped = { [weak self] event in self?.debugLog.append(event) }
        typingEngine.onTypedBatch = { [weak self] events in self?.debugLog.append(events) }
        typingEngine.onError = { [weak self] error in
            self?.debugLog.setError(error)
            self?.typingBatchID = nil
            self?.activity = .error(error.localizedDescription)
        }
        shortcutMonitor.onAction = { [weak self] in self?.handleShortcut() }
    }

    func configure() {
        permissions.refresh()
        restartShortcutMonitor()
        // A resumed setup has already passed the welcome page and has a selected model. Load it
        // in the background so later onboarding pages, including Try It, are ready to use.
        if !settings.needsOnboarding || settings.onboardingResumeStep > 0 {
            installSavedModelAtLaunch()
        }
    }

    /// Ensures the model selected during the previous run is ready before dictation begins.
    /// `configure()` can be called more than once as SwiftUI creates its scenes, so this is
    /// guarded to avoid starting duplicate installs.
    private func installSavedModelAtLaunch() {
        guard !hasStartedInitialModelInstallation else { return }
        hasStartedInitialModelInstallation = true
        installSelectedModel()
    }

    func restartShortcutMonitor() {
        shortcutMonitor.stop()
        guard !isShuttingDown else { return }
        guard settings.shortcutKey != .disabled else { return }
        do {
            try shortcutMonitor.start(shortcutKey: settings.shortcutKey)
        } catch {
            // The menu remains usable if the optional global shortcut has no permission.
            debugLog.setError(error)
        }
    }

    func startDictation() {
        guard !isShuttingDown else { return }
        cancelCurrentTypingAndRecognition()
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            guard await self.requestMicrophonePermission(), !Task.isCancelled else {
                if !Task.isCancelled { self.activity = .error("Microphone permission is required.") }
                return
            }
            guard self.accessibilityPermissionState() == .granted else {
                self.permissions.requestAccessibility()
                self.activity = .error("Allow Accessibility, then start dictation again.")
                return
            }

            if let liveRecognizer = self.recognizer as? any LiveSpeechRecognizing {
                do {
                    self.resetLiveTypingState()
                    try await liveRecognizer.startLiveTranscription(
                        model: self.settings.selectedModel,
                        onPartialTranscription: { [weak self] transcription in
                            DispatchQueue.main.async {
                                self?.receiveLivePartial(transcription)
                            }
                        },
                        onPauseDetected: { [weak self] in
                            DispatchQueue.main.async { self?.handleLivePause() }
                        }
                    )
                    if Task.isCancelled {
                        await liveRecognizer.cancelLiveTranscription()
                    } else {
                        self.activity = .recording
                        self.startSound?.play()
                    }
                } catch {
                    self.debugLog.setError(error)
                    self.activity = .error(error.localizedDescription)
                }
                return
            }

            do {
                _ = try self.recorder.start()
                if Task.isCancelled {
                    _ = self.recorder.stop()
                } else {
                    self.activity = .recording
                    self.startSound?.play()
                }
            } catch {
                self.debugLog.setError(error)
                self.activity = .error(error.localizedDescription)
            }
        }
    }

    /// Stops microphone capture and runs local transcription. It is also used for a PTT release.
    func stopAndTranscribe() {
        guard !isShuttingDown else { return }
        startTask?.cancel()
        startTask = nil

        if let liveRecognizer = recognizer as? any LiveSpeechRecognizing {
            guard activity == .recording else {
                if activity == .typing { cancelCurrentTypingAndRecognition() }
                return
            }

            // Do not cancel a pause rollover here. It owns the completed segment's full
            // transcription; cancelling it would make a double-tap discard that segment.
            let activeRolloverTask = pauseRolloverTask
            if activeRolloverTask == nil {
                pausedSegmentTypingBatchID = nil
                defersNextSegmentTyping = false
                pendingLivePause = false
            }
            stopSound?.play()
            activity = .transcribing
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let recognized = try await LiveTranscriptionStopSequencer.finalize(
                        after: activeRolloverTask,
                        using: liveRecognizer
                    )
                    guard !Task.isCancelled else { return }
                    self.finishLiveTranscription(recognized)
                } catch is CancellationError {
                    if self.activity == .transcribing { self.activity = .idle }
                } catch SpeechError.emptyTranscription {
                    if let fallback = LiveTranscriptReconciler.fallbackFinalTranscript(
                        lastHypothesis: self.previousLiveHypothesis,
                        liveTypedText: self.liveTypedText
                    ) {
                        self.finishLiveTranscription(fallback)
                    } else if self.activity == .transcribing {
                        self.activity = .idle
                    }
                } catch {
                    self.debugLog.setError(error)
                    self.activity = .error(error.localizedDescription)
                }
            }
            return
        }

        guard activity == .recording, let recordingURL = recorder.stop() else {
            if activity == .typing { cancelCurrentTypingAndRecognition() }
            return
        }

        stopSound?.play()
        activity = .transcribing
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: recordingURL) }
            do {
                let recognized = try await self.recognizer.transcribe(
                    audioURL: recordingURL,
                    model: self.settings.selectedModel
                )
                guard !Task.isCancelled else { return }
                self.typeTranscription(recognized)
            } catch is CancellationError {
                if self.activity == .transcribing { self.activity = .idle }
            } catch {
                self.debugLog.setError(error)
                self.activity = .error(error.localizedDescription)
            }
        }
    }

    func cancelCurrentOperation() {
        startTask?.cancel()
        startTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        pauseRolloverTask?.cancel()
        pauseRolloverTask = nil
        pausedSegmentTypingBatchID = nil
        defersNextSegmentTyping = false
        pendingLivePause = false
        if let liveRecognizer = recognizer as? any LiveSpeechRecognizing {
            Task { await liveRecognizer.cancelLiveTranscription() }
        } else if activity == .recording {
            _ = recorder.stop()
        }
        typingEngine.cancel()
        typingBatchID = nil
        resetLiveTypingState()
        activity = .idle
    }

    /// Stops every input/output path before AppKit tears the process down. In particular, a
    /// queued global-shortcut action must not be allowed to start a new capture while quitting.
    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        shortcutMonitor.stop()
        startSound?.stop()
        stopSound?.stop()
        cancelCurrentOperation()
    }

    func installSelectedModel() {
        guard activity != .installingModel else { return }
        cancelCurrentOperation()
        activity = .installingModel
        let model = settings.selectedModel
        modelInstallationProgress = 0
        modelInstallationStatus = "Downloading \(model.displayName)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recognizer.install(model: model) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.activity == .installingModel else { return }
                        self.modelInstallationProgress = progress
                        self.modelInstallationStatus = progress < 1
                            ? "Downloading \(model.displayName)… \(Int((progress * 100).rounded()))%"
                            : "Preparing \(model.displayName)…"
                    }
                }
                self.modelInstallationProgress = 1
                self.modelInstallationStatus = "\(model.displayName) is ready"
                self.activity = .idle
            } catch {
                self.debugLog.setError(error)
                self.modelInstallationProgress = nil
                self.modelInstallationStatus = nil
                self.activity = .error(error.localizedDescription)
            }
        }
    }

    func openModelsFolder() {
        modelStore.openInFinder()
    }

    private func cancelCurrentTypingAndRecognition() {
        let shouldCancelLiveCapture = activity == .recording || activity == .transcribing
        typingEngine.cancel()
        typingBatchID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        pauseRolloverTask?.cancel()
        pauseRolloverTask = nil
        pausedSegmentTypingBatchID = nil
        defersNextSegmentTyping = false
        pendingLivePause = false
        if let liveRecognizer = recognizer as? any LiveSpeechRecognizing,
           shouldCancelLiveCapture {
            Task { await liveRecognizer.cancelLiveTranscription() }
        } else if activity == .recording {
            _ = recorder.stop()
        }
        if activity == .typing || activity == .transcribing || activity == .recording { activity = .idle }
        resetLiveTypingState()
    }

    private func typeTranscription(_ recognized: String) {
        let prepared = TranscriptionTextNormalizer.prepare(
            recognized,
            autoCapitalizeFirstSentence: settings.autoCapitalizeFirstSentence,
            appendReturn: settings.pressEnterAfterTranscription
        )
        debugLog.setRecognized(prepared)
        activity = .typing
        typingBatchID = typingEngine.type(
            prepared,
            configuration: settings.typingConfiguration
        )
    }

    /// Live typing emits only completed text shared by two consecutive hypotheses. A confirmed
    /// revision can backspace and replace the changed suffix; decoder loops are still rejected.
    private func handleLiveHypothesis(_ recognized: String) {
        let hypothesis = TranscriptionTextNormalizer.prepare(
            recognized,
            autoCapitalizeFirstSentence: settings.autoCapitalizeFirstSentence,
            appendReturn: false
        )
        debugLog.setRecognized(hypothesis)

        let stableText = LiveTranscriptReconciler.textForLiveUpdate(
            previousHypothesis: previousLiveHypothesis,
            currentHypothesis: hypothesis,
            hasTypedText: !liveTypedText.isEmpty
        )
        previousLiveHypothesis = hypothesis
        appendLiveText(to: stableText)
    }

    private func receiveLivePartial(_ transcription: String) {
        guard activity == .recording, !defersNextSegmentTyping else { return }
        handleLiveHypothesis(transcription)
    }

    /// A pause ends one dictation segment without changing the listening state. The recognizer
    /// starts capturing the next segment before this task decodes the prior one, while live
    /// output for that new segment waits until the prior segment's final text is fully typed.
    private func handleLivePause() {
        guard activity == .recording else { return }
        guard !defersNextSegmentTyping else {
            pendingLivePause = true
            return
        }
        guard pauseRolloverTask == nil,
              let liveRecognizer = recognizer as? any LiveSpeechRecognizing
        else {
            return
        }

        defersNextSegmentTyping = true
        pauseRolloverTask = Task { [weak self] in
            guard let self else { return }
            do {
                let recognized = try await liveRecognizer.rolloverLiveTranscription(
                    onPartialTranscription: { [weak self] transcription in
                        DispatchQueue.main.async { self?.receiveLivePartial(transcription) }
                    },
                    onPauseDetected: { [weak self] in
                        DispatchQueue.main.async { self?.handleLivePause() }
                    }
                )
                // A manual stop can change the activity to `.transcribing` while this pause
                // rollover decodes. Keep its completed segment: the manual-stop task waits for
                // us before it finalizes the successor capture.
                guard !Task.isCancelled,
                      self.activity == .recording || self.activity == .transcribing
                else {
                    return
                }
                self.enqueuePausedSegmentFinalText(recognized)
            } catch is CancellationError {
                if self.activity == .recording { self.resumeNextSegmentTyping() }
            } catch SpeechError.emptyTranscription {
                // A noise-only segment should not interrupt the next recording.
                if self.activity == .recording { self.resumeNextSegmentTyping() }
            } catch {
                // `rolloverLiveTranscription` has already started the successor capture before
                // it finalizes the paused segment. A final-pass error must therefore stop that
                // successor as well; otherwise the menu reports an error while the microphone
                // continues recording in the background.
                await liveRecognizer.cancelLiveTranscription()
                guard !Task.isCancelled else { return }
                self.debugLog.setError(error)
                self.activity = .error(error.localizedDescription)
            }
            self.pauseRolloverTask = nil
            if self.activity == .recording, !self.defersNextSegmentTyping {
                self.resumeNextSegmentTyping()
            }
        }
    }

    private func finishLiveTranscription(_ recognized: String) {
        let prepared = TranscriptionTextNormalizer.prepare(
            recognized,
            autoCapitalizeFirstSentence: settings.autoCapitalizeFirstSentence,
            appendReturn: settings.pressEnterAfterTranscription
        )
        debugLog.setRecognized(prepared)

        let edit: String
        if liveTypedText.isEmpty {
            edit = prepared
        } else {
            edit = LiveTranscriptReconciler.finalEdit(from: liveTypedText, to: prepared)
        }
        resetLiveTypingState()

        activity = .typing
        // Earlier stable live text may still be waiting in the keyboard queue. Appending keeps
        // the final suffix behind it instead of cancelling it and inserting the suffix mid-text.
        typingBatchID = typingEngine.enqueue(edit, configuration: settings.typingConfiguration)
    }

    private func enqueuePausedSegmentFinalText(_ recognized: String) {
        let prepared = TranscriptionTextNormalizer.prepare(
            recognized,
            autoCapitalizeFirstSentence: settings.autoCapitalizeFirstSentence,
            appendReturn: false
        )
        debugLog.setRecognized(prepared)

        let edit = liveTypedText.isEmpty
            ? prepared
            : LiveTranscriptReconciler.finalEdit(from: liveTypedText, to: prepared)
        resetLiveTypingState()

        pausedSegmentTypingBatchID = typingEngine.enqueue(
            segmentBoundaryEdit(edit),
            configuration: settings.typingConfiguration
        )
        if pausedSegmentTypingBatchID == nil {
            resumeNextSegmentTyping()
        }
    }

    private func resumeNextSegmentTyping() {
        defersNextSegmentTyping = false
        guard pendingLivePause else { return }
        guard pauseRolloverTask == nil else { return }
        pendingLivePause = false
        // The recognizer reported a pause while the prior segment was still being typed.
        // Start its rollover now that the next segment is allowed to make progress.
        handleLivePause()
    }

    private func appendLiveText(to stableText: String) {
        guard !stableText.isEmpty else { return }

        let edit: String
        if liveTypedText.isEmpty {
            edit = stableText
        } else {
            guard let liveEdit = LiveTranscriptReconciler.liveEdit(from: liveTypedText, to: stableText) else {
                return
            }
            edit = liveEdit
        }
        guard !edit.isEmpty else { return }
        liveTypedText = stableText
        typingEngine.enqueue(edit, configuration: settings.typingConfiguration)
    }

    /// An automatic pause keeps dictation continuous, so make the boundary explicit even when
    /// Whisper's finalized segment has no trailing whitespace or punctuation.
    private func segmentBoundaryEdit(_ edit: String) -> String {
        guard !edit.isEmpty else { return " " }
        return edit.last?.isWhitespace == true ? edit : edit + " "
    }

    private func resetLiveTypingState() {
        liveTypedText = ""
        previousLiveHypothesis = ""
    }

    private func handleShortcut() {
        guard !isShuttingDown else { return }
        activity == .recording ? stopAndTranscribe() : startDictation()
    }

}
