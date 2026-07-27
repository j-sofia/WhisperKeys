import XCTest

@testable import WhisperKeys

final class TranscriptionTextNormalizerTests: XCTestCase {
    func testPrepareCollapsesRepeatedCommasFromLiveAndFinalBoundaries() {
        let text = TranscriptionTextNormalizer.prepare(
            "the community helps people learn,, share,,, and solve problems",
            autoCapitalizeFirstSentence: false,
            appendReturn: false
        )

        XCTAssertEqual(text, "the community helps people learn, share, and solve problems")
    }

    func testPrepareRemovesAnImmediatelyRepeatedLongTailPhrase() {
        let text = TranscriptionTextNormalizer.prepare(
            "the community exists to help developers connect across teams and learn from one another. connect across teams and learn from one another. connect across teams and learn from one another.",
            autoCapitalizeFirstSentence: false,
            appendReturn: false
        )

        XCTAssertEqual(
            text,
            "the community exists to help developers connect across teams and learn from one another."
        )
    }

    func testPrepareKeepsIntentionalShortWordRepetition() {
        let text = TranscriptionTextNormalizer.prepare(
            "this is very very important",
            autoCapitalizeFirstSentence: false,
            appendReturn: false
        )

        XCTAssertEqual(text, "this is very very important")
    }

    func testPrepareKeepsRepeatedPhraseWhenOtherWordsSeparateIt() {
        let text = TranscriptionTextNormalizer.prepare(
            "connect across teams and learn from one another, then document the decision. connect across teams and learn from one another.",
            autoCapitalizeFirstSentence: false,
            appendReturn: false
        )

        XCTAssertEqual(
            text,
            "connect across teams and learn from one another, then document the decision. connect across teams and learn from one another."
        )
    }

    func testPrepareSuppressesBlankAudioPlaceholderWithoutTypingReturn() {
        let text = TranscriptionTextNormalizer.prepare(
            "[BLANK_AUDIO]",
            autoCapitalizeFirstSentence: true,
            appendReturn: true
        )

        XCTAssertEqual(text, "")
    }

    func testPrepareRemovesEmbeddedBlankAudioPlaceholder() {
        let text = TranscriptionTextNormalizer.prepare(
            "hello [blank_audio] world",
            autoCapitalizeFirstSentence: false,
            appendReturn: false
        )

        XCTAssertEqual(text, "hello world")
    }

    func testPrepareAppliesCapitalizationAndReturnAfterCleanup() {
        let text = TranscriptionTextNormalizer.prepare(
            "the team shares,, knowledge",
            autoCapitalizeFirstSentence: true,
            appendReturn: true
        )

        XCTAssertEqual(text, "The team shares, knowledge\n")
    }
}
