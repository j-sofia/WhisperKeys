import Foundation

/// Determines the smallest safe edit to append after live dictation text has already been sent
/// to the focused app. Live text is never rewritten because the final Whisper pass may revise an
/// earlier word after it has been typed.
enum LiveTranscriptReconciler {
    /// Returns an append-only edit for an in-progress hypothesis. If the typed portion cannot be
    /// matched exactly, wait for another hypothesis rather than risking duplicate live text.
    static func liveEdit(from current: String, to target: String) -> String? {
        let currentWords = words(in: current)
        let targetWords = words(in: target)
        guard !currentWords.isEmpty,
              targetWords.count >= currentWords.count,
              zip(currentWords, targetWords).allSatisfy({ $0.key == $1.key })
        else {
            return nil
        }

        if targetWords.count > currentWords.count {
            let newWords = Array(targetWords.dropFirst(currentWords.count))
            // A decoder loop can turn a valid live hypothesis into “... connect across teams
            // and learn from one another connect across teams and learn from one another.”
            // Do not queue that repetition in an external app. Allow a small leading fragment
            // because looped output often includes a stray final letter from the prior phrase.
            guard !repeatsRecentPhrase(newWords, after: currentWords) else { return nil }
            return tail(after: targetWords[currentWords.count - 1], in: target, current: current)
        }

        guard let finalWord = targetWords.last else { return "" }
        let trailingPunctuation = String(target[finalWord.range.upperBound...])
        guard !trailingPunctuation.isEmpty, !current.hasSuffix(trailingPunctuation) else { return "" }
        return (current.last?.isWhitespace == true ? "\u{7F}" : "") + trailingPunctuation
    }

    private static func repeatsRecentPhrase(_ newWords: [WordToken], after currentWords: [WordToken]) -> Bool {
        let minimumPhraseLength = 5
        guard currentWords.count >= minimumPhraseLength, newWords.count >= minimumPhraseLength else {
            return false
        }

        // The `s` in “another.s connect …” is a common partial-token artifact, so look just
        // past the first couple of new words as well as at the start of the proposed append.
        let maximumOffset = min(2, newWords.count - minimumPhraseLength)
        for offset in 0...maximumOffset {
            let maximumLength = min(currentWords.count, newWords.count - offset)
            for length in stride(from: maximumLength, through: minimumPhraseLength, by: -1) {
                let currentStart = currentWords.count - length
                guard zip(
                    currentWords[currentStart...],
                    newWords[offset..<(offset + length)]
                ).allSatisfy({ $0.key == $1.key })
                else {
                    continue
                }
                return true
            }
        }
        return false
    }

    /// Returns an append-only edit for the final transcript.
    ///
    /// The live preview may be word-for-word behind the final pass, in which case only its
    /// suffix is needed. If either transcript has changed before the end of the live preview,
    /// appending from a partial prefix or later suffix can silently omit words from the final
    /// transcript. We cannot safely rewrite text in the focused app, so append the complete
    /// final result in that case. A duplicate is visible and recoverable; missing dictation is
    /// neither.
    static func finalEdit(from current: String, to target: String) -> String {
        if current.isEmpty { return target }
        if let exactEdit = liveEdit(from: current, to: target) { return exactEdit }

        let targetWords = words(in: target)
        guard !targetWords.isEmpty else { return "" }
        return append(target, to: current)
    }

    private static func tail(after word: WordToken, in target: String, current: String) -> String {
        var tail = String(target[word.range.upperBound...])
        guard !tail.isEmpty else { return "" }

        // Tokens exclude punctuation, so a live update such as "share, " and a final update
        // such as "share, and solve" both leave the target tail beginning with a comma. Do not
        // retype punctuation already sent to the focused app; that was the source of `share,,`
        // in final output.
        let currentWithoutTrailingWhitespace = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingPunctuation = String(tail.prefix { $0.isPunctuation })
        if !leadingPunctuation.isEmpty,
           currentWithoutTrailingWhitespace.hasSuffix(leadingPunctuation) {
            tail.removeFirst(leadingPunctuation.count)
        }

        if current.last?.isWhitespace == true {
            if tail.first?.isWhitespace == true {
                tail.removeFirst()
            } else if tail.first?.isPunctuation == true {
                // Live updates end after whitespace so a final comma or period belongs directly
                // after the previous word, not after the already-typed trailing space.
                return "\u{7F}" + tail
            }
        }
        return tail
    }

    private static func append(_ target: String, to current: String) -> String {
        guard !target.isEmpty else { return "" }
        return (current.last?.isWhitespace == true ? "" : " ") + target
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
