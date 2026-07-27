import ApplicationServices
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

/// CoreGraphics implementation of the keystroke transport.
///
/// Events use one virtual key code. The fastest path reuses one mutable CGEvent across the
/// sequence; there is deliberately no `CGEvent.keyboardSetUnicodeString`, pasteboard write,
/// Cmd-V shortcut, Accessibility insertion, or text-system insertion in this layer.
final class CGEventKeyEmitter: KeyEventEmitting {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var immediateEvent: CGEvent?

    func beginTyping() throws {
        guard AXIsProcessTrusted() else {
            throw TypingError.accessibilityPermissionRequired
        }
    }

    func emitKeyDown(_ stroke: KeyStroke) throws {
        try post(stroke, keyDown: true)
    }

    func emitKeyUp(_ stroke: KeyStroke) throws {
        try post(stroke, keyDown: false)
    }

    func emitImmediateKeyStroke(_ stroke: KeyStroke) throws {
        let event: CGEvent
        if let immediateEvent {
            event = immediateEvent
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(stroke.keyCode))
            event.type = .keyDown
        } else {
            guard let newEvent = CGEvent(
                keyboardEventSource: source,
                virtualKey: stroke.keyCode,
                keyDown: true
            ) else {
                throw TypingError.couldNotCreateEvent
            }
            immediateEvent = newEvent
            event = newEvent
        }

        event.flags = stroke.modifiers
        event.post(tap: .cghidEventTap)
        event.type = .keyUp
        event.post(tap: .cghidEventTap)
    }

    private func post(_ stroke: KeyStroke, keyDown: Bool) throws {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: stroke.keyCode,
            keyDown: keyDown
        ) else {
            throw TypingError.couldNotCreateEvent
        }

        event.flags = stroke.modifiers
        event.post(tap: .cghidEventTap)
    }
}
