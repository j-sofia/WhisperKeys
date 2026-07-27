import CoreGraphics
import Foundation
import XCTest

@testable import WhisperKeys

@MainActor
final class AppViewModelDictationTests: XCTestCase {
    func testDictationAndShortcutAreIgnoredWhileModelInstalls() async {
        let installStarted = expectation(description: "model installation started")
        let microphonePermissionRequested = expectation(description: "dictation does not request microphone access")
        microphonePermissionRequested.isInverted = true
        let recognizer = BlockingInstallerRecognizer(onInstallStarted: { installStarted.fulfill() })
        let suiteName = "AppViewModelDictationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let shortcutMonitor = GlobalShortcutMonitor()
        let viewModel = AppViewModel(
            settings: AppSettings(defaults: defaults),
            permissions: PermissionManager(),
            recorder: AudioRecorder(),
            recognizer: recognizer,
            typingEngine: TypingEngine(emitter: DictationCapturingEmitter()),
            shortcutMonitor: shortcutMonitor,
            debugLog: DebugLogStore(),
            modelStore: ModelStore(),
            requestMicrophonePermission: {
                microphonePermissionRequested.fulfill()
                return true
            },
            accessibilityPermissionState: { .granted },
            frontmostApplication: { nil }
        )

        viewModel.installSelectedModel()
        await fulfillment(of: [installStarted], timeout: 1)
        XCTAssertEqual(viewModel.activity, .installingModel)

        viewModel.startDictation()
        shortcutMonitor.onAction?()
        await fulfillment(of: [microphonePermissionRequested], timeout: 0.1)
        XCTAssertEqual(viewModel.activity, .installingModel)

        recognizer.finishInstallation()
        await waitUntil("model installation finishes") { viewModel.activity == .idle }
    }

    func testManualStopTypesConfirmedLiveTextAndFinalSuffix() async {
        let started = expectation(description: "live capture started")
        let recognizer = FinalizingLiveRecognizer(
            result: .success("one two three four five six"),
            onStarted: { started.fulfill() }
        )
        let harness = makeHarness(recognizer: recognizer)

        harness.viewModel.startDictation()
        await fulfillment(of: [started], timeout: 1)
        await waitUntil("recording") { harness.viewModel.activity == .recording }

        // Two matching hypotheses must reach the entire app pipeline and type before stop.
        recognizer.publishPartial("one two three four ")
        recognizer.publishPartial("one two three four ")
        await waitUntil("confirmed live text") {
            self.typedText(in: harness.debugLog) == "one two three "
        }

        harness.viewModel.stopAndTranscribe()
        await waitUntil("final suffix") {
            self.typedText(in: harness.debugLog) == "one two three four five six"
        }
        await waitUntil("idle after typing") { harness.viewModel.activity == .idle }

        XCTAssertEqual(harness.debugLog.lastError, nil)
        XCTAssertEqual(typedText(in: harness.debugLog), "one two three four five six")
    }

    func testManualStopUsesLiveHypothesisWhenFinalPassIsEmpty() async {
        let started = expectation(description: "live capture started")
        let recognizer = FinalizingLiveRecognizer(
            result: .failure(SpeechError.emptyTranscription),
            onStarted: { started.fulfill() }
        )
        let harness = makeHarness(recognizer: recognizer)

        harness.viewModel.startDictation()
        await fulfillment(of: [started], timeout: 1)
        await waitUntil("recording") { harness.viewModel.activity == .recording }

        // This intentionally has only one hypothesis. It has not been typed live, so the test
        // proves that an empty final decode does not discard it when dictation stops.
        recognizer.publishPartial("this is a substantial live ending ")
        await waitUntil("live hypothesis received") {
            harness.debugLog.recognizedText == "this is a substantial live ending"
        }
        harness.viewModel.stopAndTranscribe()

        await waitUntil("fallback final text") {
            self.typedText(in: harness.debugLog) == "this is a substantial live ending"
        }
        await waitUntil("idle after fallback") { harness.viewModel.activity == .idle }

        XCTAssertEqual(harness.debugLog.lastError, nil)
        XCTAssertEqual(typedText(in: harness.debugLog), "this is a substantial live ending")
    }

    func testHoldShortcutStartsDictationAndReleaseStopsIt() async {
        let started = expectation(description: "live capture started")
        let recognizer = FinalizingLiveRecognizer(
            result: .success("hold shortcut transcription"),
            onStarted: { started.fulfill() }
        )
        let harness = makeHarness(recognizer: recognizer)

        harness.shortcutMonitor.onHoldStarted?()
        await fulfillment(of: [started], timeout: 1)
        await waitUntil("recording") { harness.viewModel.activity == .recording }

        harness.shortcutMonitor.onHoldEnded?()
        await waitUntil("hold transcription is typed") {
            self.typedText(in: harness.debugLog) == "hold shortcut transcription"
        }
        await waitUntil("idle after hold release") { harness.viewModel.activity == .idle }
    }

