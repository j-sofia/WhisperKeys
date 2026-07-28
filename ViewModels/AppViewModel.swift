import AppKit
import Combine
import Foundation

protocol SoundPlaying: AnyObject {
    @discardableResult
    func play() -> Bool
    @discardableResult
    func stop() -> Bool
}

extension NSSound: SoundPlaying {}

@MainActor
protocol TargetApplicationActivating: AnyObject {
    func frontmostApplication() -> NSRunningApplication?
    @discardableResult
    func activate(_ application: NSRunningApplication) -> Bool
    func isActive(_ application: NSRunningApplication) -> Bool
    func isTerminated(_ application: NSRunningApplication) -> Bool
}

@MainActor
final class WorkspaceTargetApplicationActivator: TargetApplicationActivating {
    func frontmostApplication() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    func activate(_ application: NSRunningApplication) -> Bool {
        application.activate(options: [])
    }

    func isActive(_ application: NSRunningApplication) -> Bool {
        application.isActive
    }

    func isTerminated(_ application: NSRunningApplication) -> Bool {
        application.isTerminated
    }
}

@MainActor
private final class ClosureTargetApplicationActivator: TargetApplicationActivating {
    private let frontmost: () -> NSRunningApplication?
    private let activation: (NSRunningApplication) -> Bool
    private let activeState: (NSRunningApplication) -> Bool
    private let terminatedState: (NSRunningApplication) -> Bool

    init(
        frontmostApplication: @escaping () -> NSRunningApplication?,
        activateApplication: @escaping (NSRunningApplication) -> Bool,
        applicationIsActive: @escaping (NSRunningApplication) -> Bool,
        applicationIsTerminated: @escaping (NSRunningApplication) -> Bool
    ) {
        frontmost = frontmostApplication
        activation = activateApplication
        activeState = applicationIsActive
        terminatedState = applicationIsTerminated
    }

