import Foundation

/// Determines safe edits after live dictation text has already been sent to the focused app.
enum LiveTranscriptReconciler {
    private static let minimumAlignmentWords = 3

    /// Require two matching hypotheses for every live update. Ignore very short initial phrases,
    /// which are especially likely to be Whisper's silence hallucinations (for example,
    /// “thank you”). Once text has been typed, confirmed hypotheses may correct it.
    static func textForLiveUpdate(
        previousHypothesis: String,
        currentHypothesis: String,
        hasTypedText: Bool
    ) -> String {
        let stableText = completeWords(in: commonPrefix(previousHypothesis, currentHypothesis))
        guard hasTypedText || words(in: stableText).count >= minimumAlignmentWords else { return "" }
        return stableText
    }

    /// A final decode can occasionally be empty for a very short recording even though Whisper
    /// already produced a substantial live hypothesis. Preserve that spoken ending rather than
    /// showing an error and dropping it. A standalone live “thank you” remains excluded.
    static func fallbackFinalTranscript(
        lastHypothesis: String,
        liveTypedText: String
    ) -> String? {
        let candidate = lastHypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateWords = words(in: candidate)
        guard candidateWords.count >= minimumAlignmentWords else {
            return liveTypedText.isEmpty ? nil : liveTypedText
        }

        guard candidateWords.count >= 2,
              isSilenceHallucination(Array(candidateWords.suffix(2)))
        else {
            return candidate
        }

        let hallucinationStart = candidateWords[candidateWords.count - 2].range.lowerBound
        let prefix = String(candidate[..<hallucinationStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? (liveTypedText.isEmpty ? nil : liveTypedText) : prefix
    }

    /// Returns an edit for a confirmed live hypothesis. It may backspace and replace the changed
    /// suffix, but only when most of the already-typed words still align with the confirmation.
    static func liveEdit(from current: String, to target: String) -> String? {
        let currentWords = words(in: current)
        let targetWords = words(in: target)
        guard !currentWords.isEmpty,
              targetWords.count >= currentWords.count
        else {
            return nil
        }

        let isExactPrefix = zip(currentWords, targetWords).allSatisfy { $0.key == $1.key }
        if isExactPrefix {
            if targetWords.count > currentWords.count {
                let newWords = Array(targetWords.dropFirst(currentWords.count))
                guard !isSilenceHallucination(newWords) else { return nil }
                // A decoder loop can turn a valid live hypothesis into “... connect across teams
                // and learn from one another connect across teams and learn from one another.”
                // Do not queue that repetition in an external app. Allow a small leading fragment
                // because looped output often includes a stray final letter from the prior phrase.
                guard !repeatsRecentPhrase(newWords, after: currentWords) else { return nil }
            }
            return exactAppendOnlyEdit(from: current, to: target)
        }

        guard let alignment = appendAlignment(from: currentWords, to: targetWords),
              alignment.count >= requiredLiveAlignment(
                  currentWordCount: currentWords.count,
                  targetWordCount: targetWords.count
              )
        else {
            return nil
        }

        let sharedPrefix = commonPrefix(current, target)
        let deletionCount = current.dropFirst(sharedPrefix.count).count
        let replacement = String(target.dropFirst(sharedPrefix.count))
        let edit = String(repeating: "\u{7F}", count: deletionCount) + replacement
        return edit.isEmpty ? nil : edit
    }

    /// Whisper's most frequent quiet-tail output is a standalone “thank you.” Hold that tiny
    /// phrase for the full segment pass instead of sending it to the active application live.
    /// If it was genuinely dictated, the final transcription still types it normally.
    private static func isSilenceHallucination(_ words: [WordToken]) -> Bool {
        let normalized = words.map(\.key)
        return normalized == ["thank", "you"]
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
    /// suffix is needed. If the final pass revises an earlier word, preserve the live text that
    /// has already reached the focused app and append after its best word-order alignment. This
    /// intentionally retains the live version of a revised word: typing the full final result
    /// again is much more disruptive than leaving that small revision in place.
    static func finalEdit(from current: String, to target: String) -> String {
        if current.isEmpty { return target }
        if let exactEdit = exactAppendOnlyEdit(from: current, to: target) { return exactEdit }

        let currentWords = words(in: current)
        let targetWords = words(in: target)
        guard !targetWords.isEmpty else { return "" }
        guard !currentWords.isEmpty else { return append(target, to: current) }

        if let correction = shortLiveOnlyTailCorrection(
            from: current,
            currentWords: currentWords,
            to: target,
            targetWords: targetWords
        ) {
            return correction
        }

        if let alignment = appendAlignment(from: currentWords, to: targetWords) {
            return tail(after: targetWords[alignment.targetEndIndex], in: target, current: current)
        }

        // Live text is already in another application and cannot be safely replaced. After a
        // meaningful live preview, an unaligned final result is more likely a decoder revision
        // than a separate dictation, so never retype it from the beginning. Very short previews
        // are not enough to establish that the user has received useful text, so append the
        // final transcript for them.
        return currentWords.count < minimumAlignmentWords ? append(target, to: current) : ""
    }

    /// A finalized, silence-trimmed pass is allowed to remove a very short tail that appeared
    /// only in a live preview. This catches common pause hallucinations such as “thank you”
    /// without risking a rewrite of a substantial dictated ending.
    private static func shortLiveOnlyTailCorrection(
        from current: String,
        currentWords: [WordToken],
        to target: String,
        targetWords: [WordToken]
    ) -> String? {
        let maximumCorrectableTailWords = 3
        guard targetWords.count >= minimumAlignmentWords,
              targetWords.count < currentWords.count,
              currentWords.count - targetWords.count <= maximumCorrectableTailWords,
              zip(targetWords, currentWords).allSatisfy({ $0.key == $1.key }),
              let finalTargetWord = targetWords.last
        else {
            return nil
        }

        // Retain the text as it was actually typed through the final matching word, then replace
        // only its short unconfirmed tail with the final pass's punctuation (if any).
        let retainedEnd = currentWords[targetWords.count - 1].range.upperBound
        let deletionCount = current.distance(from: retainedEnd, to: current.endIndex)
        let finalDecoration = String(target[finalTargetWord.range.upperBound...])
        return String(repeating: "\u{7F}", count: deletionCount) + finalDecoration
    }

    private static func exactAppendOnlyEdit(from current: String, to target: String) -> String? {
        let currentWords = words(in: current)
        let targetWords = words(in: target)
        guard !currentWords.isEmpty,
              targetWords.count >= currentWords.count,
              zip(currentWords, targetWords).allSatisfy({ $0.key == $1.key })
        else {
            return nil
        }

        if targetWords.count > currentWords.count {
            return tail(after: targetWords[currentWords.count - 1], in: target, current: current)
        }

        guard let currentFinalWord = currentWords.last,
              let finalWord = targetWords.last
        else {
            return ""
        }

        // When both passes contain the same words, their only possible difference is the
        // decoration after the final word. Replace that decoration as a unit: a live preview
        // can leave a space behind, or revise a comma to a period before the final pass. Merely
        // appending the final decoration would otherwise produce output such as `word,.`.
        let currentDecoration = String(current[currentFinalWord.range.upperBound...])
        let finalDecoration = String(target[finalWord.range.upperBound...])
        guard currentDecoration != finalDecoration else { return "" }
        return String(repeating: "\u{7F}", count: currentDecoration.count) + finalDecoration
    }

    /// Returns the final word of the earliest longest in-order alignment. The earliest tie-break
    /// is important for transcripts with a repeated phrase: a live preview of the first phrase
    /// must not be treated as though it had already reached a later occurrence in the final pass.
    private static func appendAlignment(
        from currentWords: [WordToken],
        to targetWords: [WordToken]
    ) -> WordAlignment? {
        var previousRow = Array(repeating: WordAlignment(), count: targetWords.count + 1)

        for currentWord in currentWords {
            var currentRow = Array(repeating: WordAlignment(), count: targetWords.count + 1)

            for targetIndex in targetWords.indices {
                let column = targetIndex + 1
                var best = preferred(previousRow[column], over: currentRow[column - 1])

                if currentWord.key == targetWords[targetIndex].key {
                    let diagonal = previousRow[column - 1]
                    let matched = WordAlignment(
                        count: diagonal.count + 1,
                        targetEndIndex: targetIndex
                    )
                    best = preferred(matched, over: best)
                }
                currentRow[column] = best
            }
            previousRow = currentRow
        }

        guard let alignment = previousRow.last,
              alignment.count >= minimumAlignmentWords,
              alignment.targetEndIndex >= 0
        else {
            return nil
        }
        return alignment
    }

    private static func preferred(_ lhs: WordAlignment, over rhs: WordAlignment) -> WordAlignment {
        if lhs.count != rhs.count { return lhs.count > rhs.count ? lhs : rhs }
        if lhs.count == 0 { return lhs }
        return lhs.targetEndIndex <= rhs.targetEndIndex ? lhs : rhs
    }

    private static func requiredLiveAlignment(
        currentWordCount: Int,
        targetWordCount: Int
    ) -> Int {
        max(minimumAlignmentWords, (min(currentWordCount, targetWordCount) + 1) / 2)
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

    private static func completeWords(in text: String) -> String {
        guard let finalWhitespace = text.lastIndex(where: \.isWhitespace) else { return "" }
        return String(text[...finalWhitespace])
    }

    private static func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        String(zip(lhs, rhs).prefix { $0 == $1 }.map(\.0))
    }
}

private struct WordToken {
    let text: String
    let range: Range<String.Index>

    var key: String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private struct WordAlignment {
    let count: Int
    let targetEndIndex: Int

    init(count: Int = 0, targetEndIndex: Int = -1) {
        self.count = count
        self.targetEndIndex = targetEndIndex
    }
}
