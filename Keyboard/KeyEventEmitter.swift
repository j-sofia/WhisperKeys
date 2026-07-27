import ApplicationServices
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

protocol KeyEventEmitting: AnyObject {
    /// Performs checks needed before a sequence of key events is emitted.
    func beginTyping() throws
    func emitKeyDown(_ stroke: KeyStroke) throws
    func emitKeyUp(_ stroke: KeyStroke) throws
    /// Emits an immediate key-down/key-up pair. The fastest typing mode uses
    /// this to avoid creating two CoreGraphics event objects per character.
    func emitImmediateKeyStroke(_ stroke: KeyStroke) throws
}

extension KeyEventEmitting {
    func beginTyping() throws {}

    func emitImmediateKeyStroke(_ stroke: KeyStroke) throws {
        try emitKeyDown(stroke)
        try emitKeyUp(stroke)
    }
}

/// An alternate text transport for clients that discard Core Graphics keyboard events.
///
/// `System Events` generates input through a different macOS path from `CGEvent.post`. The
/// Windows App recognizes that path reliably when its scancode input path loses modifiers.
protocol FocusedTextEmitting: AnyObject {
    /// This is queried on the main thread while the intended target still has focus.
    func shouldUseForFocusedApplication() -> Bool
    func emitText(_ text: String) throws
}

/// Sends text through System Events when the Microsoft Windows App is focused.
final class SystemEventsTextEmitter: FocusedTextEmitting {
    // Microsoft retained this bundle identifier when Remote Desktop for Mac became Windows App.
    private static let windowsAppBundleIdentifier = "com.microsoft.rdc.macos"

    func shouldUseForFocusedApplication() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.windowsAppBundleIdentifier
    }

    func emitText(_ text: String) throws {
        guard !text.isEmpty else { return }
        let source = SystemEventsTextScript.source(for: text)
        guard let script = NSAppleScript(source: source) else {
            throw TypingError.systemEventsTypingFailed("macOS could not prepare the compatibility typing script.")
        }

        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if let message = error?[NSAppleScript.errorMessage] as? String {
            throw TypingError.systemEventsTypingFailed(message)
        }
    }
}

/// Builds a safe AppleScript payload without interpolating transcription text as source code.
/// Printable text is represented by Unicode character IDs; control characters remain physical
/// Return, Tab, and Delete key presses so the normal typing semantics are preserved.
enum SystemEventsTextScript {
    static func source(for text: String) -> String {
        let commands = commands(for: text)
        return """
        tell application "System Events"
        \(commands.map { "    \($0)" }.joined(separator: "\n"))
        end tell
        """
    }

    private static func commands(for text: String) -> [String] {
        var commands: [String] = []
        var printableRun = ""

        func flushPrintableRun() {
            guard !printableRun.isEmpty else { return }
            let expression = printableRun.unicodeScalars
                .map { "character id \($0.value)" }
                .joined(separator: " & ")
            commands.append("keystroke (\(expression))")
            printableRun.removeAll(keepingCapacity: true)
        }

        for character in text {
            switch character {
            case "\n", "\r":
                flushPrintableRun()
                commands.append("key code 36") // Return
            case "\t":
                flushPrintableRun()
                commands.append("key code 48") // Tab
            case "\u{08}", "\u{7F}":
                flushPrintableRun()
                commands.append("key code 51") // Delete
            default:
                printableRun.append(character)
            }
        }
        flushPrintableRun()
        return commands
    }
}

/// A physical event required to produce one mapped character.
///
/// A modifier flag on the character event alone is enough for many local macOS controls, but
/// remote-desktop clients commonly forward actual modifier key transitions instead. Keeping the
/// sequence explicit is therefore essential for uppercase letters and shifted punctuation in
/// Windows VMs.
struct PhysicalKeyEvent: Equatable {
    let keyCode: CGKeyCode
    let keyDown: Bool
    let flags: CGEventFlags
}

/// Expands a logical `KeyStroke` into the physical key events required to type it.
enum KeyEventPlan {
    private static let modifierKeys: [(flag: CGEventFlags, keyCode: CGKeyCode)] = [
        (.maskShift, CGKeyCode(kVK_Shift)),
        (.maskAlternate, CGKeyCode(kVK_Option)),
        (.maskControl, CGKeyCode(kVK_Control)),
        (.maskCommand, CGKeyCode(kVK_Command))
    ]

    static func modifierKeyDownEvents(for stroke: KeyStroke) -> [PhysicalKeyEvent] {
        let modifiers = requiredModifiers(for: stroke)
        var activeFlags = stroke.modifiers.subtracting(flags(for: modifiers))

        return modifiers.map { modifier in
            activeFlags.insert(modifier.flag)
            return PhysicalKeyEvent(
                keyCode: modifier.keyCode,
                keyDown: true,
                flags: activeFlags
            )
        }
    }

    static func keyDownEvent(for stroke: KeyStroke) -> PhysicalKeyEvent {
        PhysicalKeyEvent(keyCode: stroke.keyCode, keyDown: true, flags: stroke.modifiers)
    }

