import CoreGraphics
import XCTest

@testable import WhisperKeys

final class TypingEngineTests: XCTestCase {
    func testEnqueuedFinalTextWaitsForAnInProgressLiveChunk() throws {
        let emitter = RecordingEmitter()
        let engine = TypingEngine(emitter: emitter)
        let firstStroke = expectation(description: "live chunk starts typing")
        let completed = expectation(description: "combined batch completes")
        let liveText = "the transcription is still being typed "
        let finalText = "and this final phrase follows it."

        emitter.onFirstStroke = { firstStroke.fulfill() }
        engine.onCompleted = { _ in completed.fulfill() }

        let liveBatch = engine.type(
            liveText,
            configuration: TypingConfiguration(
                wordsPerMinute: 200,
                keyDownMilliseconds: 0,
                extraCharacterDelayMilliseconds: 0,
                extraWordDelayMilliseconds: 0
            )
        )
        wait(for: [firstStroke], timeout: 1)

        let finalBatch = engine.enqueue(
            finalText,
            configuration: TypingConfiguration(
                wordsPerMinute: 0,
                keyDownMilliseconds: 0,
                extraCharacterDelayMilliseconds: 0,
                extraWordDelayMilliseconds: 0
            )
        )

        XCTAssertEqual(liveBatch, finalBatch)
        wait(for: [completed], timeout: 5)

        let expected = try KeyboardMapper().map(liveText + finalText).map(StrokeSnapshot.init)
        XCTAssertEqual(emitter.strokes, expected)
    }
}

private final class RecordingEmitter: KeyEventEmitting {
    private let lock = NSLock()
    private var recordedStrokes: [StrokeSnapshot] = []
    private var hasRecordedFirstStroke = false
    var onFirstStroke: (() -> Void)?

    var strokes: [StrokeSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStrokes
    }

    func emitKeyDown(_ stroke: KeyStroke) throws {
        record(stroke)
    }

    func emitKeyUp(_ stroke: KeyStroke) throws {}

    func emitImmediateKeyStroke(_ stroke: KeyStroke) throws {
        record(stroke)
    }

    private func record(_ stroke: KeyStroke) {
        let notifyFirstStroke: (() -> Void)?
        lock.lock()
        recordedStrokes.append(StrokeSnapshot(stroke))
        notifyFirstStroke = hasRecordedFirstStroke ? nil : onFirstStroke
        hasRecordedFirstStroke = true
        lock.unlock()
        notifyFirstStroke?()
    }
}

private struct StrokeSnapshot: Equatable {
    let keyCode: CGKeyCode
    let modifiers: UInt64

    init(_ stroke: KeyStroke) {
        keyCode = stroke.keyCode
        modifiers = stroke.modifiers.rawValue
    }
}