    func frontmostApplication() -> NSRunningApplication? { frontmost() }
    func activate(_ application: NSRunningApplication) -> Bool { activation(application) }
    func isActive(_ application: NSRunningApplication) -> Bool { activeState(application) }
    func isTerminated(_ application: NSRunningApplication) -> Bool { terminatedState(application) }
}

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
    let permissions: any PermissionManaging
    let debugLog: DebugLogStore
    let modelStore: any ModelStoring

    private let recorder: any AudioRecording
    private let recognizer: SpeechRecognizing
    private let typingEngine: TypingEngine
    private let shortcutMonitor: any ShortcutMonitoring
    private let targetApplicationActivator: any TargetApplicationActivating
    private let startSound: (any SoundPlaying)?
    private let stopSound: (any SoundPlaying)?
    private let clock: any ClockProviding
    private let requestMicrophonePermission: () async -> Bool
    private let accessibilityPermissionState: () -> PermissionState
    private var permissionChangesCancellable: AnyCancellable?
    private var dictationSession = DictationSessionStateMachine()
    private var hasStartedInitialModelInstallation = false
    private var isShuttingDown = false
    private let liveAudioLevelHistoryCount = 36
    private var holdShortcutIsDown = false

    var isReviewBeforeTyping: Bool {
        (dictationSession.state.session?.mode ?? settings.transcriptionMode) == .reviewBeforeTyping
    }

    /// The app that owned text focus when this dictation began. The review panel uses this to
    /// appear on that app's display, including a separate full-screen Space.
    var dictationTarget: NSRunningApplication? {
        dictationSession.state.session?.targetApplication
    }

    init() {
        self.settings = AppSettings()
        self.permissions = PermissionManager()
        self.recorder = AudioRecorder()
        let modelStore = ModelStore()
        self.recognizer = WhisperKitSpeechRecognizer(modelStore: modelStore)
        self.typingEngine = TypingEngine()
        self.shortcutMonitor = GlobalShortcutMonitor()
        self.debugLog = DebugLogStore()
        self.modelStore = modelStore
        self.targetApplicationActivator = WorkspaceTargetApplicationActivator()
        self.startSound = NSSound(named: NSSound.Name("Tink"))
        self.stopSound = NSSound(named: NSSound.Name("Pop"))
        self.clock = SystemClock.shared
        self.requestMicrophonePermission = { [permissions] in
            await permissions.requestMicrophone()
        }
        self.accessibilityPermissionState = { [permissions] in permissions.accessibility }

        configureCallbacks()
        observePermissionChanges()
    }

    init(
        settings: AppSettings,
        permissions: any PermissionManaging,
        recorder: any AudioRecording,
        recognizer: SpeechRecognizing,
        typingEngine: TypingEngine,
        shortcutMonitor: any ShortcutMonitoring,
        debugLog: DebugLogStore,
        modelStore: any ModelStoring,
        targetApplicationActivator: (any TargetApplicationActivating)? = nil,
        startSound: (any SoundPlaying)? = NSSound(named: NSSound.Name("Tink")),
        stopSound: (any SoundPlaying)? = NSSound(named: NSSound.Name("Pop")),
        clock: any ClockProviding = SystemClock.shared,
        requestMicrophonePermission: (() async -> Bool)? = nil,
        accessibilityPermissionState: (() -> PermissionState)? = nil,
        frontmostApplication: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        activateApplication: @escaping (NSRunningApplication) -> Bool = { application in
            application.activate(options: [])
        },
        applicationIsActive: @escaping (NSRunningApplication) -> Bool = { $0.isActive },
        applicationIsTerminated: @escaping (NSRunningApplication) -> Bool = { $0.isTerminated }
    ) {
        self.settings = settings
        self.permissions = permissions
        self.recorder = recorder
        self.recognizer = recognizer
        self.typingEngine = typingEngine
        self.shortcutMonitor = shortcutMonitor
        self.debugLog = debugLog
        self.modelStore = modelStore
        self.targetApplicationActivator = targetApplicationActivator
            ?? ClosureTargetApplicationActivator(
                frontmostApplication: frontmostApplication,
                activateApplication: activateApplication,
                applicationIsActive: applicationIsActive,
                applicationIsTerminated: applicationIsTerminated
            )
        self.startSound = startSound
        self.stopSound = stopSound
        self.clock = clock
        self.requestMicrophonePermission = requestMicrophonePermission ?? { [permissions] in
            await permissions.requestMicrophone()
        }
        self.accessibilityPermissionState = accessibilityPermissionState ?? { [permissions] in
            permissions.accessibility
        }

        configureCallbacks()
        observePermissionChanges()
    }

    private func observePermissionChanges() {
        permissionChangesCancellable = permissions.changes.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func configureCallbacks() {
        typingEngine.onCompleted = { [weak self] batchID in
            guard let self else { return }
            if let session = self.dictationSession.state.session,
               case .typing(let segmentBatchID, let pendingPause) = session.liveSegmentState,
               segmentBatchID == batchID {
                session.liveSegmentState = .ready
                self.resumeNextSegmentTyping(for: session, pendingPause: pendingPause)
            }
            guard case .typing(let session) = self.dictationSession.state,
                  session.typingBatchID == batchID
            else {
                return
            }
            session.typingBatchID = nil
            self.transitionSession(to: .idle)
        }
        typingEngine.onTyped = { [weak self] event in self?.debugLog.append(event) }
        typingEngine.onTypedBatch = { [weak self] events in self?.debugLog.append(events) }
        typingEngine.onError = { [weak self] error in
            guard let self else { return }
            self.debugLog.setError(error)
            self.failCurrentSession(
                with: .typing(error),
                logUnderlyingError: false
            )
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
        let session = DictationSession(
            mode: settings.transcriptionMode,
            targetApplication: targetApplicationActivator.frontmostApplication()
        )
        guard transitionSession(to: .starting(session)) else { return }
        resetReviewState()
        resetLiveAudioLevels()
        session.startTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            guard await self.requestMicrophonePermission(), !Task.isCancelled else {
                if !Task.isCancelled, self.isCurrent(session, in: [.starting]) {
                    self.failCurrentSession(with: .microphonePermissionRequired)
                }
                return
            }
            guard self.isCurrent(session, in: [.starting]) else { return }
            guard self.accessibilityPermissionState() == .granted else {
                self.permissions.requestAccessibility()
                self.failCurrentSession(with: .accessibilityPermissionRequired)
                return
            }

            if let liveRecognizer = self.recognizer as? any LiveSpeechRecognizing {
                do {
                    self.resetLiveTypingState(for: session)
                    await liveRecognizer.setInputDeviceID(self.settings.inputDeviceID)
                    await liveRecognizer.setLiveAudioLevelHandler { [weak self] level in
                        DispatchQueue.main.async {
                            self?.receiveLiveAudioLevel(level)
                        }
                    }
                    try await liveRecognizer.startLiveTranscription(
                        model: self.settings.selectedModel,
                        onPartialTranscription: { [weak self] transcription in
                            DispatchQueue.main.async {
                                self?.receiveLivePartial(transcription, for: session)
                            }
                        },
                        onPauseDetected: { [weak self] in
                            DispatchQueue.main.async {
                                self?.handleLivePause(for: session)
                            }
                        }
                    )
                    if Task.isCancelled || !self.isCurrent(session, in: [.starting]) {
                        await liveRecognizer.cancelLiveTranscription()
                    } else {
                        self.recordingDidStart(session)
                    }
                } catch {
                    guard self.isCurrent(session, in: [.starting]) else { return }
                    self.failCurrentSession(with: error)
                }
                return
            }

            do {
                self.recorder.setAudioLevelHandler { [weak self] level in
                    DispatchQueue.main.async {
                        self?.receiveLiveAudioLevel(level)
                    }
                }
                _ = try self.recorder.start(inputDeviceID: self.settings.inputDeviceID)
                if Task.isCancelled || !self.isCurrent(session, in: [.starting]) {
                    _ = self.recorder.stop()
                    self.recorder.setAudioLevelHandler(nil)
                } else {
                    self.recordingDidStart(session)
                }
            } catch {
                guard self.isCurrent(session, in: [.starting]) else { return }
                self.failCurrentSession(with: error)
            }
        }
    }

    /// Stops microphone capture and runs local transcription.
    func stopAndTranscribe() {
        guard !isShuttingDown else { return }
        guard case .recording(let session) = dictationSession.state else {
            if case .typing = dictationSession.state {
                cancelCurrentTypingAndRecognition()
            }
            return
        }
        session.startTask?.cancel()
        session.startTask = nil

        if let liveRecognizer = recognizer as? any LiveSpeechRecognizing {
            // Do not cancel a pause rollover here. It owns the completed segment's full
            // transcription; cancelling it would discard that completed segment.
            let activeRolloverTask = session.liveSegmentState.finalizationTask
            if activeRolloverTask == nil {
                session.liveSegmentState = .ready
            }
            _ = stopSound?.play()
            resetLiveAudioLevels()
            guard transitionSession(to: .transcribing(session)) else { return }
            session.transcriptionTask = Task { [weak self, weak session] in
                guard let self, let session else { return }
                do {
                    let recognized = try await LiveTranscriptionStopSequencer.finalize(
                        after: activeRolloverTask,
                        using: liveRecognizer
                    )
                    guard !Task.isCancelled,
                          self.isCurrent(session, in: [.transcribing])
                    else {
                        return
                    }
                    self.finishLiveTranscription(recognized, for: session)
                } catch is CancellationError {
                    if self.isCurrent(session, in: [.transcribing]) {
                        self.transitionSession(to: .idle)
                    }
                } catch SpeechError.emptyTranscription {
                    guard self.isCurrent(session, in: [.transcribing]) else { return }
                    self.finishEmptyLiveTranscription(for: session)
                } catch {
                    guard self.isCurrent(session, in: [.transcribing]) else { return }
                    self.failCurrentSession(with: error)
                }
            }
            return
        }

        guard let recordingURL = recorder.stop() else { return }

        recorder.setAudioLevelHandler(nil)
        _ = stopSound?.play()
        resetLiveAudioLevels()
        guard transitionSession(to: .transcribing(session)) else { return }
        session.transcriptionTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer { try? FileManager.default.removeItem(at: recordingURL) }
            do {
                let recognized = try await self.recognizer.transcribe(
                    audioURL: recordingURL,
                    model: self.settings.selectedModel
                )
                guard !Task.isCancelled,
                      self.isCurrent(session, in: [.transcribing])
                else {
                    return
                }
                self.typeTranscription(recognized, for: session)
            } catch is CancellationError {
                if self.isCurrent(session, in: [.transcribing]) {
                    self.transitionSession(to: .idle)
                }
            } catch {
                guard self.isCurrent(session, in: [.transcribing]) else { return }
                self.failCurrentSession(with: error)
            }
        }
    }

    func cancelCurrentOperation() {
        let previousPhase = dictationSession.state.phase
        dictationSession.state.session?.cancelTasks()
        if let liveRecognizer = recognizer as? any LiveSpeechRecognizing {
            Task { await liveRecognizer.cancelLiveTranscription() }
        } else if previousPhase == .recording {
            _ = recorder.stop()
            recorder.setAudioLevelHandler(nil)
        }
        typingEngine.cancel()
        resetReviewState()
        resetLiveAudioLevels()
        transitionSession(to: .idle)
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
        Task { [weak self] in
            guard let self else { return }
            defer { self.restartShortcutMonitor() }
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
                self.activity = .error(
                    .modelInstallationFailed(model, details: error.localizedDescription)
                )
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
        let phase = dictationSession.state.phase
        let shouldCancelLiveCapture = phase == .recording || phase == .transcribing
        dictationSession.state.session?.cancelTasks()
        typingEngine.cancel()
        if let liveRecognizer = recognizer as? any LiveSpeechRecognizing,
           shouldCancelLiveCapture {
            Task { await liveRecognizer.cancelLiveTranscription() }
        } else if phase == .recording {
            _ = recorder.stop()
            recorder.setAudioLevelHandler(nil)
        }
        transitionSession(to: .idle)
        resetReviewState()
        resetLiveAudioLevels()
    }

    private func typeTranscription(_ recognized: String, for session: DictationSession) {
        guard session.mode != .reviewBeforeTyping else {
            finishReviewTranscription(recognized, for: session)
            return
        }
        let prepared = TranscriptionTextNormalizer.prepare(
            recognized,
            autoCapitalizeFirstSentence: settings.autoCapitalizeFirstSentence,
            appendReturn: settings.pressEnterAfterTranscription
        )
        debugLog.setRecognized(prepared)
        guard transitionSession(to: .typing(session)) else { return }
        session.typingBatchID = typingEngine.type(
            prepared,
            configuration: settings.typingConfiguration
        )
    }

    /// Live typing emits only completed text shared by two consecutive hypotheses. A confirmed
    /// revision can backspace and replace the changed suffix; decoder loops are still rejected.
    private func handleLiveHypothesis(_ recognized: String, for session: DictationSession) {
        let hypothesis = TranscriptionTextNormalizer.prepare(
            recognized,
            autoCapitalizeFirstSentence: settings.autoCapitalizeFirstSentence,
            appendReturn: false
        )
        debugLog.setRecognized(hypothesis)

        let previousHypothesis = session.previousLiveHypothesis
        session.previousLiveHypothesis = hypothesis

        guard session.mode != .reviewBeforeTyping else {
            reviewTranscription = preparedReviewTranscription(
                session.reviewFinalizedSegments + [recognized]
            )
            return
        }

        let stableText = LiveTranscriptReconciler.textForLiveUpdate(
            previousHypothesis: previousHypothesis,
            currentHypothesis: hypothesis,
            hasTypedText: !session.liveTypedText.isEmpty
        )
        appendLiveText(to: stableText, for: session)
    }

    private func receiveLivePartial(_ transcription: String, for session: DictationSession) {
        guard isCurrent(session, in: [.recording]),
              !session.liveSegmentState.defersPartials
        else {
            return
        }
        handleLiveHypothesis(transcription, for: session)
    }

    /// A pause ends one dictation segment without changing the listening state. The recognizer
    /// starts capturing the next segment before this task decodes the prior one, while live
    /// output for that new segment waits until the prior segment's final text is fully typed.
    private func handleLivePause(for session: DictationSession) {
        guard isCurrent(session, in: [.recording]) else { return }
        switch session.liveSegmentState {
        case .finalizing(let task, _):
            session.liveSegmentState = .finalizing(task: task, pendingPause: true)
            return
        case .typing(let batchID, _):
            session.liveSegmentState = .typing(batchID: batchID, pendingPause: true)
            return
        case .ready:
            break
        }

        guard let liveRecognizer = recognizer as? any LiveSpeechRecognizing else { return }
        session.liveSegmentState = .finalizing(task: nil, pendingPause: false)
        let rolloverTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let recognized = try await liveRecognizer.rolloverLiveTranscription(
                    onPartialTranscription: { [weak self] transcription in
                        DispatchQueue.main.async {
                            self?.receiveLivePartial(transcription, for: session)
                        }
                    },
                    onPauseDetected: { [weak self] in
                        DispatchQueue.main.async {
                            self?.handleLivePause(for: session)
                        }
                    }
                )
                // An explicit stop can change the session to `.transcribing` while this pause
                // rollover decodes. The stop task waits for this completed segment.
                guard !Task.isCancelled,
                      self.isCurrent(session, in: [.recording, .transcribing])
                else {
                    return
                }
                self.enqueuePausedSegmentFinalText(recognized, for: session)
            } catch is CancellationError {
                self.finishLiveSegmentFinalization(for: session)
            } catch SpeechError.emptyTranscription {
                // A noise-only segment should not interrupt the next recording.
                self.finishLiveSegmentFinalization(for: session)
            } catch {
                // Rollover already started the successor capture, so an error must stop it.
                await liveRecognizer.cancelLiveTranscription()
                guard !Task.isCancelled,
                      self.isCurrent(session, in: [.recording, .transcribing])
                else {
                    return
                }
                self.failCurrentSession(with: error)
            }
        }
        if case .finalizing(_, let pendingPause) = session.liveSegmentState {
            session.liveSegmentState = .finalizing(
                task: rolloverTask,
                pendingPause: pendingPause
            )
        } else {
            rolloverTask.cancel()
        }
    }

    private func finishLiveTranscription(_ recognized: String, for session: DictationSession) {
        guard session.mode != .reviewBeforeTyping else {
            finishReviewTranscription(
                combineReviewSegments(with: recognized, for: session),
                for: session
            )
            return
        }
        let prepared = TranscriptionTextNormalizer.prepare(
            recognized,
            autoCapitalizeFirstSentence: settings.autoCapitalizeFirstSentence,
            appendReturn: settings.pressEnterAfterTranscription
        )
        debugLog.setRecognized(prepared)

        let edit: String
        if session.liveTypedText.isEmpty {
            edit = prepared
        } else {
            edit = LiveTranscriptReconciler.finalEdit(
                from: session.liveTypedText,
                to: prepared
            )
        }
        resetLiveTypingState(for: session)

        guard transitionSession(to: .typing(session)) else { return }
        // Earlier stable live text may still be waiting in the keyboard queue. Appending keeps
        // the final suffix behind it instead of cancelling it and inserting the suffix mid-text.
        session.typingBatchID = typingEngine.enqueue(
            edit,
            configuration: settings.typingConfiguration
        )
    }

    private func enqueuePausedSegmentFinalText(
        _ recognized: String,
        for session: DictationSession
    ) {
        let pendingPause = session.liveSegmentState.pendingPause
        guard session.mode != .reviewBeforeTyping else {
            let segment = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                session.reviewFinalizedSegments.append(segment)
            }
            reviewTranscription = preparedReviewTranscription(session.reviewFinalizedSegments)
            debugLog.setRecognized(reviewTranscription)
            resetLiveTypingState(for: session)
            session.liveSegmentState = .ready
            resumeNextSegmentTyping(for: session, pendingPause: pendingPause)
            return
        }

        let prepared = TranscriptionTextNormalizer.prepare(
            recognized,
            autoCapitalizeFirstSentence: settings.autoCapitalizeFirstSentence,
            appendReturn: false
        )
        debugLog.setRecognized(prepared)

        let edit = session.liveTypedText.isEmpty
            ? prepared
            : LiveTranscriptReconciler.finalEdit(from: session.liveTypedText, to: prepared)
        resetLiveTypingState(for: session)

        if let batchID = typingEngine.enqueue(
            segmentBoundaryEdit(edit),
            configuration: settings.typingConfiguration
        ) {
            session.liveSegmentState = .typing(
                batchID: batchID,
                pendingPause: pendingPause
            )
        } else {
            session.liveSegmentState = .ready
            resumeNextSegmentTyping(for: session, pendingPause: pendingPause)
        }
    }

    private func finishLiveSegmentFinalization(for session: DictationSession) {
        guard case .finalizing(_, let pendingPause) = session.liveSegmentState else { return }
        session.liveSegmentState = .ready
        resumeNextSegmentTyping(for: session, pendingPause: pendingPause)
    }

    private func resumeNextSegmentTyping(
        for session: DictationSession,
        pendingPause: Bool
    ) {
        guard pendingPause, isCurrent(session, in: [.recording]) else { return }
        // The recognizer reported a pause while the prior segment was still being typed.
        // Start its rollover now that the next segment is allowed to make progress.
        handleLivePause(for: session)
    }

    private func appendLiveText(to stableText: String, for session: DictationSession) {
        guard !stableText.isEmpty else { return }

        let edit: String
        if session.liveTypedText.isEmpty {
            edit = stableText
        } else {
            guard let liveEdit = LiveTranscriptReconciler.liveEdit(
                from: session.liveTypedText,
                to: stableText
            ) else {
                return
            }
            edit = liveEdit
        }
        guard !edit.isEmpty else { return }
        session.liveTypedText = stableText
        typingEngine.enqueue(edit, configuration: settings.typingConfiguration)
    }

    /// An automatic pause keeps dictation continuous, so make the boundary explicit even when
    /// Whisper's finalized segment has no trailing whitespace or punctuation.
    private func segmentBoundaryEdit(_ edit: String) -> String {
        guard !edit.isEmpty else { return " " }
        return edit.last?.isWhitespace == true ? edit : edit + " "
    }

    private func resetLiveTypingState(for session: DictationSession) {
        session.liveTypedText = ""
        session.previousLiveHypothesis = ""
    }

    private func finishEmptyLiveTranscription(for session: DictationSession) {
        let fallback = LiveTranscriptReconciler.fallbackFinalTranscript(
            lastHypothesis: session.previousLiveHypothesis,
            liveTypedText: session.liveTypedText
        )
        if session.mode == .reviewBeforeTyping {
            let reviewed = combineReviewSegments(with: fallback ?? "", for: session)
            if reviewed.isEmpty {
                transitionSession(to: .idle)
            } else {
                finishReviewTranscription(reviewed, for: session)
            }
        } else if let fallback {
            finishLiveTranscription(fallback, for: session)
        } else {
            transitionSession(to: .idle)
        }
    }

    private func combineReviewSegments(
        with finalSegment: String,
        for session: DictationSession
    ) -> String {
        let segments = session.reviewFinalizedSegments + [finalSegment]
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

    private func finishReviewTranscription(
        _ recognized: String,
        for session: DictationSession
    ) {
        let prepared = TranscriptionTextNormalizer.prepare(
            recognized,
            autoCapitalizeFirstSentence: settings.autoCapitalizeFirstSentence,
            appendReturn: settings.pressEnterAfterTranscription
        )
        guard !prepared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            transitionSession(to: .idle)
            return
        }
        reviewTranscription = prepared
        debugLog.setRecognized(prepared)
        resetLiveTypingState(for: session)
        transitionSession(to: .reviewing(session))
    }

    func acceptReviewedTranscription() {
        guard case .reviewing(let session) = dictationSession.state else { return }
        let transcription = reviewTranscription
        guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelCurrentOperation()
            return
        }

        let targetApplication = session.targetApplication
        session.reviewFinalizedSegments = []
        guard transitionSession(to: .typing(session)) else { return }
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session,
                  self.isCurrent(session, in: [.typing])
            else {
                return
            }
            self.typeReviewedTranscription(
                transcription,
                into: targetApplication,
                for: session,
                remainingFocusChecks: 12
            )
        }
    }

    /// Activation is asynchronous. Waiting briefly for the captured target to become active
    /// avoids emitting the accepted text while WhisperKeys' panel is still the front process.
    private func typeReviewedTranscription(
        _ transcription: String,
        into targetApplication: NSRunningApplication?,
        for session: DictationSession,
        remainingFocusChecks: Int
    ) {
        guard isCurrent(session, in: [.typing]) else { return }
        guard let targetApplication,
              !targetApplicationActivator.isTerminated(targetApplication)
        else {
            session.typingBatchID = typingEngine.type(
                transcription,
                configuration: settings.typingConfiguration
            )
            return
        }

        guard targetApplicationActivator.isActive(targetApplication) else {
            _ = targetApplicationActivator.activate(targetApplication)
            guard remainingFocusChecks > 0 else {
                failCurrentSession(
                    with: .focusRestorationFailed(
                        applicationName: targetApplication.localizedName
                            ?? "the original app"
                    ),
                    logUnderlyingError: false
                )
                return
            }
            clock.scheduleOnMain(after: 0.025) { [weak self, weak session] in
                guard let self, let session else { return }
                self.typeReviewedTranscription(
                    transcription,
                    into: targetApplication,
                    for: session,
                    remainingFocusChecks: remainingFocusChecks - 1
                )
            }
            return
        }

        session.typingBatchID = typingEngine.type(
            transcription,
            configuration: settings.typingConfiguration
        )
    }

    private func resetReviewState() {
        reviewTranscription = ""
    }

    func updateReviewedTranscription(_ text: String) {
        guard case .reviewing = dictationSession.state else { return }
        reviewTranscription = text
        debugLog.setRecognized(text)
    }

    func performRecoveryAction(_ action: AppRecoveryAction) {
        switch action {
        case .openMicrophoneSettings:
            permissions.openMicrophonePrivacySettings()
        case .openAccessibilitySettings:
            permissions.openAccessibilityPrivacySettings()
        case .chooseAnotherMicrophone:
            AppDelegate.presentSettings()
        case .retryModel:
            installSelectedModel()
        case .retryDictation:
            startDictation()
        }
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

        guard ![.recording, .transcribing, .reviewing].contains(
            dictationSession.state.phase
        ) else {
            return
        }
        startDictation()
    }

    private func handleHoldShortcutEnded() {
        guard holdShortcutIsDown else { return }
        holdShortcutIsDown = false
        switch dictationSession.state {
        case .recording:
            stopAndTranscribe()
        case .starting(let session):
            // Permission and model startup are asynchronous. If the user releases before the
            // microphone begins recording, stop immediately after that startup completes.
            session.stopWhenRecordingStarts = true
        default:
            break
        }
    }

    private func recordingDidStart(_ session: DictationSession) {
        guard isCurrent(session, in: [.starting]) else { return }
        session.startTask = nil
        guard transitionSession(to: .recording(session)) else { return }
        _ = startSound?.play()
        if session.stopWhenRecordingStarts {
            session.stopWhenRecordingStarts = false
            stopAndTranscribe()
        }
    }

    private func isCurrent(
        _ session: DictationSession,
        in phases: Set<DictationSessionPhase>
    ) -> Bool {
        dictationSession.isCurrent(session, in: phases)
    }

    @discardableResult
    private func transitionSession(to newState: DictationSessionState) -> Bool {
        switch dictationSession.transition(to: newState) {
        case .success:
            activity = newState.activity
            return true
        case .failure(let transition):
            debugLog.setError(
                NSError(
                    domain: "WhisperKeys.DictationSession",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid dictation transition: \(transition.from) → \(transition.to)."
                    ]
                )
            )
            return false
        }
    }

    private func failCurrentSession(with error: Error) {
        debugLog.setError(error)
        failCurrentSession(with: .recording(error), logUnderlyingError: false)
    }

    private func failCurrentSession(
        with error: AppError,
        logUnderlyingError: Bool = true
    ) {
        if logUnderlyingError {
            debugLog.setError(error)
        }
        dictationSession.state.session?.cancelTasks()
        typingEngine.cancel()
        guard transitionSession(to: .idle) else { return }
        activity = .error(error)
    }

}
