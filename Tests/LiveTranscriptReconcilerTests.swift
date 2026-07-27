import XCTest

@testable import WhisperKeys

final class LiveTranscriptReconcilerTests: XCTestCase {
    // MARK: - Final transcript reconciliation

    func testFinalEditAppendsOnlyTheNewSuffixWhenLiveTextIsAnExactWordPrefix() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "The software engineering community is a place for Wegman engineers to learn, share, ",
            to: "The software engineering community is a place for Wegman engineers to learn, share, and solve problems together."
        )

        XCTAssertEqual(edit, "and solve problems together.")
        XCTAssertEqual(
            applying(edit, to: "The software engineering community is a place for Wegman engineers to learn, share, "),
            "The software engineering community is a place for Wegman engineers to learn, share, and solve problems together."
        )
    }

    func testFinalEditAppendsEntireFinalWhenFinalPassAddsWordsBeforeLiveText() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "software engineering community is a place for Wegman engineers ",
            to: "The software engineering community is a place for Wegman engineers to learn and share."
        )

        XCTAssertEqual(
            edit,
            "The software engineering community is a place for Wegman engineers to learn and share."
        )
        XCTAssertEqual(
            applying(edit, to: "software engineering community is a place for Wegman engineers "),
            "software engineering community is a place for Wegman engineers The software engineering community is a place for Wegman engineers to learn and share."
        )
    }

    func testFinalEditAppendsEntireFinalWhenAnEarlyWordWasRevised() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "please send the draft ",
            to: "please send that draft after the pause."
        )

        XCTAssertEqual(edit, "please send that draft after the pause.")
        XCTAssertEqual(
            applying(edit, to: "please send the draft "),
            "please send the draft please send that draft after the pause."
        )
    }

    func testFinalEditDoesNotUseARepeatedSuffixToSkipOpeningWords() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "software engineering community ",
            to: "The software engineering community helps the software engineering community learn together."
        )

        XCTAssertEqual(
            edit,
            "The software engineering community helps the software engineering community learn together."
        )
    }

    func testFinalEditAppendsEntireFinalWhenOnlyOneOpeningWordMatches() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "the software engineering community ",
            to: "the product engineering community shares practices."
        )

        XCTAssertEqual(edit, "the product engineering community shares practices.")
    }

    func testFinalEditInsertsASpaceBeforeAnUnrelatedFinalTranscript() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "already typed",
            to: "a separate final transcript"
        )

        XCTAssertEqual(edit, " a separate final transcript")
    }

    func testFinalEditRemovesTheLiveTrailingSpaceBeforeFinalPunctuation() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "the engineering community ",
            to: "the engineering community."
        )

        XCTAssertEqual(edit, "\u{7F}.")
        XCTAssertEqual(applying(edit, to: "the engineering community "), "the engineering community.")
    }

    func testFinalEditDoesNotAppendPunctuationThatWasAlreadyTyped() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "the engineering community.",
            to: "the engineering community."
        )

        XCTAssertEqual(edit, "")
    }

    func testFinalEditMatchesCaseAndDiacriticChangesWithoutRepeatingWords() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "CAFÉ ",
            to: "cafe au lait"
        )

        XCTAssertEqual(edit, "au lait")
        XCTAssertEqual(applying(edit, to: "CAFÉ "), "CAFÉ au lait")
    }

    func testFinalEditReturnsNoEditForAnEmptyFinalTranscript() {
        XCTAssertEqual(
            LiveTranscriptReconciler.finalEdit(from: "live words already typed ", to: "   \n\t "),
            ""
        )
    }

    func testFinalEditReturnsTheFinalTranscriptWhenNoLiveTextWasTyped() {
        XCTAssertEqual(
            LiveTranscriptReconciler.finalEdit(from: "", to: "complete final transcript"),
            "complete final transcript"
        )
    }

    // MARK: - Live hypothesis reconciliation

    func testLiveEditPreservesPunctuationBeforeAnAppendedWord() {
        let edit = LiveTranscriptReconciler.liveEdit(
            from: "hello ",
            to: "hello, world"
        )

        XCTAssertEqual(edit, "\u{7F}, world")
    }

    func testLiveEditDoesNotRepeatPunctuationAlreadyQueuedForTyping() {
        let edit = LiveTranscriptReconciler.liveEdit(
            from: "share, ",
            to: "share, and solve problems"
        )

        XCTAssertEqual(edit, "and solve problems")
        XCTAssertEqual(applying(edit ?? "", to: "share, "), "share, and solve problems")
    }

    func testLiveEditAppendsOnlyNewCompletedWords() {
        let edit = LiveTranscriptReconciler.liveEdit(
            from: "the software engineering ",
            to: "the software engineering community "
        )

        XCTAssertEqual(edit, "community ")
        XCTAssertEqual(
            applying(edit ?? "", to: "the software engineering "),
            "the software engineering community "
        )
    }

    func testLiveEditRefusesToReplaceWordsAlreadyQueuedForTyping() {
        XCTAssertNil(
            LiveTranscriptReconciler.liveEdit(
                from: "the software engineering community ",
                to: "the product engineering community "
            )
        )
    }

    func testLiveEditDoesNotTreatAShorterHypothesisAsAnAppend() {
        XCTAssertNil(
            LiveTranscriptReconciler.liveEdit(
                from: "the software engineering community ",
                to: "the software engineering "
            )
        )
    }

    func testLiveEditRejectsALongPhraseRepeatedAtTheEndOfAHypothesis() {
        let current = "the community exists to help developers connect across teams and learn from one another "

        XCTAssertNil(
            LiveTranscriptReconciler.liveEdit(
                from: current,
                to: current + "connect across teams and learn from one another "
            )
        )
    }

    func testLiveEditRejectsALongRepeatedPhraseWithAStrayLeadingWord() {
        let current = "the community exists to help developers connect across teams and learn from one another "

        XCTAssertNil(
            LiveTranscriptReconciler.liveEdit(
                from: current,
                to: current + "s connect across teams and learn from one another "
            )
        )
    }

    private func applying(_ edit: String, to current: String) -> String {
        edit.reduce(into: current) { text, character in
            if character == "\u{7F}" || character == "\u{08}" {
                text.removeLast()
            } else {
                text.append(character)
            }
        }
    }
}
