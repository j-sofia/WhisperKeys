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
    private let startSound = NSSound(named: NSSound.Name("Tink"))
    private let stopSound = NSSound(named: NSSound.Name("Pop"))
    private var transcriptionTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var hasStartedInitialModelInstallation = false
    private var liveTypedText = ""
    private var previousLiveHypothesis = ""
    private var typingBatchID: UUID?

    init() {
        self.settings = AppSettings()
        self.permissions = PermissionManager()
        self.recorder = AudioRecorder()
        self.recognizer = WhisperKitSpeechRecognizer()
        self.typingEngine = TypingEngine()
        self.shortcutMonitor = GlobalShortcutMonitor()
        self.debugLog = DebugLogStore()
        self.modelStore = ModelStore()

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
        modelStore: ModelStore
    ) {
        self.settings = settings
        self.permissions = permissions
        self.recorder = recorder
        self.recognizer = recognizer
        self.typingEngine = typingEngine
        self.shortcutMonitor = shortcutMonitor
        self.debugLog = debugLog
        self.modelStore = modelStore

        configureCallbacks()
    }

    private func configureCallbacks() {
        typingEngine.onCompleted = { [weak self] batchID in
            guard let self,
                  self.activity == .typing,
                  self.typingBatchID == batchID
            else { return }
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
        guard settings.shortcutKey != .disabled else { return }
        do {
            try shortcutMonitor.start(shortcutKey: settings.shortcutKey)
        } catch {
            // The menu remains usable if the optional global shortcut has no permission.
            debugLog.setError(error)
        }
    }

    func startDictation() {
        cancelCurrentTypingAndRecognition()
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            guard await self.permissions.requestMicrophone(), !Task.isCancelled else {
                if !Task.isCancelled { self.activity = .error("Microphone permission is required.") }
                return
            }
            guard self.permissions.accessibility == .granted else {
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
                                guard let self, self.activity == .recording else { return }
                                self.handleLiveHypothesis(transcription)
                            }
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
        startTask?.cancel()
        startTask = nil

        if let liveRecognizer = recognizer as? any LiveSpeechRecognizing {
            guard activity == .recording else {
                if activity == .typing { cancelCurrentTypingAndRecognition() }
                return
            }

            stopSound?.play()
            activity = .transcribing
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let recognized = try await liveRecognizer.stopAndFinalizeLiveTranscription()
                    guard !Task.isCancelled else { return }
                    self.finishLiveTranscription(recognized)
                } catch is CancellationError {
                    if self.activity == .transcribing { self.activity = .idle }
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
        typingEngine.cancel()
        typingBatchID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if let liveRecognizer = recognizer as? any LiveSpeechRecognizing {
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

    /// Live typing emits only completed text shared by two consecutive hypotheses. The
    /// reconciler rejects revisions and decoder loops so text already placed in another app is
    /// never rewritten or repeated.
    private func handleLiveHypothesis(_ recognized: String) {
        let hypothesis = TranscriptionTextNormalizer.prepare(
            recognized,
            autoCapitalizeFirstSentence: settings.autoCapitalizeFirstSentence,
            appendReturn: false
        )
        debugLog.setRecognized(hypothesis)

        let stableText = completeWords(in: commonPrefix(previousLiveHypothesis, hypothesis))
        previousLiveHypothesis = hypothesis
        appendLiveText(to: stableText)
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

    private func appendLiveText(to stableText: String) {
        guard !stableText.isEmpty else { return }

        let edit: String
        if liveTypedText.isEmpty {
            edit = stableText
        } else {
            // Do not fall back to a character-level replacement during recording. A rough
            // hypothesis is allowed to be incomplete, never to delete or alter text already
            // placed in another app.
            guard let appendOnlyEdit = LiveTranscriptReconciler.liveEdit(from: liveTypedText, to: stableText) else {
                return
            }
            edit = appendOnlyEdit
        }
        guard !edit.isEmpty else { return }
        liveTypedText = stableText
        typingEngine.enqueue(edit, configuration: settings.typingConfiguration)
    }

    private func resetLiveTypingState() {
        liveTypedText = ""
        previousLiveHypothesis = ""
    }

    /// Drops a possibly incomplete final word from a common partial-transcription prefix.
    private func completeWords(in text: String) -> String {
        guard let finalWhitespace = text.lastIndex(where: \.isWhitespace) else { return "" }
        return String(text[...finalWhitespace])
    }

    private func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        String(zip(lhs, rhs).prefix { $0 == $1 }.map(\.0))
    }

    private func handleShortcut() {
        activity == .recording ? stopAndTranscribe() : startDictation()
    }

}
