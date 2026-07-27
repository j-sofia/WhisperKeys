import CoreGraphics
import Foundation

struct KeyStroke {
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags
}

struct TypingConfiguration {
    let wordsPerMinute: Int
    let keyDownMilliseconds: Int
    let extraCharacterDelayMilliseconds: Int
    let extraWordDelayMilliseconds: Int

    init(
        wordsPerMinute: Int,
        keyDownMilliseconds: Int,
        extraCharacterDelayMilliseconds: Int,
        extraWordDelayMilliseconds: Int
    ) {
        // Zero represents the fastest mode: emit each key event without an
        // intentional delay between characters.
        self.wordsPerMinute = min(max(wordsPerMinute, 0), 200)
        self.keyDownMilliseconds = min(max(keyDownMilliseconds, 0), 250)
        self.extraCharacterDelayMilliseconds = min(max(extraCharacterDelayMilliseconds, 0), 5_000)
        self.extraWordDelayMilliseconds = min(max(extraWordDelayMilliseconds, 0), 5_000)
    }

    /// A conventional word is five characters, so 60 WPM is 200 ms per character.
    /// Zero is the fastest mode and adds no delay between characters.
    var characterIntervalMilliseconds: Double {
        guard wordsPerMinute > 0 else { return 0 }
        return 60_000.0 / Double(wordsPerMinute * 5)
    }

    var isFastest: Bool {
        wordsPerMinute == 0
            && keyDownMilliseconds == 0
            && extraCharacterDelayMilliseconds == 0
            && extraWordDelayMilliseconds == 0
    }

    /// Remote clients need separate, observable down/up transitions even when the user selected
    /// fastest typing. This only adds the amount of timing missing from the current preference.
    func applyingMinimumKeyTiming(
        keyDownMilliseconds minimumKeyDownMilliseconds: Int,
        characterIntervalMilliseconds minimumCharacterIntervalMilliseconds: Int
    ) -> TypingConfiguration {
        let keyDownMilliseconds = max(self.keyDownMilliseconds, minimumKeyDownMilliseconds)
        let existingCharacterInterval = characterIntervalMilliseconds + Double(extraCharacterDelayMilliseconds)
        let additionalCharacterDelay = max(
            0,
            Int(ceil(Double(minimumCharacterIntervalMilliseconds) - existingCharacterInterval))
        )
        return TypingConfiguration(
            wordsPerMinute: wordsPerMinute,
            keyDownMilliseconds: keyDownMilliseconds,
            extraCharacterDelayMilliseconds: extraCharacterDelayMilliseconds + additionalCharacterDelay,
            extraWordDelayMilliseconds: extraWordDelayMilliseconds
        )
    }
}

struct TypingLogEntry: Identifiable {
    let id = UUID()
    let character: String
    let keyCode: CGKeyCode
    let modifierDescription: String
    let elapsedMilliseconds: Double
    let timestamp: Date
}

enum TypingError: LocalizedError {
    case accessibilityPermissionRequired
    case couldNotCreateEvent
    case keyboardLayoutUnavailable
    case unsupportedCharacter(Character)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            "Accessibility permission is required before WhisperKeys can emit key events."
        case .couldNotCreateEvent:
            "macOS could not create a keyboard event."
        case .keyboardLayoutUnavailable:
            "macOS could not read the active keyboard layout. Switch to a standard keyboard layout and try again."
        case .unsupportedCharacter(let character):
            "The active keyboard layout cannot type “\(character)” as one key press."
        }
    }
}