    static func keyUpEvent(for stroke: KeyStroke) -> PhysicalKeyEvent {
        PhysicalKeyEvent(keyCode: stroke.keyCode, keyDown: false, flags: stroke.modifiers)
    }

    static func modifierKeyUpEvents(for stroke: KeyStroke) -> [PhysicalKeyEvent] {
        let modifiers = requiredModifiers(for: stroke)
        var activeFlags = stroke.modifiers

        return modifiers.reversed().map { modifier in
            activeFlags.remove(modifier.flag)
            return PhysicalKeyEvent(
                keyCode: modifier.keyCode,
                keyDown: false,
                flags: activeFlags
            )
        }
    }

    private static func requiredModifiers(for stroke: KeyStroke) -> [(flag: CGEventFlags, keyCode: CGKeyCode)] {
        modifierKeys.filter { stroke.modifiers.contains($0.flag) }
    }

    private static func flags(for modifiers: [(flag: CGEventFlags, keyCode: CGKeyCode)]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { flags, modifier in
            flags.insert(modifier.flag)
        }
    }
}

/// CoreGraphics implementation of the keystroke transport.
///
/// The fastest path reuses one mutable `CGEvent` for the character itself. Modifiers are still
/// sent as discrete key-down and key-up events; there is deliberately no
/// `CGEvent.keyboardSetUnicodeString`, pasteboard write, Cmd-V shortcut, Accessibility insertion,
/// or text-system insertion in this layer.
final class CGEventKeyEmitter: KeyEventEmitting {
    /// Gives remote desktop clients a chance to forward a modifier before the dependent key.
    /// This is only used for shifted/modified characters, so normal fast typing remains fast.
    private static let modifierTransitionDelay: TimeInterval = 0.02

    private let source = CGEventSource(stateID: .hidSystemState)
    private var immediateEvent: CGEvent?

    func beginTyping() throws {
        guard AXIsProcessTrusted() else {
            throw TypingError.accessibilityPermissionRequired
        }
    }

    func emitKeyDown(_ stroke: KeyStroke) throws {
        let modifierEvents = KeyEventPlan.modifierKeyDownEvents(for: stroke)
        do {
            try post(modifierEvents)
            settleAfterModifierTransition(ifNeeded: modifierEvents)
            try post(KeyEventPlan.keyDownEvent(for: stroke))
        } catch {
            try? post(KeyEventPlan.modifierKeyUpEvents(for: stroke))
            throw error
        }
    }

    func emitKeyUp(_ stroke: KeyStroke) throws {
        let modifierEvents = KeyEventPlan.modifierKeyUpEvents(for: stroke)
        do {
            try post(KeyEventPlan.keyUpEvent(for: stroke))
        } catch {
            try? post(modifierEvents)
            throw error
        }
        settleAfterModifierTransition(ifNeeded: modifierEvents)
        try post(modifierEvents)
    }

    func emitImmediateKeyStroke(_ stroke: KeyStroke) throws {
        let modifierDownEvents = KeyEventPlan.modifierKeyDownEvents(for: stroke)
        let modifierUpEvents = KeyEventPlan.modifierKeyUpEvents(for: stroke)

        do {
            try post(modifierDownEvents)
            settleAfterModifierTransition(ifNeeded: modifierDownEvents)
            try postImmediateCharacter(stroke, keyDown: true)
            try postImmediateCharacter(stroke, keyDown: false)
        } catch {
            try? post(modifierUpEvents)
            throw error
        }

        settleAfterModifierTransition(ifNeeded: modifierUpEvents)
        try post(modifierUpEvents)
    }

    private func postImmediateCharacter(_ stroke: KeyStroke, keyDown: Bool) throws {
        let event: CGEvent
        if let immediateEvent {
            event = immediateEvent
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(stroke.keyCode))
            event.type = keyDown ? .keyDown : .keyUp
        } else {
            guard let newEvent = CGEvent(
                keyboardEventSource: source,
                virtualKey: stroke.keyCode,
                keyDown: keyDown
            ) else {
                throw TypingError.couldNotCreateEvent
            }
            immediateEvent = newEvent
            event = newEvent
        }

        event.flags = stroke.modifiers
        event.post(tap: .cghidEventTap)
    }

    private func post(_ events: [PhysicalKeyEvent]) throws {
        for event in events {
            try post(event)
        }
    }

    private func post(_ plannedEvent: PhysicalKeyEvent) throws {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: plannedEvent.keyCode,
            keyDown: plannedEvent.keyDown
        ) else {
            throw TypingError.couldNotCreateEvent
        }

        event.flags = plannedEvent.flags
        event.post(tap: .cghidEventTap)
    }

    private func settleAfterModifierTransition(ifNeeded modifierEvents: [PhysicalKeyEvent]) {
        guard !modifierEvents.isEmpty else { return }
        Thread.sleep(forTimeInterval: Self.modifierTransitionDelay)
    }
}