    func testReviewBeforeTypingWaitsForAcceptance() async {
        let started = expectation(description: "live capture started")
        let recognizer = FinalizingLiveRecognizer(
            result: .success("one two three four"),
            onStarted: { started.fulfill() }
        )
        let harness = makeHarness(recognizer: recognizer, transcriptionMode: .reviewBeforeTyping)

        harness.viewModel.startDictation()
        await fulfillment(of: [started], timeout: 1)
        await waitUntil("recording") { harness.viewModel.activity == .recording }

        recognizer.publishPartial("one two three")
        await waitUntil("review transcription") {
            harness.viewModel.reviewTranscription == "one two three"
        }
        XCTAssertEqual(typedText(in: harness.debugLog), "")

        harness.viewModel.stopAndTranscribe()
        await waitUntil("review is ready") { harness.viewModel.activity == .reviewing }
        XCTAssertEqual(harness.viewModel.reviewTranscription, "one two three four")
        XCTAssertEqual(typedText(in: harness.debugLog), "")

        harness.viewModel.updateReviewedTranscription("edited transcript")
        harness.viewModel.acceptReviewedTranscription()
        await waitUntil("accepted transcription is typed") {
            self.typedText(in: harness.debugLog) == "edited transcript"
        }
        await waitUntil("idle after acceptance") { harness.viewModel.activity == .idle }
    }

    private func makeHarness(
        recognizer: FinalizingLiveRecognizer,
        transcriptionMode: TranscriptionMode = .live
    ) -> DictationHarness {
        let suiteName = "AppViewModelDictationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.autoCapitalizeFirstSentence = false
        settings.transcriptionModeID = transcriptionMode.rawValue
        settings.wordsPerMinute = 0
        settings.keyDownMilliseconds = 0
        settings.characterDelayMilliseconds = 0
        settings.wordDelayMilliseconds = 0

        let debugLog = DebugLogStore()
        let shortcutMonitor = GlobalShortcutMonitor()
        let viewModel = AppViewModel(
            settings: settings,
            permissions: PermissionManager(),
            recorder: AudioRecorder(),
            recognizer: recognizer,
            typingEngine: TypingEngine(emitter: DictationCapturingEmitter()),
            shortcutMonitor: shortcutMonitor,
            debugLog: debugLog,
            modelStore: ModelStore(),
            requestMicrophonePermission: { true },
            accessibilityPermissionState: { .granted },
            frontmostApplication: { nil }
        )
        return DictationHarness(
            viewModel: viewModel,
            debugLog: debugLog,
            shortcutMonitor: shortcutMonitor
        )
    }

    private func typedText(in debugLog: DebugLogStore) -> String {
        debugLog.typedEvents.reduce(into: "") { text, entry in
            switch entry.character {
            case "␠": text.append(" ")
            case "↵": text.append("\n")
            case "⇥": text.append("\t")
            default: text.append(entry.character)
            }
        }
    }

    private func waitUntil(
        _ description: String,
        condition: @escaping () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(description)")
    }
}

private struct DictationHarness {
    let viewModel: AppViewModel
    let debugLog: DebugLogStore
    let shortcutMonitor: GlobalShortcutMonitor
}

private final class FinalizingLiveRecognizer: LiveSpeechRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<String, Error>
    private let onStarted: () -> Void
    private var onPartialTranscription: (@Sendable (String) -> Void)?

    init(result: Result<String, Error>, onStarted: @escaping () -> Void) {
        self.result = result
        self.onStarted = onStarted
    }

    func publishPartial(_ text: String) {
        lock.withLock { onPartialTranscription?(text) }
    }

    func transcribe(audioURL: URL, model: WhisperModel) async throws -> String { "" }

    func install(
        model: WhisperModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {}

    func startLiveTranscription(
        model: WhisperModel,
        onPartialTranscription: @escaping @Sendable (String) -> Void,
        onPauseDetected: @escaping @Sendable () -> Void
    ) async throws {
        lock.withLock { self.onPartialTranscription = onPartialTranscription }
        onStarted()
    }

    func rolloverLiveTranscription(
        onPartialTranscription: @escaping @Sendable (String) -> Void,
        onPauseDetected: @escaping @Sendable () -> Void
    ) async throws -> String {
        throw SpeechError.noRecording
    }

    func stopAndFinalizeLiveTranscription() async throws -> String {
        try result.get()
    }

    func cancelLiveTranscription() async {}
}

private final class BlockingInstallerRecognizer: SpeechRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let onInstallStarted: () -> Void
    private var continuation: CheckedContinuation<Void, Never>?

    init(onInstallStarted: @escaping () -> Void) {
        self.onInstallStarted = onInstallStarted
    }

    func transcribe(audioURL: URL, model: WhisperModel) async throws -> String { "" }

    func install(
        model: WhisperModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        onInstallStarted()
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func finishInstallation() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

private final class DictationCapturingEmitter: KeyEventEmitting {
    func emitKeyDown(_ stroke: KeyStroke) throws {}
    func emitKeyUp(_ stroke: KeyStroke) throws {}
    func emitImmediateKeyStroke(_ stroke: KeyStroke) throws {}
}
