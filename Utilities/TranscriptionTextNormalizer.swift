import Foundation

enum TranscriptionTextNormalizer {
    static func prepare(
        _ recognized: String,
        autoCapitalizeFirstSentence: Bool,
        appendReturn: Bool
    ) -> String {
        var text = TranscriptRepetitionFilter.clean(TranscriptArtifactFilter.clean(recognized))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if autoCapitalizeFirstSentence, let first = text.first {
            text.replaceSubrange(text.startIndex...text.startIndex, with: first.uppercased())
        }
        if appendReturn { text.append("\n") }
        return text
    }
}

/// Drops non-speech annotations produced by recognizers, plus standalone filler sounds.
/// Delimited annotations are not spoken words, so replacing them with a space preserves the
/// words on either side without allowing a sound label to reach the focused application.
private enum TranscriptArtifactFilter {
    static func clean(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(
            of: #"\s*(?:\*[^*\r\n]+\*|\[[^\]\r\n]+\])\s*"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\b(?:u+h+|u+m+)\b"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"[,;:]([.!?])"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^\s*[,;:]+\s*|\s*[,;:]+\s*$"#,
            with: "",
            options: .regularExpression
        )
        return cleaned
    }
}

/// Removes obvious decoder loops without attempting to rewrite normal spoken language.
///
/// Whisper occasionally repeats the same long tail of a transcription when it reaches a window
/// boundary. Only immediately adjacent runs of at least five words are removed; short and
/// separated repetitions are intentionally preserved because they can be meaningful speech.
private enum TranscriptRepetitionFilter {
    static func clean(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(
            of: ",{2,}",
            with: ",",
            options: .regularExpression
        )

        while let range = duplicatePhraseRange(in: cleaned) {
            cleaned.removeSubrange(range)
        }
        return cleaned
    }

    private static func duplicatePhraseRange(in text: String) -> Range<String.Index>? {
        let tokens = words(in: text)
        let minimumPhraseLength = 5
        guard tokens.count >= minimumPhraseLength * 2 else { return nil }

        for start in tokens.indices {
            let maximumLength = (tokens.count - start) / 2
            guard maximumLength >= minimumPhraseLength else { continue }

            for length in stride(from: maximumLength, through: minimumPhraseLength, by: -1) {
                guard phrasesMatch(tokens, firstStart: start, secondStart: start + length, length: length) else {
                    continue
                }

                var repetitions = 2
                while start + (repetitions + 1) * length <= tokens.count,
                      phrasesMatch(
                        tokens,
                        firstStart: start,
                        secondStart: start + repetitions * length,
                        length: length
                      )
                {
                    repetitions += 1
                }

                let firstDuplicate = tokens[start + length]
                let finalDuplicate = tokens[start + repetitions * length - 1]
                return firstDuplicate.range.lowerBound..<endOfDecoration(
                    after: finalDuplicate.range.upperBound,
                    in: text
                )
            }
        }
        return nil
    }

    private static func phrasesMatch(
        _ tokens: [WordToken],
        firstStart: Int,
        secondStart: Int,
        length: Int
    ) -> Bool {
        for offset in 0..<length where tokens[firstStart + offset].key != tokens[secondStart + offset].key {
            return false
        }
        return true
    }

    private static func endOfDecoration(after index: String.Index, in text: String) -> String.Index {
        var end = index
        while end < text.endIndex, text[end].isWhitespace || text[end].isPunctuation {
            end = text.index(after: end)
        }
        return end
    }

    private static func words(in text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        var wordStart: String.Index?

        for index in text.indices {
            if text[index].isLetter || text[index].isNumber {
                if wordStart == nil { wordStart = index }
            } else if let start = wordStart {
                tokens.append(WordToken(text: String(text[start..<index]), range: start..<index))
                wordStart = nil
            }
        }

        if let wordStart {
            tokens.append(WordToken(text: String(text[wordStart...]), range: wordStart..<text.endIndex))
        }
        return tokens
    }
}

private struct WordToken {
    let text: String
    let range: Range<String.Index>

    var key: String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
