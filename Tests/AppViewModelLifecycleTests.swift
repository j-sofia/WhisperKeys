import AppKit
import Combine
import Foundation
import XCTest

@testable import WhisperKeys

@MainActor
final class AppViewModelLifecycleTests: XCTestCase {
    func testLiveLifecycleHandlesPartialsPauseAndStopDuringRolloverThroughTypingCompletion() async {
        let rolloverGate = LifecycleGate()
        let recognizer = LifecycleLiveRecognizer(
            rolloverText: "alpha beta gamma delta",
            finalText: "epsilon zeta",
            rolloverGate: rolloverGate
        )
        let harness = makeHarness(
            recognizer: recognizer,
            mappableText: "alpha beta gamma delta epsilon zeta"
        )
        var activities: [AppActivity] = []
        let activityObservation = harness.viewModel.$activity.sink { activities.append($0) }
        defer { activityObservation.cancel() }

        harness.viewModel.startDictation()
        await waitUntil("live capture starts") {
            recognizer.startCallCount == 1 && harness.viewModel.activity == .recording
        }

        recognizer.publishPartial("alpha beta gamma delta ")
        await waitUntil("partial result reaches the view model") {
            harness.debugLog.recognizedText == "alpha beta gamma delta"
        }
        recognizer.publishPartial("alpha beta gamma delta ")
        await waitUntil("stable partial text is typed") {
            self.typedText(in: harness.debugLog) == "alpha beta gamma "
        }

        recognizer.detectPause()
        await waitUntil("pause rollover starts") { recognizer.rolloverCallCount == 1 }

        harness.viewModel.stopAndTranscribe()
        XCTAssertEqual(harness.viewModel.activity, .transcribing)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            recognizer.finalizationCallCount,
            0,
            "Stopping during rollover must not finalize the successor capture early."
        )

        await rolloverGate.open()
        await waitUntil("both finalized segments finish typing") {
            self.typedText(in: harness.debugLog)
                == "alpha beta gamma delta epsilon zeta"
        }
        await waitUntil("typing completion returns the lifecycle to idle") {
            harness.viewModel.activity == .idle
        }

        XCTAssertEqual(recognizer.rolloverCallCount, 1)
        XCTAssertEqual(recognizer.finalizationCallCount, 1)
        XCTAssertEqual(recognizer.cancellationCallCount, 0)
        assertOrdered(
            [.idle, .recording, .transcribing, .typing, .idle],
            in: activities
        )
    }

    func testCancellationDuringPauseRolloverEndsTheLifecycleAndIgnoresLateResults() async {
        let rolloverGate = LifecycleGate()
        let recognizer = LifecycleLiveRecognizer(
            rolloverText: "cancelled rollover text",
            finalText: "cancelled final text",
            rolloverGate: rolloverGate
        )
        let harness = makeHarness(
            recognizer: recognizer,
            mappableText: "cancel this pending segment cancelled rollover text final"
        )
        var activities: [AppActivity] = []
        let activityObservation = harness.viewModel.$activity.sink { activities.append($0) }
        defer { activityObservation.cancel() }

        harness.viewModel.startDictation()
        await waitUntil("live capture starts") {
            recognizer.startCallCount == 1 && harness.viewModel.activity == .recording
        }
        recognizer.publishPartial("cancel this pending segment")
        await waitUntil("partial result is visible") {
            harness.debugLog.recognizedText == "cancel this pending segment"
        }

        recognizer.detectPause()
        await waitUntil("pause rollover starts") { recognizer.rolloverCallCount == 1 }

        harness.viewModel.cancelCurrentOperation()
        XCTAssertEqual(harness.viewModel.activity, .idle)
        await waitUntil("recognizer capture is cancelled") {
            recognizer.cancellationCallCount == 1
        }

        await rolloverGate.open()
        recognizer.publishPartial("late partial must be ignored")
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(harness.viewModel.activity, .idle)
        XCTAssertEqual(recognizer.finalizationCallCount, 0)
        XCTAssertEqual(typedText(in: harness.debugLog), "")
        XCTAssertEqual(harness.viewModel.reviewTranscription, "")
        assertOrdered([.idle, .recording, .idle], in: activities)
    }

    func testReviewAcceptanceRestoresFocusAndReturnsToIdleAfterTypingCompletes() async {
        let targetApplication = NSRunningApplication.current
        let focus = LifecycleFocusState()
        let recognizer = LifecycleLiveRecognizer(
            rolloverText: "",
            finalText: "original review transcript",
            rolloverGate: LifecycleGate(isOpen: true)
        )
        let harness = makeHarness(
            recognizer: recognizer,
            mode: .reviewBeforeTyping,
            mappableText: "draft review text original transcript edited accepted",
            targetApplication: targetApplication,
            focus: focus
        )
        var activities: [AppActivity] = []
        let activityObservation = harness.viewModel.$activity.sink { activities.append($0) }
        defer { activityObservation.cancel() }

        harness.viewModel.startDictation()
        await waitUntil("review capture starts") {
            recognizer.startCallCount == 1 && harness.viewModel.activity == .recording
        }
        XCTAssertTrue(harness.viewModel.dictationTarget === targetApplication)

        recognizer.publishPartial("draft review text")
        await waitUntil("partial result updates the review") {
            harness.viewModel.reviewTranscription == "draft review text"
        }
        XCTAssertEqual(typedText(in: harness.debugLog), "")

        harness.viewModel.stopAndTranscribe()
        await waitUntil("final result is ready for review") {
            harness.viewModel.activity == .reviewing
        }
        XCTAssertEqual(harness.viewModel.reviewTranscription, "original review transcript")
        XCTAssertEqual(typedText(in: harness.debugLog), "")

        harness.viewModel.updateReviewedTranscription("edited accepted transcript")
        harness.viewModel.acceptReviewedTranscription()
        XCTAssertEqual(harness.viewModel.activity, .typing)

        await waitUntil("the original application is reactivated") {
            focus.activationRequests == 1
        }
        await waitUntil("accepted text finishes typing") {
            self.typedText(in: harness.debugLog) == "edited accepted transcript"
        }
        await waitUntil("typing completion clears the lifecycle") {
            harness.viewModel.activity == .idle
        }

        XCTAssertNil(harness.viewModel.dictationTarget)
        XCTAssertEqual(focus.activationRequests, 1)
        XCTAssertEqual(recognizer.finalizationCallCount, 1)
        assertOrdered(
            [.idle, .recording, .transcribing, .reviewing, .typing, .idle],
            in: activities
        )
    }

    private func makeHarness(
        recognizer: LifecycleLiveRecognizer,
        mode: TranscriptionMode = .live,
        mappableText: String,
        targetApplication: NSRunningApplication? = nil,
        focus: LifecycleFocusState = LifecycleFocusState(isActive: true)
    ) -> LifecycleHarness {
        let suiteName = "AppViewModelLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.autoCapitalizeFirstSentence = false
        settings.transcriptionModeID = mode.rawValue
        settings.wordsPerMinute = 0
        settings.keyDownMilliseconds = 0
        settings.characterDelayMilliseconds = 0
        settings.wordDelayMilliseconds = 0

        let debugLog = DebugLogStore()
        let typingEngine = TypingEngine(
            mapper: testMapper(for: mappableText),
            emitter: LifecycleKeyEmitter(),
            focusedApplicationTypingConfigurationAdjuster: LifecycleTypingConfigurationAdjuster()
        )
        let viewModel = AppViewModel(
            settings: settings,
            permissions: PermissionManager(),
            recorder: AudioRecorder(),
            recognizer: recognizer,
            typingEngine: typingEngine,
            shortcutMonitor: GlobalShortcutMonitor(),
            debugLog: debugLog,
            modelStore: ModelStore(),
            requestMicrophonePermission: { true },
            accessibilityPermissionState: { .granted },
            frontmostApplication: { targetApplication },
            activateApplication: { _ in
                focus.activationRequests += 1
                focus.isActive = true
                return true
            },
            applicationIsActive: { _ in focus.isActive },
            applicationIsTerminated: { _ in false }
        )
        return LifecycleHarness(viewModel: viewModel, debugLog: debugLog)
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
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(description)")
    }

    private func assertOrdered(
        _ expected: [AppActivity],
        in actual: [AppActivity],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchStart = actual.startIndex
        for activity in expected {
            guard let match = actual[searchStart...].firstIndex(of: activity) else {
                XCTFail(
                    "Missing \(activity) after index \(searchStart) in \(actual)",
                    file: file,
                    line: line
                )
                return
            }
            searchStart = actual.index(after: match)
        }
    }
}

