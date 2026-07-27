import Carbon.HIToolbox
import CoreGraphics
import Foundation
import XCTest

@testable import WhisperKeys

final class KeyEventPlanTests: XCTestCase {
    func testSystemEventsScriptSendsPrintableTextWithoutInterpolatingItAsSource() {
        XCTAssertEqual(
            SystemEventsTextScript.source(for: "A\\\"b"),
            """
            tell application "System Events"
                keystroke (character id 65 & character id 92 & character id 34 & character id 98)
            end tell
            """
        )
    }

    func testSystemEventsScriptKeepsReturnTabAndDeleteAsPhysicalKeys() {
        XCTAssertEqual(
            SystemEventsTextScript.source(for: "A\n\t\u{08}B"),
            """
            tell application "System Events"
                keystroke (character id 65)
                key code 36
                key code 48
                key code 51
                keystroke (character id 66)
            end tell
            """
        )
    }

    func testSystemEventsScriptCompilesWithoutExecutingAutomation() {
        let script = NSAppleScript(source: SystemEventsTextScript.source(for: "Hello\nWorld"))
        var error: NSDictionary?

        XCTAssertTrue(script?.compileAndReturnError(&error) == true, "\(error ?? [:])")
    }

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
