import AppKit
import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var activity: AppActivity = .idle
    @Published private(set) var modelInstallationProgress: Double?
    @Published private(set) var modelInstallationStatus: String?
    @Published private(set) var liveAudioLevels = Array(repeating: 0.05, count: 36)
    @Published private(set) var reviewTranscription = ""
    /// Increments whenever the configured shortcut completes, allowing setup to verify it live.
    @Published private(set) var shortcutRecognitionCount = 0

    let settings: AppSettings
    let permissions: PermissionManager
    let debugLog: DebugLogStore
    let modelStore: ModelStore

    private let recorder: AudioRecorder
    private let recognizer: SpeechRecognizing
    private let liveRecognizer: (any LiveSpeechRecognizing)?
    private let typingEngine: TypingEngine
    private let shortcutMonitor: GlobalShortcutMonitor
    private let inputDevicePolicy: CoreAudioInputDevicePolicy
    private let requestMicrophonePermission: () async -> Bool
    private let accessibilityPermissionState: () -> PermissionState
    private let frontmostApplication: () -> NSRunningApplication?
    private let activateApplication: (NSRunningApplication) -> Bool
    private let startSound = NSSound(named: NSSound.Name("Tink"))
    private let stopSound = NSSound(named: NSSound.Name("Pop"))
    private var transcriptionTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var liveCancellationTask: Task<Void, Never>?
    private var modelInstallationTask: Task<Void, Never>?
    private var dictationSessionGeneration = 0
    private var hasStartedInitialModelInstallation = false
    private var liveTypedText = ""
    private var previousLiveHypothesis = ""
    private var typingBatchID: UUID?
    private var pauseRolloverTask: Task<Void, Never>?
    private var pausedSegmentTypingBatchID: UUID?
    private var defersNextSegmentTyping = false
    private var pendingLivePause = false
    private var isShuttingDown = false
    private let liveAudioLevelHistoryCount = 36
    private var activeTranscriptionMode: TranscriptionMode?
    private var reviewFinalizedSegments: [String] = []
    private var dictationTargetApplication: NSRunningApplication?
    private var holdShortcutIsDown = false
    private var stopHoldDictationWhenRecordingStarts = false
    private var isStartingDictation = false

    var isReviewBeforeTyping: Bool {
        (activeTranscriptionMode ?? settings.transcriptionMode) == .reviewBeforeTyping
    }

    /// The app that owned text focus when this dictation began. The review panel uses this to
    /// appear on that app's display, including a separate full-screen Space.
    var dictationTarget: NSRunningApplication? { dictationTargetApplication }

    init() {
        self.settings = AppSettings()
        self.permissions = PermissionManager()
        self.recorder = AudioRecorder()
        let modelStore = ModelStore()
        let recognizer = WhisperKitSpeechRecognizer(modelStore: modelStore)
        self.recognizer = recognizer
        self.liveRecognizer = recognizer as? any LiveSpeechRecognizing
        self.typingEngine = TypingEngine()
        self.shortcutMonitor = GlobalShortcutMonitor()
        self.inputDevicePolicy = CoreAudioInputDevicePolicy()
        self.debugLog = DebugLogStore()
        self.modelStore = modelStore
        self.requestMicrophonePermission = { [permissions] in
            await permissions.requestMicrophone()
        }
        self.accessibilityPermissionState = { [permissions] in permissions.accessibility }
        self.frontmostApplication = { NSWorkspace.shared.frontmostApplication }
        self.activateApplication = { application in
            application.activate(options: [])
        }

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
        inputDevicePolicy: CoreAudioInputDevicePolicy = CoreAudioInputDevicePolicy(),
        requestMicrophonePermission: (() async -> Bool)? = nil,
        accessibilityPermissionState: (() -> PermissionState)? = nil,
        frontmostApplication: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        activateApplication: @escaping (NSRunningApplication) -> Bool = { application in
            application.activate(options: [])
        }
    ) {
        self.settings = settings
        self.permissions = permissions
        self.recorder = recorder
        self.recognizer = recognizer
        self.liveRecognizer = recognizer as? any LiveSpeechRecognizing
        self.typingEngine = typingEngine
        self.shortcutMonitor = shortcutMonitor
        self.inputDevicePolicy = inputDevicePolicy
        self.debugLog = debugLog
        self.modelStore = modelStore
        self.requestMicrophonePermission = requestMicrophonePermission ?? { [permissions] in
            await permissions.requestMicrophone()
        }
        self.accessibilityPermissionState = accessibilityPermissionState ?? { [permissions] in
            permissions.accessibility
        }
        self.frontmostApplication = frontmostApplication
        self.activateApplication = activateApplication

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
            self.activeTranscriptionMode = nil
            self.dictationTargetApplication = nil
            self.activity = .idle
        }
        typingEngine.onTyped = { [weak self] event in self?.debugLog.append(event) }
        typingEngine.onTypedBatch = { [weak self] events in self?.debugLog.append(events) }
        typingEngine.onError = { [weak self] error in
            self?.debugLog.setError(error)
            self?.typingBatchID = nil
            self?.activity = .error(error.localizedDescription)
        }
        shortcutMonitor.onAction = { [weak self] in
            self?.recordShortcutRecognition()
            self?.handleShortcut()
        }
        shortcutMonitor.onHoldStarted = { [weak self] in
            self?.recordShortcutRecognition()
            self?.handleHoldShortcutStarted()
        }
        shortcutMonitor.onHoldEnded = { [weak self] in
            self?.handleHoldShortcutEnded()
        }
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
        holdShortcutIsDown = false
        stopHoldDictationWhenRecordingStarts = false
        guard !isShuttingDown else { return }
        guard settings.shortcutIsEnabled else { return }
        do {
            try shortcutMonitor.start(
                shortcut: settings.shortcutConfiguration,
                activationMode: settings.shortcutActivationMode,
                doublePressIntervalMilliseconds: settings.shortcutDoublePressIntervalMilliseconds
            )
        } catch {
            // The menu remains usable if the optional global shortcut has no permission.
            debugLog.setError(error)
        }
    }

    func startDictation() {
        guard !isShuttingDown, activity != .installingModel else { return }
        cancelCurrentTypingAndRecognition()
        dictationSessionGeneration &+= 1
        let sessionGeneration = dictationSessionGeneration
        isStartingDictation = true
        activeTranscriptionMode = settings.transcriptionMode
        dictationTargetApplication = frontmostApplication()
        resetReviewState()
        resetLiveAudioLevels()
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            await self.liveCancellationTask?.value
            guard self.isCurrentDictationSession(sessionGeneration), !Task.isCancelled else { return }
            guard await self.requestMicrophonePermission(), !Task.isCancelled else {
                self.isStartingDictation = false
                if !Task.isCancelled { self.activity = .error("Microphone permission is required.") }
                return
            }
            guard self.isCurrentDictationSession(sessionGeneration) else { return }
            guard self.accessibilityPermissionState() == .granted else {
                self.isStartingDictation = false
                self.permissions.requestAccessibility()
                self.activity = .error("Allow Accessibility, then start dictation again.")
                return
            }

            if let liveRecognizer = self.liveRecognizer {
                do {
                    self.resetLiveTypingState()
                    let effectiveInputDeviceID = self.inputDevicePolicy.effectiveInputDeviceID(
                        for: self.settings.inputDeviceID
                    )
                    await liveRecognizer.setInputDeviceID(effectiveInputDeviceID)
                    await liveRecognizer.setLiveAudioLevelHandler { [weak self] level in
                        DispatchQueue.main.async {
                            self?.receiveLiveAudioLevel(level)
                        }
                    }
                    try await liveRecognizer.startLiveTranscription(
                        model: self.settings.selectedModel,
                        onPartialTranscription: { [weak self] transcription in
                            DispatchQueue.main.async {
                                self?.receiveLivePartial(transcription, sessionGeneration: sessionGeneration)
                            }
                        },
                        onPauseDetected: { [weak self] in
                            DispatchQueue.main.async { self?.handleLivePause(sessionGeneration: sessionGeneration) }
                        }
                    )
                    if Task.isCancelled || !self.isCurrentDictationSession(sessionGeneration) {
                        await liveRecognizer.cancelLiveTranscription()
                    } else {
                        self.recordingDidStart(sessionGeneration: sessionGeneration)
                    }
                } catch {
                    guard self.isCurrentDictationSession(sessionGeneration) else { return }
                    self.isStartingDictation = false
                    self.debugLog.setError(error)
                    self.activity = .error(error.localizedDescription)
                }
                return
            }

            do {
                self.recorder.setAudioLevelHandler { [weak self] level in
                    DispatchQueue.main.async {
                        self?.receiveLiveAudioLevel(level)
                    }
                }
                let effectiveInputDeviceID = self.inputDevicePolicy.effectiveInputDeviceID(
                    for: self.settings.inputDeviceID
                )
                _ = try self.recorder.start(inputDeviceID: effectiveInputDeviceID)
                if Task.isCancelled || !self.isCurrentDictationSession(sessionGeneration) {
                    _ = self.recorder.stop()
                    self.recorder.setAudioLevelHandler(nil)
                } else {
                    self.recordingDidStart(sessionGeneration: sessionGeneration)
                }
            } catch {
                guard self.isCurrentDictationSession(sessionGeneration) else { return }
                self.isStartingDictation = false
                self.debugLog.setError(error)
                self.activity = .error(error.localizedDescription)
            }
        }
    }

    /// Stops microphone capture and runs local transcription.
    func stopAndTranscribe() {
        guard !isShuttingDown else { return }
        isStartingDictation = false
        startTask?.cancel()
        startTask = nil

        if let liveRecognizer {
            let sessionGeneration = dictationSessionGeneration
            guard activity == .recording else {
                if activity == .typing { cancelCurrentTypingAndRecognition() }
                return
            }

            // Do not cancel a pause rollover here. It owns the completed segment's full
            // transcription; cancelling it would discard that completed segment.
            let activeRolloverTask = pauseRolloverTask
            if activeRolloverTask == nil {
                pausedSegmentTypingBatchID = nil
                defersNextSegmentTyping = false
                pendingLivePause = false
            }
            stopSound?.play()
            resetLiveAudioLevels()
            activity = .transcribing
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let recognized = try await LiveTranscriptionStopSequencer.finalize(
                        after: activeRolloverTask,
                        using: liveRecognizer
                    )
                    guard !Task.isCancelled, self.isCurrentDictationSession(sessionGeneration) else { return }
                    self.finishLiveTranscription(recognized)
                } catch is CancellationError {
                    if self.activity == .transcribing { self.activity = .idle }
                } catch SpeechError.emptyTranscription {
                    self.finishEmptyLiveTranscription()
                } catch {
                    self.debugLog.setError(error)
                    self.activity = .error(error.localizedDescription)
                }
            }
            return
        }

        guard activity == .recording else {
            if activity == .typing { cancelCurrentTypingAndRecognition() }
            return
        }

        let recordingURL: URL
        do {
            guard let stoppedURL = try recorder.stopRecording() else { return }
            recordingURL = stoppedURL
        } catch {
            recorder.setAudioLevelHandler(nil)
            resetLiveAudioLevels()
            debugLog.setError(error)
            activity = .error(error.localizedDescription)
            return
        }

        recorder.setAudioLevelHandler(nil)
        stopSound?.play()
        resetLiveAudioLevels()
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
        isStartingDictation = false
        dictationSessionGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        modelInstallationTask?.cancel()
        modelInstallationTask = nil
        pauseRolloverTask?.cancel()
        pauseRolloverTask = nil
        pausedSegmentTypingBatchID = nil
        defersNextSegmentTyping = false
        pendingLivePause = false
        if let liveRecognizer {
            beginLiveCancellation(using: liveRecognizer)
        } else if activity == .recording {
            _ = recorder.stop()
            recorder.setAudioLevelHandler(nil)
        }
        typingEngine.cancel()
        typingBatchID = nil
        resetLiveTypingState()
        resetReviewState()
        activeTranscriptionMode = nil
        dictationTargetApplication = nil
        resetLiveAudioLevels()
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
        guard !isShuttingDown, activity != .installingModel else { return }
        // A model download uses the same WhisperKit resources as dictation. Stop listening for
        // the shortcut until the install has finished so it cannot start a competing capture.
        shortcutMonitor.stop()
        cancelCurrentOperation()
        activity = .installingModel
        let model = settings.selectedModel
        modelInstallationProgress = 0
        modelInstallationStatus = "Downloading \(model.displayName)…"
        modelInstallationTask?.cancel()
        modelInstallationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.modelInstallationTask = nil
                self.restartShortcutMonitor()
            }
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
                guard !Task.isCancelled else { return }
                self.modelInstallationProgress = 1
                self.modelInstallationStatus = "\(model.displayName) is ready"
                self.activity = .idle
            } catch {
                guard !Task.isCancelled else { return }
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

    /// Removes all app-owned files and preferences. Callers terminate the app immediately after
    /// this succeeds, preventing stale in-memory settings from recreating the cleared defaults.
    func deleteAllLocalData() throws {
        try modelStore.removeAllLocalData()
        settings.removeAllStoredValues()
    }

    private func cancelCurrentTypingAndRecognition() {
        let shouldCancelLiveCapture = activity == .recording || activity == .transcribing
        dictationSessionGeneration &+= 1
        typingEngine.cancel()
        typingBatchID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        pauseRolloverTask?.cancel()
        pauseRolloverTask = nil
        pausedSegmentTypingBatchID = nil
        defersNextSegmentTyping = false
        pendingLivePause = false
        if let liveRecognizer,
           shouldCancelLiveCapture {
            beginLiveCancellation(using: liveRecognizer)
        } else if activity == .recording {
            _ = recorder.stop()
            recorder.setAudioLevelHandler(nil)
        }
        if activity == .typing || activity == .transcribing || activity == .recording || activity == .reviewing {
            activity = .idle
        }
        resetLiveTypingState()
        resetReviewState()
        activeTranscriptionMode = nil
        dictationTargetApplication = nil
        resetLiveAudioLevels()
    }

    private func typeTranscription(_ recognized: String) {
        guard !isReviewBeforeTyping else {
            finishReviewTranscription(recognized)
            return
        }
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

        let previousHypothesis = previousLiveHypothesis
        previousLiveHypothesis = hypothesis

        guard !isReviewBeforeTyping else {
            reviewTranscription = preparedReviewTranscription(
                reviewFinalizedSegments + [recognized]
            )
            return
        }

        let stableText = LiveTranscriptReconciler.textForLiveUpdate(
            previousHypothesis: previousHypothesis,
            currentHypothesis: hypothesis,
            hasTypedText: !liveTypedText.isEmpty
        )
        appendLiveText(to: stableText)
    }

    private func receiveLivePartial(_ transcription: String, sessionGeneration: Int) {
        guard isCurrentDictationSession(sessionGeneration), activity == .recording, !defersNextSegmentTyping else { return }
        handleLiveHypothesis(transcription)
    }

    /// A pause ends one dictation segment without changing the listening state. The recognizer
    /// starts capturing the next segment before this task decodes the prior one, while live
    /// output for that new segment waits until the prior segment's final text is fully typed.
    private func handleLivePause(sessionGeneration: Int) {
        guard isCurrentDictationSession(sessionGeneration), activity == .recording else { return }
        guard !defersNextSegmentTyping else {
            pendingLivePause = true
            return
        }
        guard pauseRolloverTask == nil,
              let liveRecognizer
        else {
            return
        }

        defersNextSegmentTyping = true
        pauseRolloverTask = Task { [weak self] in
            guard let self else { return }
            do {
                    let recognized = try await liveRecognizer.rolloverLiveTranscription(
                        onPartialTranscription: { [weak self] transcription in
                            DispatchQueue.main.async {
                                self?.receiveLivePartial(transcription, sessionGeneration: sessionGeneration)
                            }
                        },
                        onPauseDetected: { [weak self] in
                            DispatchQueue.main.async { self?.handleLivePause(sessionGeneration: sessionGeneration) }
                        }
                    )
                // An explicit stop can change the activity to `.transcribing` while this pause
                // rollover decodes. Keep its completed segment: the stop task waits for
                // us before it finalizes the successor capture.
                guard !Task.isCancelled,
                      self.isCurrentDictationSession(sessionGeneration),
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
                guard !Task.isCancelled, self.isCurrentDictationSession(sessionGeneration) else { return }
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
        guard !isReviewBeforeTyping else {
            finishReviewTranscription(combineReviewSegments(with: recognized))
            return
        }
        guard ensureOriginalTargetStillActiveForLiveTyping() else { return }
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
        guard !isReviewBeforeTyping else {
            let segment = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                reviewFinalizedSegments.append(segment)
            }
            reviewTranscription = preparedReviewTranscription(reviewFinalizedSegments)
            debugLog.setRecognized(reviewTranscription)
            resetLiveTypingState()
            resumeNextSegmentTyping()
            return
        }
        guard ensureOriginalTargetStillActiveForLiveTyping() else { return }

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
        handleLivePause(sessionGeneration: dictationSessionGeneration)
    }

    private func appendLiveText(to stableText: String) {
        guard !stableText.isEmpty else { return }
        guard ensureOriginalTargetStillActiveForLiveTyping() else { return }

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

    private func finishEmptyLiveTranscription() {
        let fallback = LiveTranscriptReconciler.fallbackFinalTranscript(
            lastHypothesis: previousLiveHypothesis,
            liveTypedText: liveTypedText
        )
        if isReviewBeforeTyping {
            let reviewed = combineReviewSegments(with: fallback ?? "")
            if reviewed.isEmpty {
                if activity == .transcribing { activity = .idle }
            } else {
                finishReviewTranscription(reviewed)
            }
        } else if let fallback {
            finishLiveTranscription(fallback)
        } else if activity == .transcribing {
            activity = .idle
        }
    }

    private func combineReviewSegments(with finalSegment: String) -> String {
        let segments = reviewFinalizedSegments + [finalSegment]
        return segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func preparedReviewTranscription(_ segments: [String]) -> String {
        let combined = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return TranscriptionTextNormalizer.prepare(
            combined,
            autoCapitalizeFirstSentence: settings.autoCapitalizeFirstSentence,
            appendReturn: false
        )
    }

    private func finishReviewTranscription(_ recognized: String) {
        let prepared = TranscriptionTextNormalizer.prepare(
            recognized,
            autoCapitalizeFirstSentence: settings.autoCapitalizeFirstSentence,
            appendReturn: settings.pressEnterAfterTranscription
        )
        guard !prepared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            activity = .idle
            return
        }
        reviewTranscription = prepared
        debugLog.setRecognized(prepared)
        resetLiveTypingState()
        activity = .reviewing
    }

    func acceptReviewedTranscription() {
        guard activity == .reviewing else { return }
        let transcription = reviewTranscription
        guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelCurrentOperation()
            return
        }

        let targetApplication = dictationTargetApplication
        reviewFinalizedSegments = []
        activity = .typing
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activity == .typing else { return }
            self.typeReviewedTranscription(
                transcription,
                into: targetApplication,
                remainingFocusChecks: 12
            )
        }
    }

    /// Activation is asynchronous. Waiting briefly for the captured target to become active
    /// avoids emitting the accepted text while WhisperKeys' panel is still the front process.
    private func typeReviewedTranscription(
        _ transcription: String,
        into targetApplication: NSRunningApplication?,
        remainingFocusChecks: Int
    ) {
        guard activity == .typing else { return }
        guard let targetApplication, !targetApplication.isTerminated else {
            typingBatchID = typingEngine.type(
                transcription,
                configuration: settings.typingConfiguration
            )
            return
        }

        guard targetApplication.isActive else {
            _ = activateApplication(targetApplication)
            guard remainingFocusChecks > 0 else {
                debugLog.setError(
                    NSError(
                        domain: "WhisperKeys",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not return focus to \(targetApplication.localizedName ?? "the original app")."]
                    )
                )
                activity = .error("Could not return focus to \(targetApplication.localizedName ?? "the original app").")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.typeReviewedTranscription(
                    transcription,
                    into: targetApplication,
                    remainingFocusChecks: remainingFocusChecks - 1
                )
            }
            return
        }

        typingBatchID = typingEngine.type(
            transcription,
            configuration: settings.typingConfiguration
        )
    }

    private func resetReviewState() {
        reviewTranscription = ""
        reviewFinalizedSegments = []
    }

    func updateReviewedTranscription(_ text: String) {
        guard activity == .reviewing else { return }
        reviewTranscription = text
        debugLog.setRecognized(text)
    }

    private func receiveLiveAudioLevel(_ level: Float) {
        guard activity == .recording else { return }
        let normalized = min(max(Double(level), 0), 1)
        liveAudioLevels.append(max(0.025, normalized))
        if liveAudioLevels.count > liveAudioLevelHistoryCount {
            liveAudioLevels.removeFirst(liveAudioLevels.count - liveAudioLevelHistoryCount)
        }
    }

    private func resetLiveAudioLevels() {
        liveAudioLevels = Array(repeating: 0.05, count: liveAudioLevelHistoryCount)
    }

    private func handleShortcut() {
        guard !isShuttingDown, activity != .installingModel else { return }
        switch activity {
        case .recording:
            stopAndTranscribe()
        case .reviewing:
            break
        default:
            startDictation()
        }
    }

    private func recordShortcutRecognition() {
        shortcutRecognitionCount &+= 1
    }

    private func handleHoldShortcutStarted() {
        guard !isShuttingDown, activity != .installingModel else { return }
        guard !holdShortcutIsDown else { return }
        holdShortcutIsDown = true
        stopHoldDictationWhenRecordingStarts = false

        guard activity != .recording, activity != .transcribing, activity != .reviewing else { return }
        startDictation()
    }

    private func handleHoldShortcutEnded() {
        guard holdShortcutIsDown else { return }
        holdShortcutIsDown = false
        if activity == .recording {
            stopAndTranscribe()
        } else if isStartingDictation {
            // Permission and model startup are asynchronous. If the user releases before the
            // microphone begins recording, stop immediately after that startup completes.
            stopHoldDictationWhenRecordingStarts = true
        }
    }

    private func recordingDidStart(sessionGeneration: Int) {
        guard isCurrentDictationSession(sessionGeneration) else { return }
        isStartingDictation = false
        activity = .recording
        startSound?.play()
        if stopHoldDictationWhenRecordingStarts {
            stopHoldDictationWhenRecordingStarts = false
            stopAndTranscribe()
        }
    }

    private func isCurrentDictationSession(_ sessionGeneration: Int) -> Bool {
        dictationSessionGeneration == sessionGeneration
    }

    private func beginLiveCancellation(using liveRecognizer: any LiveSpeechRecognizing) {
        let priorCancellation = liveCancellationTask
        liveCancellationTask = Task {
            await priorCancellation?.value
            await liveRecognizer.cancelLiveTranscription()
        }
    }

    private func ensureOriginalTargetStillActiveForLiveTyping() -> Bool {
        guard !isReviewBeforeTyping, let targetApplication = dictationTargetApplication else { return true }
        guard !targetApplication.isTerminated, targetApplication.isActive else {
            let appName = targetApplication.localizedName ?? "the original app"
            let message = "Stopped dictation because focus moved away from \(appName)."
            beginLiveCancellationIfAvailable()
            debugLog.setError(NSError(domain: "WhisperKeys", code: 2, userInfo: [NSLocalizedDescriptionKey: message]))
            activity = .error(message)
            return false
        }
        return true
    }

    private func beginLiveCancellationIfAvailable() {
        guard let liveRecognizer else { return }
        beginLiveCancellation(using: liveRecognizer)
    }

}
