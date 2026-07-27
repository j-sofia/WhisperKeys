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
            return tail(after: targetWords[currentWords.count - 1], in: target, current: current)
        }

        guard let finalWord = targetWords.last else { return "" }
        let trailingPunctuation = String(target[finalWord.range.upperBound...])
        guard !trailingPunctuation.isEmpty, !current.hasSuffix(trailingPunctuation) else { return "" }
        return (current.last?.isWhitespace == true ? "\u{7F}" : "") + trailingPunctuation
    }

    /// Returns the remaining final transcript even if the final pass revised some live text.
    /// Prefer the shared starting words. When the final result inserted or revised its opening,
    /// use a multi-word suffix of live text as an anchor. If no reliable anchor remains, append
    /// the complete final result: duplicated text is preferable to silently losing dictation.
    static func finalEdit(from current: String, to target: String) -> String {
        if current.isEmpty { return target }
        if let exactEdit = liveEdit(from: current, to: target) { return exactEdit }

        let currentWords = words(in: current)
        let targetWords = words(in: target)
        guard !targetWords.isEmpty else { return "" }

        let prefixLength = commonPrefixLength(currentWords, targetWords)
        if prefixLength > 0 {
            return tail(after: targetWords[prefixLength - 1], in: target, current: current)
        }

        if let anchor = suffixAnchor(from: currentWords, in: targetWords) {
            return tail(after: targetWords[anchor.targetEndIndex], in: target, current: current)
        }

        return append(target, to: current)
    }

    private static func suffixAnchor(from current: [WordToken], in target: [WordToken]) -> Anchor? {
        // A two-word anchor avoids treating a common word such as “the” as proof that two
        // unrelated hypotheses are the same phrase.
        guard current.count >= 2, target.count >= 2 else { return nil }

        for length in stride(from: min(current.count, target.count), through: 2, by: -1) {
            let suffix = current.suffix(length)
            for startIndex in 0...(target.count - length) {
                let candidate = target[startIndex..<(startIndex + length)]
                guard zip(suffix, candidate).allSatisfy({ $0.key == $1.key }) else { continue }
                return Anchor(targetEndIndex: startIndex + length - 1)
            }
        }
        return nil
    }

    private static func commonPrefixLength(_ lhs: [WordToken], _ rhs: [WordToken]) -> Int {
        zip(lhs, rhs).prefix { $0.key == $1.key }.count
    }

    private static func tail(after word: WordToken, in target: String, current: String) -> String {
        var tail = String(target[word.range.upperBound...])
        guard !tail.isEmpty else { return "" }

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

private struct Anchor {
    let targetEndIndex: Int
}
