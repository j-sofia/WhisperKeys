import CoreGraphics
import Foundation
import XCTest

@testable import WhisperKeys

@MainActor
final class AppViewModelLiveStopTests: XCTestCase {
    func testManualStopDuringPauseRolloverFinishesBothSegments() async {
        let liveStarted = expectation(description: "live capture started")
        let rolloverStarted = expectation(description: "pause rollover started")
        let successorFinalized = expectation(description: "successor capture finalized")
        let finalizedBeforeRollover = expectation(description: "successor is not finalized early")
        finalizedBeforeRollover.isInverted = true

        let gate = AppViewModelAsyncGate()
        let recognizer = PausingLiveRecognizer(
            rolloverStarted: { rolloverStarted.fulfill() },
            liveStarted: { liveStarted.fulfill() },
            successorFinalized: { successorFinalized.fulfill() },
            finalizedBeforeRollover: { finalizedBeforeRollover.fulfill() },
            gate: gate
        )
        let debugLog = DebugLogStore()
        let typingEngine = TypingEngine(emitter: CapturingKeyEmitter())
        let defaultsSuiteName = "AppViewModelLiveStopTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.autoCapitalizeFirstSentence = false
        settings.wordsPerMinute = 0
        settings.keyDownMilliseconds = 0
        settings.characterDelayMilliseconds = 0
        settings.wordDelayMilliseconds = 0

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
            accessibilityPermissionState: { .granted }
        )

        viewModel.startDictation()
        await fulfillment(of: [liveStarted], timeout: 1)
        await waitUntil("dictation is recording") { viewModel.activity == .recording }

        recognizer.detectPause()
        await fulfillment(of: [rolloverStarted], timeout: 1)

        // This stop request arrives while the first, pause-ended segment is still being
        // finalized. It must wait instead of cancelling and losing that segment.
        viewModel.stopAndTranscribe()
        await fulfillment(of: [finalizedBeforeRollover], timeout: 0.1)

        await gate.open()
        await fulfillment(of: [successorFinalized], timeout: 1)
        await waitUntil("both segments are typed") {
            self.typedText(in: debugLog) == "prior segment successor segment"
        }

        XCTAssertEqual(typedText(in: debugLog), "prior segment successor segment")
    }

    func testPauseRolloverFailureCancelsTheSuccessorCapture() async {
        let liveStarted = expectation(description: "live capture started")
        let unexpectedPriorCaptureCancellation = expectation(description: "no prior capture is cancelled")
        unexpectedPriorCaptureCancellation.isInverted = true
        let successorCaptureCancelled = expectation(description: "successor capture cancelled")
        let recognizer = RolloverFailingLiveRecognizer(
            liveStarted: { liveStarted.fulfill() },
            priorCaptureCancelled: { unexpectedPriorCaptureCancellation.fulfill() },
            successorCaptureCancelled: { successorCaptureCancelled.fulfill() }
        )
        let debugLog = DebugLogStore()
        let defaultsSuiteName = "AppViewModelLiveStopTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.autoCapitalizeFirstSentence = false

        let viewModel = AppViewModel(
            settings: settings,
            permissions: PermissionManager(),
            recorder: AudioRecorder(),
            recognizer: recognizer,
            typingEngine: TypingEngine(emitter: CapturingKeyEmitter()),
            shortcutMonitor: GlobalShortcutMonitor(),
            debugLog: debugLog,
            modelStore: ModelStore(),
            requestMicrophonePermission: { true },
            accessibilityPermissionState: { .granted }
        )

        viewModel.startDictation()
        await fulfillment(of: [liveStarted], timeout: 1)
        await waitUntil("dictation is recording") { viewModel.activity == .recording }
        await fulfillment(of: [unexpectedPriorCaptureCancellation], timeout: 0.05)

        recognizer.detectPause()
        await fulfillment(of: [successorCaptureCancelled], timeout: 1)
        await waitUntil("rollover error") {
            if case .error = viewModel.activity { return true }
            return false
        }

        XCTAssertEqual(debugLog.lastError, SpeechError.modelMissing(.tiny).localizedDescription)
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

private final class RolloverFailingLiveRecognizer: LiveSpeechRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let liveStarted: () -> Void
    private let priorCaptureCancelled: () -> Void
    private let successorCaptureCancelled: () -> Void
    private var onPauseDetected: (@Sendable () -> Void)?
    private var shouldReportCancellation = false

    init(
        liveStarted: @escaping () -> Void,
        priorCaptureCancelled: @escaping () -> Void,
        successorCaptureCancelled: @escaping () -> Void
    ) {
        self.liveStarted = liveStarted
        self.priorCaptureCancelled = priorCaptureCancelled
        self.successorCaptureCancelled = successorCaptureCancelled
    }

    func detectPause() {
        lock.withLock {
            shouldReportCancellation = true
            onPauseDetected?()
        }
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
        lock.withLock { self.onPauseDetected = onPauseDetected }
        liveStarted()
    }

    func rolloverLiveTranscription(
        onPartialTranscription: @escaping @Sendable (String) -> Void,
        onPauseDetected: @escaping @Sendable () -> Void
    ) async throws -> String {
        throw SpeechError.modelMissing(.tiny)
    }

    func stopAndFinalizeLiveTranscription() async throws -> String { "" }

    func cancelLiveTranscription() async {
        let report = lock.withLock { () -> Bool in
            guard shouldReportCancellation else { return false }
            shouldReportCancellation = false
            return true
        }
        if report {
            successorCaptureCancelled()
        } else {
            priorCaptureCancelled()
        }
    }
}

private final class PausingLiveRecognizer: LiveSpeechRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let rolloverStarted: () -> Void
    private let liveStarted: () -> Void
    private let successorFinalized: () -> Void
    private let finalizedBeforeRollover: () -> Void
    private let gate: AppViewModelAsyncGate
    private var onPauseDetected: (@Sendable () -> Void)?
    private var rolloverCompleted = false

    init(
        rolloverStarted: @escaping () -> Void,
        liveStarted: @escaping () -> Void,
        successorFinalized: @escaping () -> Void,
        finalizedBeforeRollover: @escaping () -> Void,
        gate: AppViewModelAsyncGate
    ) {
        self.rolloverStarted = rolloverStarted
        self.liveStarted = liveStarted
        self.successorFinalized = successorFinalized
        self.finalizedBeforeRollover = finalizedBeforeRollover
        self.gate = gate
    }

    func detectPause() {
        lock.withLock { onPauseDetected?() }
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
        lock.withLock { self.onPauseDetected = onPauseDetected }
        liveStarted()
    }

    func rolloverLiveTranscription(
        onPartialTranscription: @escaping @Sendable (String) -> Void,
        onPauseDetected: @escaping @Sendable () -> Void
    ) async throws -> String {
        rolloverStarted()
        await gate.wait()
        lock.withLock {
            rolloverCompleted = true
            self.onPauseDetected = onPauseDetected
        }
        return "prior segment"
    }

    func stopAndFinalizeLiveTranscription() async throws -> String {
        let completed = lock.withLock { rolloverCompleted }
        if !completed { finalizedBeforeRollover() }
        successorFinalized()
        return "successor segment"
    }

    func cancelLiveTranscription() async {}
}

private actor AppViewModelAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

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

private final class CapturingKeyEmitter: KeyEventEmitting {
    func emitKeyDown(_ stroke: KeyStroke) throws {}
    func emitKeyUp(_ stroke: KeyStroke) throws {}
    func emitImmediateKeyStroke(_ stroke: KeyStroke) throws {}
}
