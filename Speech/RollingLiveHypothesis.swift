import Foundation

/// Maintains a single, append-only-looking hypothesis while the audio being decoded moves
/// forward in bounded, overlapping windows. Whisper's output inside the most recent window
/// can still change; text before the overlap is retained as the window moves on.
struct RollingLiveHypothesis {
    private struct Word {
        let display: String
        let comparisonKey: String
    }

    private var confirmed: [Word] = []
    private var pending: [Word] = []

    mutating func update(_ transcription: String, windowAdvanced: Bool) -> String {
        let incoming = words(in: transcription)
        guard !incoming.isEmpty else { return renderedText }

        guard windowAdvanced, !pending.isEmpty else {
            pending = incoming
            return renderedText
        }

        // Keep enough shared text at the handoff that an ordinary Whisper revision does not
        // make the caller's full hypothesis jump backwards. One matching word is too easy to
        // find accidentally (for example, "the"), so wait for a short phrase.
        let overlap = longestOverlap(from: pending, to: incoming) ?? 0
        if overlap < 2 {
            // A preview can take longer than the advance interval on slower machines. In that
            // case the next result may already start beyond the previous result's useful
            // overlap, or Whisper may revise the overlap completely. Retaining `pending` here
            // would make every later advanced window compare against stale text and live typing
            // would stop until the final pass. Keep moving forward instead; the caller still
            // waits for two matching hypotheses before emitting text to the focused app.
            // A single matched word is not strong enough to make this a normal handoff, but
            // it is enough to avoid duplicating that exact boundary word in the fallback.
        }
        confirmed.append(contentsOf: pending.dropLast(overlap))
        pending = incoming
        return renderedText
    }

    mutating func reset() {
        confirmed = []
        pending = []
    }

    private var renderedText: String {
        (confirmed + pending).map(\.display).joined(separator: " ")
    }

    private func words(in text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).map { token in
            let display = String(token)
            let comparisonKey = display.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(String.init)
                .joined()
                .lowercased()
            return Word(
                display: display,
                comparisonKey: comparisonKey.isEmpty ? display.lowercased() : comparisonKey
            )
        }
    }

    private func longestOverlap(from previous: [Word], to current: [Word]) -> Int? {
        let maximum = min(previous.count, current.count)
        for length in stride(from: maximum, through: 1, by: -1) {
            guard zip(previous.suffix(length), current.prefix(length)).allSatisfy({
                $0.comparisonKey == $1.comparisonKey
            }) else {
                continue
            }
            return length
        }
        return nil
    }
}
