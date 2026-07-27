import Carbon.HIToolbox
import CoreGraphics

@testable import WhisperKeys

final class TestKeyboardLayout: KeyboardLayoutTranslating {
    private struct Key: Hashable {
        let keyCode: CGKeyCode
        let modifierState: UInt32
    }

    private let characters: [Key: String]

    init(entries: [(keyCode: CGKeyCode, modifierState: UInt32, character: String)]) {
        characters = Dictionary(
            uniqueKeysWithValues: entries.map {
                (Key(keyCode: $0.keyCode, modifierState: $0.modifierState), $0.character)
            }
        )
    }

    func translatedCharacter(for keyCode: CGKeyCode, modifierState: UInt32) -> String? {
        characters[Key(keyCode: keyCode, modifierState: modifierState)]
    }
}

func testMapper(
    entries: [(keyCode: CGKeyCode, modifierState: UInt32, character: String)]
) -> KeyboardMapper {
    let layout = TestKeyboardLayout(entries: entries)
    return KeyboardMapper(layoutProvider: { layout })
}

func testMapper(for text: String) -> KeyboardMapper {
    var entries: [(keyCode: CGKeyCode, modifierState: UInt32, character: String)] = []
    var seen = Set<Character>()

    for character in text where !character.isNewline && character != "\t" {
        guard seen.insert(character).inserted else { continue }
        entries.append((CGKeyCode(entries.count), 0, String(character)))
    }

    return testMapper(entries: entries)
}

let testShiftModifier = UInt32(shiftKey >> 8)
let testOptionModifier = UInt32(optionKey >> 8)

struct StrokeSnapshot: Equatable {
    let keyCode: CGKeyCode
    let modifiers: UInt64

    init(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
    }

    init(_ stroke: KeyStroke) {
        self.init(keyCode: stroke.keyCode, modifiers: stroke.modifiers)
    }
}
