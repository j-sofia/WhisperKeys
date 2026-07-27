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

    func testFinalEditAppendsOnlyTheRemainderOfALongTranscriptAfterALiveWindowFallback() {
        let liveText = "Testing out Whisper Keys again this is a test of a really long input "
            + "I basically have to keep "
        let finalText = "Testing out Whisper Keys again this is a test of a really long input "
            + "I basically have to keep typing until the hypothesis text stops predicting "
            + "or guessing at what I said and typing in real time."

        let edit = LiveTranscriptReconciler.finalEdit(from: liveText, to: finalText)

        XCTAssertEqual(
            edit,
            "typing until the hypothesis text stops predicting or guessing at what I said and typing in real time."
        )
        XCTAssertEqual(applying(edit, to: liveText), finalText)
    }

    func testFinalEditPreservesLiveTextWhenFinalPassAddsWordsBeforeIt() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "software engineering community is a place for Wegman engineers ",
            to: "The software engineering community is a place for Wegman engineers to learn and share."
        )

        XCTAssertEqual(edit, "to learn and share.")
        XCTAssertEqual(
            applying(edit, to: "software engineering community is a place for Wegman engineers "),
            "software engineering community is a place for Wegman engineers to learn and share."
        )
    }

    func testFinalEditDoesNotReplayTheTranscriptWhenAnEarlyWordWasRevised() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "please send the draft ",
            to: "please send that draft after the pause."
        )

        XCTAssertEqual(edit, "after the pause.")
        XCTAssertEqual(
            applying(edit, to: "please send the draft "),
            "please send the draft after the pause."
        )
    }

    func testFinalEditUsesTheEarliestAlignmentWhenTheFinalTranscriptRepeatsAPhrase() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "software engineering community ",
            to: "The software engineering community helps the software engineering community learn together."
        )

        XCTAssertEqual(edit, "helps the software engineering community learn together.")
    }

    func testFinalEditDoesNotReplayALongLiveTranscriptWhenThereIsNoSubstantialAlignment() {
        let edit = LiveTranscriptReconciler.finalEdit(
            from: "the completely unrelated words ",
            to: "the product engineering community shares practices."
        )

        XCTAssertEqual(edit, "")
    }

    func testFinalEditDoesNotReplayALongTranscriptAfterAnEarlyLiveRevision() {
        let liveText = "Testing out Whisper Keys again. This is a test of if I have a really long input "
            + "and then at the end I end the thing, is it going to re-input all of the text? "
            + "I basically just have to keep typing until the hypothesis text stops predicting or guessing "
            + "at what I said and typing in real time. So let's see if I can get it to stop typing."
        let finalText = "Testing out Whisper Keys again. This is a test of whether I have a really long input "
            + "and then at the end I end the thing. Is it going to re-input all of the text? "
            + "I basically just have to keep typing until the hypothesis text stops predicting or guessing "
            + "at what I said and typing in real time. So let's see if I can get it to stop typing. "
            + "I basically just have to keep on talking forever."

        let edit = LiveTranscriptReconciler.finalEdit(from: liveText, to: finalText)

        XCTAssertEqual(edit, " I basically just have to keep on talking forever.")
        XCTAssertFalse(edit.localizedCaseInsensitiveContains("Testing out Whisper Keys"))
        XCTAssertEqual(
            applying(edit, to: liveText),
            liveText + " I basically just have to keep on talking forever."
        )
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

    func testFinalEditBackspacesAShortLiveOnlySilenceHallucination() {
        let liveText = "Testing a long transcription and then pausing thank you "
        let finalText = "Testing a long transcription and then pausing."

        let edit = LiveTranscriptReconciler.finalEdit(from: liveText, to: finalText)

        XCTAssertTrue(edit.contains("\u{7F}"))
        XCTAssertEqual(applying(edit, to: liveText), finalText)
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

    func testLiveEditContinuesAfterAnEarlyHypothesisRevisionInALongTranscription() {
        let liveText = "Testing out Whisper Keys again this is a test of if I have a really long input "
            + "and then I keep talking until the hypothesis stops predicting "
        let revisedHypothesis = "Testing out Whisper Keys again this is a test of whether I have a really long input "
            + "and then I keep talking until the hypothesis stops predicting or guessing at what I said "

        let edit = LiveTranscriptReconciler.liveEdit(from: liveText, to: revisedHypothesis)

        XCTAssertEqual(
            applying(edit ?? "", to: liveText),
            revisedHypothesis
        )
    }

    func testLiveUpdatesKeepAdvancingWhenAnEarlyHypothesisWordChanges() {
        let liveText = "Testing out Whisper Keys again this is a test of if I have a really long input "
            + "and then I keep talking until the hypothesis stops predicting "
        let previousHypothesis = "Testing out Whisper Keys again this is a test of whether I have a really long input "
            + "and then I keep talking until the hypothesis stops predicting or guessing at what I said "
        let revisedHypothesis = previousHypothesis + "and I keep talking "

        let unconfirmedText = LiveTranscriptReconciler.textForLiveUpdate(
            previousHypothesis: liveText,
            currentHypothesis: previousHypothesis,
            hasTypedText: true
        )
        let textToReconcile = LiveTranscriptReconciler.textForLiveUpdate(
            previousHypothesis: previousHypothesis,
            currentHypothesis: revisedHypothesis,
            hasTypedText: true
        )

        XCTAssertNil(LiveTranscriptReconciler.liveEdit(from: liveText, to: unconfirmedText))
        XCTAssertEqual(textToReconcile, previousHypothesis)
        XCTAssertEqual(
            applying(LiveTranscriptReconciler.liveEdit(from: liveText, to: textToReconcile) ?? "", to: liveText),
            previousHypothesis
        )
    }

    func testLiveUpdatesRequireTwoHypothesesAndIgnoreAShortInitialSilenceHallucination() {
        XCTAssertEqual(
            LiveTranscriptReconciler.textForLiveUpdate(
                previousHypothesis: "thank you",
                currentHypothesis: "thank you",
                hasTypedText: false
            ),
            ""
        )

        XCTAssertEqual(
            LiveTranscriptReconciler.textForLiveUpdate(
                previousHypothesis: "three stable words ",
                currentHypothesis: "three stable words ",
                hasTypedText: false
            ),
            "three stable words "
        )
    }

    func testFallbackFinalTranscriptUsesSubstantialLiveHypothesisWhenFinalPassIsEmpty() {
        XCTAssertEqual(
            LiveTranscriptReconciler.fallbackFinalTranscript(
                lastHypothesis: "this is a short but complete ending",
                liveTypedText: "this is a short "
            ),
            "this is a short but complete ending"
        )
    }

    func testFallbackFinalTranscriptDropsTrailingThankYouHallucination() {
        XCTAssertEqual(
            LiveTranscriptReconciler.fallbackFinalTranscript(
                lastHypothesis: "this is the actual dictated sentence thank you",
                liveTypedText: "this is the actual dictated sentence "
            ),
            "this is the actual dictated sentence"
        )
    }

    func testLiveEditBackspacesAndReplacesConfirmedWords() {
        let edit = LiveTranscriptReconciler.liveEdit(
            from: "the software engineering community ",
            to: "the product engineering community "
        )

        XCTAssertTrue(edit?.contains("\u{7F}") == true)
        XCTAssertEqual(
            applying(edit ?? "", to: "the software engineering community "),
            "the product engineering community "
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

    func testLiveEditHoldsAStandaloneThankYouUntilTheFinalPass() {
        XCTAssertNil(
            LiveTranscriptReconciler.liveEdit(
                from: "testing a long transcription and then pausing ",
                to: "testing a long transcription and then pausing thank you "
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
