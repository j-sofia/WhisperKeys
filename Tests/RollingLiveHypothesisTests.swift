import XCTest

@testable import WhisperKeys

final class RollingLiveHypothesisTests: XCTestCase {
    func testWindowHandoffPreservesAContinuousHypothesis() {
        var hypothesis = RollingLiveHypothesis()

        XCTAssertEqual(
            hypothesis.update("one two three four five six", windowAdvanced: false),
            "one two three four five six"
        )
        XCTAssertEqual(
            hypothesis.update("four five six seven eight", windowAdvanced: true),
            "one two three four five six seven eight"
        )
    }

    func testWindowHandoffMatchesWordsDespiteCaseAndPunctuation() {
        var hypothesis = RollingLiveHypothesis()

        _ = hypothesis.update("One, two. Three four", windowAdvanced: false)

        XCTAssertEqual(
            hypothesis.update("three, four five", windowAdvanced: true),
            "One, two. three, four five"
        )
    }

    func testUnmatchedHandoffCommitsThePreviousPreviewSoLiveTypingCanKeepMoving() {
        var hypothesis = RollingLiveHypothesis()

        _ = hypothesis.update("one two three four", windowAdvanced: false)

        XCTAssertEqual(
            hypothesis.update("five six seven eight", windowAdvanced: true),
            "one two three four five six seven eight"
        )
    }

    func testMultipleWindowHandoffsKeepTheEntireSentence() {
        var hypothesis = RollingLiveHypothesis()

        _ = hypothesis.update("the software engineering community is a place", windowAdvanced: false)
        _ = hypothesis.update("community is a place for engineers to learn", windowAdvanced: true)

        XCTAssertEqual(
            hypothesis.update("engineers to learn share and solve problems", windowAdvanced: true),
            "the software engineering community is a place for engineers to learn share and solve problems"
        )
    }

    func testSingleWordOverlapAvoidsDuplicatingTheBoundaryWordDuringFallback() {
        var hypothesis = RollingLiveHypothesis()

        _ = hypothesis.update("one two three common", windowAdvanced: false)

        XCTAssertEqual(
            hypothesis.update("common words begin a different sentence", windowAdvanced: true),
            "one two three common words begin a different sentence"
        )
    }

    func testLongTranscriptionContinuesAfterAnUnmatchedWindowHandoff() {
        var hypothesis = RollingLiveHypothesis()

        let opening = "Testing out Whisper Keys again this is a test of a really long input"
        let delayedPreview = "I basically have to keep typing until the hypothesis text stops predicting"
        let nextPreview = "typing until the hypothesis text stops predicting or guessing at what I said and typing in real time"

        _ = hypothesis.update(opening, windowAdvanced: false)
        _ = hypothesis.update(delayedPreview, windowAdvanced: true)

        XCTAssertEqual(
            hypothesis.update(nextPreview, windowAdvanced: true),
            "Testing out Whisper Keys again this is a test of a really long input "
                + "I basically have to keep typing until the hypothesis text stops predicting "
                + "or guessing at what I said and typing in real time"
        )
    }

    func testUpdatesWithinTheSameWindowReplaceOnlyUnconfirmedWords() {
        var hypothesis = RollingLiveHypothesis()

        _ = hypothesis.update("the software engineering commu", windowAdvanced: false)

        XCTAssertEqual(
            hypothesis.update("the software engineering community", windowAdvanced: false),
            "the software engineering community"
        )
    }

    func testResetForgetsTextFromThePreviousRecording() {
        var hypothesis = RollingLiveHypothesis()

        _ = hypothesis.update("first recording words", windowAdvanced: false)
        hypothesis.reset()

        XCTAssertEqual(
            hypothesis.update("second recording words", windowAdvanced: false),
            "second recording words"
        )
    }
}
