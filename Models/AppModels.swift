import Foundation
import SwiftUI

enum AppActivity: Equatable {
    case idle
    case recording
    case transcribing
    case typing
    case installingModel
    case error(String)

    var displayName: String {
        switch self {
        case .idle: "Ready"
        case .recording: "Listening…"
        case .transcribing: "Transcribing locally…"
        case .typing: "Typing…"
        case .installingModel: "Installing local model…"
        case .error(let message): message
        }
    }
}

enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny = "tiny"
    case small = "small"
    case base = "base"
    case largeV3 = "large-v3-v20240930_626MB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: "Tiny (fastest)"
        case .small: "Small"
        case .base: "Base"
        case .largeV3: "Large v3 (most accurate)"
        }
    }
}

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
