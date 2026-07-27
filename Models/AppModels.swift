import Carbon.HIToolbox
import Darwin
import Foundation
import SwiftUI

enum AppActivity: Equatable {
    case idle
    case recording
    case transcribing
    case reviewing
    case typing
    case installingModel
    case error(String)

    var displayName: String {
        switch self {
        case .idle: "Ready"
        case .recording: "Listening…"
        case .transcribing: "Transcribing locally…"
        case .reviewing: "Review transcription"
        case .typing: "Typing…"
        case .installingModel: "Installing local model…"
        case .error(let message): message
        }
    }
}

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case live
    case reviewBeforeTyping

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .live: "Live mode"
        case .reviewBeforeTyping: "Review before typing"
        }
    }
}

enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny = "tiny"
    case small = "small"
    case base = "base"
    case largeV3 = "large-v3-v20240930_626MB"

    var id: String { rawValue }

    /// Ordered from the lightest to the most capable model. `CaseIterable` preserves
    /// declaration order, so keep this explicit in case a future model is inserted.
    static let selectionOrder: [WhisperModel] = [.tiny, .base, .small, .largeV3]

    var displayName: String {
        switch self {
        case .tiny: "Tiny"
        case .small: "Small"
        case .base: "Base"
        case .largeV3: "Large v3"
        }
    }

    /// Approximate figures for the optimized WhisperKit downloads. Runtime memory
    /// changes with the audio being processed and other apps running on the Mac.
    var downloadSize: String {
        switch self {
        case .tiny: "75 MB"
        case .base: "142 MB"
        case .small: "466 MB"
        case .largeV3: "626 MB"
        }
    }

    var estimatedMemory: String {
        switch self {
        case .tiny: "~0.7 GB"
        case .base: "~1 GB"
        case .small: "~2 GB"
        case .largeV3: "~3.5 GB"
        }
    }

    var accuracyLabel: String {
        switch self {
        case .tiny: "Good"
        case .base: "Better"
        case .small: "High"
        case .largeV3: "Best"
        }
    }

    var speedLabel: String {
        switch self {
        case .tiny: "Fastest"
        case .base: "Fast"
        case .small: "Balanced"
        case .largeV3: "Slower"
        }
    }

    var cardSummary: String {
        switch self {
        case .tiny: "Quick, everyday dictation."
        case .base: "Best balance for live dictation."
        case .small: "Extra help with voices and noise."
        case .largeV3: "Best accuracy for careful transcription."
        }
    }
}

/// The small amount of hardware information needed to make a conservative, local
/// model suggestion. It never leaves the Mac.
struct MacHardwareProfile: Equatable {
    let isAppleSilicon: Bool
    let memoryBytes: UInt64
    let activeProcessorCount: Int

    static let current = MacHardwareProfile(
        isAppleSilicon: sysctlInt("hw.optional.arm64") == 1,
        memoryBytes: ProcessInfo.processInfo.physicalMemory,
        activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
    )

    var memoryInGigabytes: Int {
        Int((Double(memoryBytes) / 1_073_741_824).rounded())
    }

    var processorDescription: String {
        isAppleSilicon ? "Apple silicon" : "Intel processor"
    }

    var shortDescription: String {
        "\(processorDescription) · \(memoryInGigabytes) GB memory"
    }

    var recommendedModel: WhisperModel {
        // Large is intentionally reserved for roomy Apple silicon Macs. This keeps
        // the default responsive while another app is using shared memory.
        if isAppleSilicon, memoryInGigabytes >= 32 {
            return .largeV3
        }
        if isAppleSilicon, memoryInGigabytes >= 24 {
            return .small
        }
        if isAppleSilicon, memoryInGigabytes >= 8 {
            return .base
        }
        if !isAppleSilicon, memoryInGigabytes >= 24, activeProcessorCount >= 8 {
            return .small
        }
        if !isAppleSilicon, memoryInGigabytes >= 16, activeProcessorCount >= 4 {
            return .base
        }
        return .tiny
    }

    private static func sysctlInt(_ name: String) -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return value
    }
}

/// How a global shortcut controls dictation.
enum ShortcutActivationMode: String, CaseIterable, Identifiable {
    case singlePress
    case doublePress
    case hold

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .singlePress: "Single press"
        case .doublePress: "Double press"
        case .hold: "Hold to talk"
        }
    }

    var detail: String {
        switch self {
        case .singlePress: "Press once to start or stop dictation."
        case .doublePress: "Press twice quickly to start or stop dictation."
        case .hold: "Hold to dictate, then release to transcribe."
        }
    }
}

/// A recorded physical key plus any modifiers that must be held with it.
/// `displayName` is captured alongside the key so a shortcut remains understandable even if the
/// user's keyboard layout changes before the next launch.
struct ShortcutConfiguration: Equatable {
    var keyCode: Int64?
    var modifierFlagsRawValue: UInt64
    var displayName: String

    static let defaultRightOption = ShortcutConfiguration(
        keyCode: Int64(kVK_RightOption),
        modifierFlagsRawValue: 0,
        displayName: "Right Option"
    )

    var isEnabled: Bool { keyCode != nil }

    var symbolName: String {
        guard let keyCode else { return "menubar.rectangle" }
        return switch Int(keyCode) {
        case kVK_RightOption, kVK_Option: "option"
        case kVK_RightCommand, kVK_Command: "command"
        case kVK_RightControl, kVK_Control: "control"
        case kVK_RightShift, kVK_Shift: "shift"
        default: "keyboard"
        }
    }

    var isModifierKey: Bool {
        guard let keyCode else { return false }
        switch Int(keyCode) {
        case kVK_RightOption, kVK_Option,
             kVK_RightCommand, kVK_Command,
             kVK_RightControl, kVK_Control,
             kVK_RightShift, kVK_Shift,
             kVK_CapsLock, 63: // Function (Fn) does not have a Carbon constant on every SDK.
            return true
        default:
            return false
        }
    }
}

/// Legacy modifier choices are kept solely to migrate existing user defaults.
enum ShortcutKey: String, CaseIterable, Identifiable {
    case rightOption
    case leftOption
    case rightCommand
    case leftCommand
    case rightControl
    case leftControl
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption: "Right Option"
        case .leftOption: "Left Option"
        case .rightCommand: "Right Command"
        case .leftCommand: "Left Command"
        case .rightControl: "Right Control"
        case .leftControl: "Left Control"
        case .disabled: "Disabled"
        }
    }

    /// The SF Symbol that represents this modifier in the menu-bar shortcut card.
    /// Left and right variants intentionally share the same modifier glyph.
    var symbolName: String {
        switch self {
        case .rightOption, .leftOption: "option"
        case .rightCommand, .leftCommand: "command"
        case .rightControl, .leftControl: "control"
        case .disabled: "menubar.rectangle"
        }
    }

    var shortcutConfiguration: ShortcutConfiguration {
        let keyCode: Int64?
        switch self {
        case .rightOption: keyCode = Int64(kVK_RightOption)
        case .leftOption: keyCode = Int64(kVK_Option)
        case .rightCommand: keyCode = Int64(kVK_RightCommand)
        case .leftCommand: keyCode = Int64(kVK_Command)
        case .rightControl: keyCode = Int64(kVK_RightControl)
        case .leftControl: keyCode = Int64(kVK_Control)
        case .disabled: keyCode = nil
        }
        return ShortcutConfiguration(
            keyCode: keyCode,
            modifierFlagsRawValue: 0,
            displayName: displayName
        )
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System Default"
        case .light: "Light Mode"
        case .dark: "Dark Mode"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
