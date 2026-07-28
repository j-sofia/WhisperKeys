import XCTest

@testable import WhisperKeys

@MainActor
final class DictationSessionStateMachineTests: XCTestCase {
    func testLiveSessionAllowsOnlyTheExpectedLifecycle() {
        var machine = DictationSessionStateMachine()
        let session = DictationSession(mode: .live, targetApplication: nil)

        assertTransitionSucceeds(machine.transition(to: .starting(session)))
        assertTransitionSucceeds(machine.transition(to: .recording(session)))
        assertTransitionSucceeds(machine.transition(to: .transcribing(session)))
        assertTransitionSucceeds(machine.transition(to: .typing(session)))
        assertTransitionSucceeds(machine.transition(to: .idle))

        XCTAssertEqual(machine.state.phase, .idle)
    }

    func testReviewSessionAllowsReviewBeforeTyping() {
        var machine = DictationSessionStateMachine()
        let session = DictationSession(mode: .reviewBeforeTyping, targetApplication: nil)

        assertTransitionSucceeds(machine.transition(to: .starting(session)))
        assertTransitionSucceeds(machine.transition(to: .recording(session)))
        assertTransitionSucceeds(machine.transition(to: .transcribing(session)))
        assertTransitionSucceeds(machine.transition(to: .reviewing(session)))
        assertTransitionSucceeds(machine.transition(to: .typing(session)))

        XCTAssertEqual(machine.state.phase, .typing)
    }

    func testInvalidPhaseTransitionIsRejectedWithoutChangingState() {
        var machine = DictationSessionStateMachine()
        let session = DictationSession(mode: .live, targetApplication: nil)

        let result = machine.transition(to: .recording(session))

        XCTAssertEqual(
            transitionError(from: result),
            InvalidDictationSessionTransition(from: .idle, to: .recording)
        )
        XCTAssertEqual(machine.state.phase, .idle)
    }

    func testTransitionCannotSwapSessionIdentityMidLifecycle() {
        var machine = DictationSessionStateMachine()
        let firstSession = DictationSession(mode: .live, targetApplication: nil)
        let secondSession = DictationSession(mode: .live, targetApplication: nil)
        assertTransitionSucceeds(machine.transition(to: .starting(firstSession)))

        let result = machine.transition(to: .recording(secondSession))

        XCTAssertEqual(
            transitionError(from: result),
            InvalidDictationSessionTransition(from: .starting, to: .recording)
        )
        XCTAssertTrue(machine.state.session === firstSession)
        XCTAssertEqual(machine.state.phase, .starting)
    }

    private func assertTransitionSucceeds(
        _ result: Result<Void, InvalidDictationSessionTransition>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("Unexpected transition failure: \(error)", file: file, line: line)
        }
    }

    private func transitionError(
        from result: Result<Void, InvalidDictationSessionTransition>
    ) -> InvalidDictationSessionTransition? {
        guard case .failure(let error) = result else { return nil }
        return error
    }
}