private struct LifecycleHarness {
    let viewModel: AppViewModel
    let debugLog: DebugLogStore
}

private final class LifecycleFocusState {
    var isActive: Bool
    var activationRequests = 0

    init(isActive: Bool = false) {
        self.isActive = isActive
    }
}

private final class LifecycleLiveRecognizer: LiveSpeechRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let rolloverText: String
    private let finalText: String
    private let rolloverGate: LifecycleGate
    private var partialHandler: (@Sendable (String) -> Void)?
    private var pauseHandler: (@Sendable () -> Void)?
    private var starts = 0
    private var rollovers = 0
    private var finalizations = 0
    private var cancellations = 0

    var startCallCount: Int { lock.withLock { starts } }
    var rolloverCallCount: Int { lock.withLock { rollovers } }
    var finalizationCallCount: Int { lock.withLock { finalizations } }
    var cancellationCallCount: Int { lock.withLock { cancellations } }

    init(
        rolloverText: String,
        finalText: String,
        rolloverGate: LifecycleGate
    ) {
        self.rolloverText = rolloverText
        self.finalText = finalText
        self.rolloverGate = rolloverGate
    }

    func publishPartial(_ text: String) {
        let handler = lock.withLock { partialHandler }
        handler?(text)
    }

    func detectPause() {
        let handler = lock.withLock { pauseHandler }
        handler?()
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
        lock.withLock {
            starts += 1
            partialHandler = onPartialTranscription
            pauseHandler = onPauseDetected
        }
    }

    func rolloverLiveTranscription(
        onPartialTranscription: @escaping @Sendable (String) -> Void,
        onPauseDetected: @escaping @Sendable () -> Void
    ) async throws -> String {
        lock.withLock {
            rollovers += 1
            partialHandler = onPartialTranscription
            pauseHandler = onPauseDetected
        }
        await rolloverGate.wait()
        try Task.checkCancellation()
        return rolloverText
    }

    func stopAndFinalizeLiveTranscription() async throws -> String {
        lock.withLock { finalizations += 1 }
        return finalText
    }

    func cancelLiveTranscription() async {
        lock.withLock { cancellations += 1 }
    }
}

private actor LifecycleGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

private final class LifecycleKeyEmitter: KeyEventEmitting {
    func emitKeyDown(_ stroke: KeyStroke) throws {}
    func emitKeyUp(_ stroke: KeyStroke) throws {}
    func emitImmediateKeyStroke(_ stroke: KeyStroke) throws {}
}

private final class LifecycleTypingConfigurationAdjuster:
    FocusedApplicationTypingConfigurationAdjusting
{
    func configuration(
        forFocusedApplication configuration: TypingConfiguration
    ) -> TypingConfiguration {
        configuration
    }
}
