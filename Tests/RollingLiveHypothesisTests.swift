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

    func testUnmatchedHandoffKeepsPreviousHypothesisUntilAStableHandoffIsAvailable() {
        var hypothesis = RollingLiveHypothesis()

        _ = hypothesis.update("one two three four", windowAdvanced: false)

        XCTAssertEqual(
            hypothesis.update("five six seven eight", windowAdvanced: true),
            "one two three four"
        )
    }
}
