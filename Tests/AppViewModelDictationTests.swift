import CoreGraphics
import Foundation
import XCTest

@testable import WhisperKeys

@MainActor
final class AppViewModelDictationTests: XCTestCase {
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

    private func makeHarness(recognizer: FinalizingLiveRecognizer) -> DictationHarness {
        let suiteName = "AppViewModelDictationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.autoCapitalizeFirstSentence = false
        settings.wordsPerMinute = 0
        settings.keyDownMilliseconds = 0
        settings.characterDelayMilliseconds = 0
        settings.wordDelayMilliseconds = 0

        let debugLog = DebugLogStore()
        let viewModel = AppViewModel(
            settings: settings,
            permissions: PermissionManager(),
            recorder: AudioRecorder(),
            recognizer: recognizer,
            typingEngine: TypingEngine(emitter: DictationCapturingEmitter()),
            shortcutMonitor: GlobalShortcutMonitor(),
            debugLog: debugLog,
            modelStore: ModelStore(),
            requestMicrophonePermission: { true },
            accessibilityPermissionState: { .granted }
        )
        return DictationHarness(viewModel: viewModel, debugLog: debugLog)
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

private final class DictationCapturingEmitter: KeyEventEmitting {
    func emitKeyDown(_ stroke: KeyStroke) throws {}
    func emitKeyUp(_ stroke: KeyStroke) throws {}
    func emitImmediateKeyStroke(_ stroke: KeyStroke) throws {}
}
