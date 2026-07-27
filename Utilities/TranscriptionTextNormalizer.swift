import Foundation

enum TranscriptionTextNormalizer {
    static func prepare(
        _ recognized: String,
        autoCapitalizeFirstSentence: Bool,
        appendReturn: Bool
    ) -> String {
        var text = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        if autoCapitalizeFirstSentence, let first = text.first {
            text.replaceSubrange(text.startIndex...text.startIndex, with: first.uppercased())
        }
        if appendReturn { text.append("\n") }
        return text
    }
}
