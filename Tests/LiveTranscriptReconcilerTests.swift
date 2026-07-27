import XCTest

@testable import WhisperKeys

final class LiveTranscriptReconcilerTests: XCTestCase {
    func testFinalEditAppendsAfterAnEarlyWordRevision() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "please send the draft ",
            to: "please send that draft after the pause."
        )

        XCTAssertEqual(edit, "that draft after the pause.")
    }

    func testFinalEditUsesLiveSuffixWhenFinalResultAddsAnOpeningWord() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "good morning everyone ",
            to: "hello good morning everyone and welcome back."
        )

        XCTAssertEqual(edit, "and welcome back.")
    }

    func testFinalEditFallsBackToFullFinalResultWhenThereIsNoReliableAnchor() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "the wrong opening ",
            to: "a completely different continuation after the pause"
        )

        XCTAssertEqual(edit, "a completely different continuation after the pause")
    }

    func testLiveEditPreservesPunctuationBeforeAnAppendedWord() {
        let edit = LiveTranscriptReconciler.liveEdit(
            from: "hello ",
            to: "hello, world"
        )

        XCTAssertEqual(edit, "\u{7F}, world")
    }
}
