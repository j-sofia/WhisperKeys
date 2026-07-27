import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Resolves characters against a snapshot of the user's selected macOS keyboard layout.
///
/// Text Input Source and Carbon keyboard-layout APIs are accessed only on the main thread.
/// The resulting physical keystrokes can then be emitted on the typing queue without touching
/// those APIs again. Characters that require a dead-key sequence are reported as unsupported
/// instead of being sent as a Unicode string event.
final class KeyboardMapper {
    private let candidates: [(modifierState: UInt32, flags: CGEventFlags)] = [
        (0, []),
        (UInt32(shiftKey >> 8), .maskShift),
        (UInt32(optionKey >> 8), .maskAlternate),
        (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate])
    ]

    /// Captures the current input source once. This must run on the main thread because the
    /// Text Input Source APIs can trap when called from the background typing queue.
    func map(_ text: String) throws -> [KeyStroke] {
        guard !text.isEmpty else { return [] }
        dispatchPrecondition(condition: .onQueue(.main))

        let layout = try KeyboardLayout.current()
        let strokesByCharacter = makeStrokeMap(using: layout)
        return try text.map { character in
            if let special = specialStroke(for: character) {
                return special
            }
            guard let stroke = strokesByCharacter[String(character)] else {
                throw TypingError.unsupportedCharacter(character)
            }
            return stroke
        }
    }

    private func specialStroke(for character: Character) -> KeyStroke? {
        switch character {
        case "\n", "\r":
            return KeyStroke(keyCode: CGKeyCode(kVK_Return), modifiers: [])
        case "\t":
            return KeyStroke(keyCode: CGKeyCode(kVK_Tab), modifiers: [])
        case "\u{08}", "\u{7F}":
            return KeyStroke(keyCode: CGKeyCode(kVK_Delete), modifiers: [])
        default:
            return nil
        }
    }

    /// Searches the layout once per transcription rather than once per character.
    private func makeStrokeMap(using layout: KeyboardLayout) -> [String: KeyStroke] {
        var strokesByCharacter: [String: KeyStroke] = [:]
        strokesByCharacter.reserveCapacity(256)
        for keyCode in CGKeyCode(0)...CGKeyCode(127) {
            for candidate in candidates {
                guard let character = layout.translatedCharacter(for: keyCode, modifierState: candidate.modifierState) else {
                    continue
                }
                if strokesByCharacter[character] == nil {
                    strokesByCharacter[character] = KeyStroke(keyCode: keyCode, modifiers: candidate.flags)
                }
            }
        }
        return strokesByCharacter
    }
}

/// A retained, immutable `uchr` keyboard-layout snapshot. Holding a copy prevents a layout
/// change from invalidating the pointer while `UCKeyTranslate` is iterating over key codes.
private struct KeyboardLayout {
    private let data: CFData
    private let keyboardType: UInt32

    static func current() throws -> Self {
        let currentData = TISCopyCurrentKeyboardLayoutInputSource()
            .flatMap { copyLayoutData(from: $0.takeRetainedValue()) }

        guard let data = currentData ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()
            .flatMap({ copyLayoutData(from: $0.takeRetainedValue()) }),
              CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size
        else {
            throw TypingError.keyboardLayoutUnavailable
        }

        return Self(data: data, keyboardType: UInt32(LMGetKbdType()))
    }

    func translatedCharacter(for keyCode: CGKeyCode, modifierState: UInt32) -> String? {
        guard let bytes = CFDataGetBytePtr(data) else { return nil }

        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var unicode = Array<UniChar>(repeating: 0, count: 8)

        // `kTISPropertyUnicodeKeyLayoutData` is documented as the native `uchr` data for
        // `UCKeyTranslate`; using the raw pointer avoids rebinding CFData's byte storage.
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let status = unicode.withUnsafeMutableBufferPointer { buffer in
            UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDown),
                modifierState,
                keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                buffer.count,
                &actualLength,
                buffer.baseAddress
            )
        }

        guard status == noErr,
              deadKeyState == 0,
              actualLength > 0,
              actualLength <= unicode.count
        else { return nil }
        return String(utf16CodeUnits: unicode, count: actualLength)
    }

    private static func copyLayoutData(from source: TISInputSource) -> CFData? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        return CFDataCreateCopy(kCFAllocatorDefault, layoutData)
    }
}
