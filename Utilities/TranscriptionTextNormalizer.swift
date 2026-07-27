import Foundation

enum TranscriptionTextNormalizer {
    static func prepare(
        _ recognized: String,
        autoCapitalizeFirstSentence: Bool,
        appendReturn: Bool
    ) -> String {
        var text = TranscriptRepetitionFilter.clean(recognized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if autoCapitalizeFirstSentence, let first = text.first {
            text.replaceSubrange(text.startIndex...text.startIndex, with: first.uppercased())
        }
        if appendReturn { text.append("\n") }
        return text
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
