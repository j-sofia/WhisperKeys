import Carbon.HIToolbox
import CoreGraphics
import XCTest

@testable import WhisperKeys

@MainActor
final class KeyboardMapperTests: XCTestCase {
    func testMapsLowercaseUppercasePunctuationTabAndNewline() throws {
        let mapper = testMapper(entries: [
            (0, 0, "a"),
            (0, testShiftModifier, "A"),
            (18, testShiftModifier, "!")
        ])

        let strokes = try mapper.map("aA!\t\n")

        XCTAssertEqual(strokes.map(StrokeSnapshot.init), [
            StrokeSnapshot(keyCode: 0, modifiers: []),
            StrokeSnapshot(keyCode: 0, modifiers: .maskShift),
            StrokeSnapshot(keyCode: 18, modifiers: .maskShift),
            StrokeSnapshot(keyCode: CGKeyCode(kVK_Tab), modifiers: []),
            StrokeSnapshot(keyCode: CGKeyCode(kVK_Return), modifiers: [])
        ])
    }

    func testMapsOptionAndShiftOptionCharactersWithTheirModifiers() throws {
        let mapper = testMapper(entries: [
            (14, testOptionModifier, "å"),
            (14, testShiftModifier | testOptionModifier, "Å")
        ])

        let strokes = try mapper.map("åÅ")

        XCTAssertEqual(strokes.map(StrokeSnapshot.init), [
            StrokeSnapshot(keyCode: 14, modifiers: .maskAlternate),
            StrokeSnapshot(keyCode: 14, modifiers: [.maskShift, .maskAlternate])
        ])
    }

    func testMapsUnicodeCharacterProvidedByLayout() throws {
        let mapper = testMapper(entries: [(12, 0, "é")])

        XCTAssertEqual(
            try mapper.map("é").map(StrokeSnapshot.init),
            [StrokeSnapshot(keyCode: 12, modifiers: [])]
        )
    }

    func testRejectsUnsupportedUnicodeGraphemeWithoutSubstitutingIt() {
        let mapper = testMapper(entries: [])

        XCTAssertThrowsError(try mapper.map("👩🏽‍💻")) { error in
            guard case let TypingError.unsupportedCharacter(character) = error else {
                return XCTFail("Expected an unsupported-character error, got \(error)")
            }
            XCTAssertEqual(character, "👩🏽‍💻")
        }
    }
}
