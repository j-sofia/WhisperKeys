import Foundation
import XCTest

@testable import WhisperKeys

final class LiveTranscriptionStopSequencerTests: XCTestCase {
    func testManualStopWaitsForPauseRolloverBeforeFinalizingSuccessorCapture() async throws {
        let rolloverStarted = expectation(description: "pause rollover started")
        let finalizationStarted = expectation(description: "successor finalization started")
        finalizationStarted.isInverted = true

        let gate = AsyncGate()
        let recognizer = ControlledLiveRecognizer(
            finalText: "successor segment",
            onFinalization: { finalizationStarted.fulfill() }
        )
        let rolloverTask = Task<Void, Never> {
            rolloverStarted.fulfill()
            await gate.wait()
            recognizer.markRolloverComplete()
        }

        let stopTask = Task {
            try await LiveTranscriptionStopSequencer.finalize(
                after: rolloverTask,
                using: recognizer
            )
        }

        await fulfillment(of: [rolloverStarted], timeout: 1)
        await fulfillment(of: [finalizationStarted], timeout: 0.1)
        XCTAssertFalse(recognizer.didFinalize)

        await gate.open()
        let result = try await stopTask.value

        XCTAssertEqual(result, "successor segment")
        XCTAssertTrue(recognizer.didFinalize)
        XCTAssertTrue(recognizer.didWaitForRollover)
    }
}

private final class ControlledLiveRecognizer: LiveSpeechRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let finalText: String
    private let onFinalization: () -> Void
    private var rolloverComplete = false
    private var finalized = false
    private var waitedForRollover = false

    var didFinalize: Bool { lock.withLock { finalized } }
    var didWaitForRollover: Bool { lock.withLock { waitedForRollover } }

    init(finalText: String, onFinalization: @escaping () -> Void) {
        self.finalText = finalText
        self.onFinalization = onFinalization
    }

    func markRolloverComplete() {
        lock.withLock { rolloverComplete = true }
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
    ) async throws {}

    func rolloverLiveTranscription(
        onPartialTranscription: @escaping @Sendable (String) -> Void,
        onPauseDetected: @escaping @Sendable () -> Void
    ) async throws -> String { "" }

    func stopAndFinalizeLiveTranscription() async throws -> String {
        lock.withLock {
            finalized = true
            waitedForRollover = rolloverComplete
        }
        onFinalization()
        return finalText
    }

    func cancelLiveTranscription() async {}
}

private actor AsyncGate {
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
