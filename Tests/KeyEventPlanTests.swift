import Carbon.HIToolbox
import CoreGraphics
import XCTest

@testable import WhisperKeys

final class KeyEventPlanTests: XCTestCase {
    func testShiftedCharacterUsesExplicitShiftDownAndUp() {
        let stroke = KeyStroke(keyCode: 0, modifiers: .maskShift)

        XCTAssertEqual(KeyEventPlan.modifierKeyDownEvents(for: stroke), [
            PhysicalKeyEvent(keyCode: CGKeyCode(kVK_Shift), keyDown: true, flags: .maskShift)
        ])
        XCTAssertEqual(KeyEventPlan.keyDownEvent(for: stroke), PhysicalKeyEvent(keyCode: 0, keyDown: true, flags: .maskShift))
        XCTAssertEqual(KeyEventPlan.keyUpEvent(for: stroke), PhysicalKeyEvent(keyCode: 0, keyDown: false, flags: .maskShift))
        XCTAssertEqual(KeyEventPlan.modifierKeyUpEvents(for: stroke), [
            PhysicalKeyEvent(keyCode: CGKeyCode(kVK_Shift), keyDown: false, flags: [])
        ])
    }

    func testShiftOptionCharacterPressesModifiersInOrderAndReleasesThemInReverse() {
        let stroke = KeyStroke(keyCode: 14, modifiers: [.maskShift, .maskAlternate])

        XCTAssertEqual(KeyEventPlan.modifierKeyDownEvents(for: stroke), [
            PhysicalKeyEvent(keyCode: CGKeyCode(kVK_Shift), keyDown: true, flags: .maskShift),
            PhysicalKeyEvent(keyCode: CGKeyCode(kVK_Option), keyDown: true, flags: [.maskShift, .maskAlternate])
        ])
        XCTAssertEqual(KeyEventPlan.modifierKeyUpEvents(for: stroke), [
            PhysicalKeyEvent(keyCode: CGKeyCode(kVK_Option), keyDown: false, flags: .maskShift),
            PhysicalKeyEvent(keyCode: CGKeyCode(kVK_Shift), keyDown: false, flags: [])
        ])
    }

    func testUnmodifiedCharacterHasNoModifierEvents() {
        let stroke = KeyStroke(keyCode: 0, modifiers: [])

        XCTAssertTrue(KeyEventPlan.modifierKeyDownEvents(for: stroke).isEmpty)
        XCTAssertTrue(KeyEventPlan.modifierKeyUpEvents(for: stroke).isEmpty)
    }
}
