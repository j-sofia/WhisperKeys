import CoreGraphics
import XCTest

@testable import WhisperKeys

final class TypingEngineTests: XCTestCase {
    func testEnqueuedFinalTextWaitsForAnInProgressLiveChunk() throws {
        let emitter = RecordingEmitter()
        let firstStroke = expectation(description: "live chunk starts typing")
        let completed = expectation(description: "combined batch completes")
        let liveText = "the transcription is still being typed "
        let finalText = "and this final phrase follows it."
        let mapper = testMapper(for: liveText + finalText)
        let engine = TypingEngine(mapper: mapper, emitter: emitter)

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

        let expected = try mapper.map(liveText + finalText).map(StrokeSnapshot.init)
        XCTAssertEqual(emitter.strokes, expected)
    }

    func testTypingHonorsKeyDownAndCharacterInterval() {
        let emitter = RecordingEmitter()
        let completed = expectation(description: "typing completes")
        let engine = TypingEngine(mapper: testMapper(for: "ab"), emitter: emitter)
        engine.onCompleted = { _ in completed.fulfill() }

        engine.type(
            "ab",
            configuration: TypingConfiguration(
                wordsPerMinute: 100,
                keyDownMilliseconds: 30,
                extraCharacterDelayMilliseconds: 0,
                extraWordDelayMilliseconds: 0
            )
        )
        wait(for: [completed], timeout: 2)

        let events = emitter.events
        XCTAssertEqual(events.map(\.kind), [.keyDown, .keyUp, .keyDown, .keyUp])
        XCTAssertGreaterThanOrEqual(events[1].timestamp.timeIntervalSince(events[0].timestamp), 0.015)
        XCTAssertGreaterThanOrEqual(events[2].timestamp.timeIntervalSince(events[1].timestamp), 0.055)
    }

    func testWhitespaceReceivesExtraWordDelayBeforeNextCharacter() {
        let emitter = RecordingEmitter()
        let completed = expectation(description: "typing completes")
        let engine = TypingEngine(mapper: testMapper(for: " a"), emitter: emitter)
        engine.onCompleted = { _ in completed.fulfill() }

        engine.type(
            " a",
            configuration: TypingConfiguration(
                wordsPerMinute: 0,
                keyDownMilliseconds: 0,
                extraCharacterDelayMilliseconds: 10,
                extraWordDelayMilliseconds: 35
            )
        )
        wait(for: [completed], timeout: 2)

        let events = emitter.events
        XCTAssertEqual(events.map(\.kind), [.keyDown, .keyUp, .keyDown, .keyUp])
        XCTAssertGreaterThanOrEqual(events[2].timestamp.timeIntervalSince(events[1].timestamp), 0.03)
    }

    func testCancellationReleasesPressedKeyAndPreventsRemainingStrokes() {
        let emitter = RecordingEmitter()
        let firstKeyDown = expectation(description: "first key is pressed")
        let keyReleased = expectation(description: "pressed key is released")
        let noCompletion = expectation(description: "cancelled batch does not complete")
        noCompletion.isInverted = true
        let engine = TypingEngine(mapper: testMapper(for: "abc"), emitter: emitter)

        emitter.onKeyDown = { firstKeyDown.fulfill() }
        emitter.onKeyUp = { keyReleased.fulfill() }
        engine.onCompleted = { _ in noCompletion.fulfill() }

        engine.type(
            "abc",
            configuration: TypingConfiguration(
                wordsPerMinute: 100,
                keyDownMilliseconds: 250,
                extraCharacterDelayMilliseconds: 0,
                extraWordDelayMilliseconds: 0
            )
        )
        wait(for: [firstKeyDown], timeout: 1)
        engine.cancel()
        wait(for: [keyReleased], timeout: 1)
        wait(for: [noCompletion], timeout: 0.1)

        XCTAssertEqual(emitter.events.map(\.kind), [.keyDown, .keyUp])
    }

    func testTypingMappedUnicodeUsesTheResolvedStrokes() {
        let emitter = RecordingEmitter()
        let completed = expectation(description: "typing completes")
        let mapper = testMapper(entries: [
            (12, 0, "é"),
            (14, testShiftModifier | testOptionModifier, "Å")
        ])
        let engine = TypingEngine(mapper: mapper, emitter: emitter)
        engine.onCompleted = { _ in completed.fulfill() }

        engine.type(
            "éÅ",
            configuration: TypingConfiguration(
                wordsPerMinute: 0,
                keyDownMilliseconds: 0,
                extraCharacterDelayMilliseconds: 0,
                extraWordDelayMilliseconds: 0
            )
        )
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(emitter.strokes, [
            StrokeSnapshot(keyCode: 12, modifiers: []),
            StrokeSnapshot(keyCode: 14, modifiers: [.maskShift, .maskAlternate])
        ])
    }
}

private final class RecordingEmitter: KeyEventEmitting {
    enum EventKind: Equatable {
        case keyDown
        case keyUp
        case immediate
    }

    struct Event {
        let kind: EventKind
        let stroke: StrokeSnapshot
        let timestamp: Date
    }

    private let lock = NSLock()
    private var hasRecordedFirstStroke = false
    var onFirstStroke: (() -> Void)?
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    private var recordedEvents: [Event] = []

    var strokes: [StrokeSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents.compactMap { event in
            switch event.kind {
            case .keyDown, .immediate: event.stroke
            case .keyUp: nil
            }
        }
    }

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func emitKeyDown(_ stroke: KeyStroke) throws {
        record(stroke, kind: .keyDown)
    }

    func emitKeyUp(_ stroke: KeyStroke) throws {
        record(stroke, kind: .keyUp)
    }

    func emitImmediateKeyStroke(_ stroke: KeyStroke) throws {
        record(stroke, kind: .immediate)
    }

    private func record(_ stroke: KeyStroke, kind: EventKind) {
        let notifyFirstStroke: (() -> Void)?
        let notifyKeyDown: (() -> Void)?
        let notifyKeyUp: (() -> Void)?
        lock.lock()
        recordedEvents.append(Event(kind: kind, stroke: StrokeSnapshot(stroke), timestamp: Date()))
        notifyFirstStroke = hasRecordedFirstStroke ? nil : onFirstStroke
        hasRecordedFirstStroke = true
        notifyKeyDown = kind == .keyDown ? onKeyDown : nil
        notifyKeyUp = kind == .keyUp ? onKeyUp : nil
        lock.unlock()
        notifyFirstStroke?()
        notifyKeyDown?()
        notifyKeyUp?()
    }
}
