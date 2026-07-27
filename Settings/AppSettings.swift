import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    private enum Default {
        static let wordsPerMinute = 0
        static let customWordsPerMinute = 60
        static let keyDownMilliseconds = 1
        static let characterDelayMilliseconds = 2
        static let showInDock = false
    }

    private enum Key {
        static let onboardingFlowVersion = "onboardingFlowVersion"
        static let model = "whisperModel"
        static let wordsPerMinute = "wordsPerMinute"
        static let customWordsPerMinute = "customWordsPerMinute"
        static let keyDownMilliseconds = "keyDownMilliseconds"
        static let characterDelayMilliseconds = "characterDelayMilliseconds"
        static let wordDelayMilliseconds = "wordDelayMilliseconds"
        /// The old modifier-only shortcut setting. It is read once to migrate existing users.
        static let shortcutKey = "shortcutKey"
        static let shortcutKeyCode = "shortcutKeyCode"
        static let shortcutModifierFlags = "shortcutModifierFlags"
        static let shortcutDisplayName = "shortcutDisplayName"
        static let shortcutActivationMode = "shortcutActivationMode"
        static let shortcutDoublePressInterval = "shortcutDoublePressInterval"
        static let autoCapitalize = "autoCapitalize"
        static let pressEnter = "pressEnter"
        static let transcriptionMode = "transcriptionMode"
        static let inputDeviceID = "inputDeviceID"
        static let showInDock = "showInDock"
        static let appearance = "appearance"
        static let onboardingCompleted = "onboardingCompleted"
        static let onboardingResumeStep = "onboardingResumeStep"
    }

    private let defaults: UserDefaults
    private let defaultsDomainName: String

    @Published var whisperModelID: String { didSet { defaults.set(whisperModelID, forKey: Key.model) } }
    @Published var wordsPerMinute: Int {
        didSet {
            let normalized = min(max(wordsPerMinute, 0), 200)
            if wordsPerMinute != normalized {
                wordsPerMinute = normalized
                return
            }
            defaults.set(wordsPerMinute, forKey: Key.wordsPerMinute)
            if wordsPerMinute > 0, customWordsPerMinute != wordsPerMinute {
                customWordsPerMinute = wordsPerMinute
            }
        }
    }
    private(set) var customWordsPerMinute: Int {
        didSet { defaults.set(customWordsPerMinute, forKey: Key.customWordsPerMinute) }
    }
    @Published var keyDownMilliseconds: Int { didSet { defaults.set(keyDownMilliseconds, forKey: Key.keyDownMilliseconds) } }
    @Published var characterDelayMilliseconds: Int { didSet { defaults.set(characterDelayMilliseconds, forKey: Key.characterDelayMilliseconds) } }
    @Published var wordDelayMilliseconds: Int { didSet { defaults.set(wordDelayMilliseconds, forKey: Key.wordDelayMilliseconds) } }
    @Published var shortcutConfiguration: ShortcutConfiguration {
        didSet {
            if let keyCode = shortcutConfiguration.keyCode {
                defaults.set(keyCode, forKey: Key.shortcutKeyCode)
            } else {
                defaults.removeObject(forKey: Key.shortcutKeyCode)
            }
            defaults.set(NSNumber(value: shortcutConfiguration.modifierFlagsRawValue), forKey: Key.shortcutModifierFlags)
            defaults.set(shortcutConfiguration.displayName, forKey: Key.shortcutDisplayName)
        }
    }
    @Published var shortcutActivationModeID: String {
        didSet { defaults.set(shortcutActivationModeID, forKey: Key.shortcutActivationMode) }
    }
    @Published var shortcutDoublePressIntervalMilliseconds: Int {
        didSet {
            let normalized = min(max(shortcutDoublePressIntervalMilliseconds, 200), 800)
            if shortcutDoublePressIntervalMilliseconds != normalized {
                shortcutDoublePressIntervalMilliseconds = normalized
                return
            }
            defaults.set(shortcutDoublePressIntervalMilliseconds, forKey: Key.shortcutDoublePressInterval)
        }
    }
    @Published var autoCapitalizeFirstSentence: Bool { didSet { defaults.set(autoCapitalizeFirstSentence, forKey: Key.autoCapitalize) } }
    @Published var pressEnterAfterTranscription: Bool { didSet { defaults.set(pressEnterAfterTranscription, forKey: Key.pressEnter) } }
    @Published var transcriptionModeID: String { didSet { defaults.set(transcriptionModeID, forKey: Key.transcriptionMode) } }
    /// `nil` follows the Mac's current default input. A concrete ID keeps dictation on that device.
    @Published var inputDeviceID: UInt32? {
        didSet {
            guard let inputDeviceID else {
                defaults.removeObject(forKey: Key.inputDeviceID)
                return
            }
            defaults.set(NSNumber(value: inputDeviceID), forKey: Key.inputDeviceID)
        }
    }
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: Key.showInDock) } }
    @Published var appearanceID: String { didSet { defaults.set(appearanceID, forKey: Key.appearance) } }
    @Published private(set) var needsOnboarding: Bool {
        didSet { defaults.set(!needsOnboarding, forKey: Key.onboardingCompleted) }
    }
    @Published private(set) var onboardingResumeStep: Int {
        didSet { defaults.set(onboardingResumeStep, forKey: Key.onboardingResumeStep) }
    }
    @Published private(set) var startAtLogin: Bool
    @Published private(set) var startAtLoginRequiresApproval: Bool
    @Published private(set) var startAtLoginError: String?

    init(
        defaults: UserDefaults = .standard,
        defaultsDomainName: String = Bundle.main.bundleIdentifier ?? "com.j-sof.WhisperKeys"
    ) {
        self.defaults = defaults
        self.defaultsDomainName = defaultsDomainName
        // Keep an existing choice intact. On a new installation, start with the
        // conservative recommendation calculated from this Mac's local hardware.
        whisperModelID = defaults.string(forKey: Key.model) ?? MacHardwareProfile.current.recommendedModel.rawValue
        let savedWordsPerMinute = defaults.object(forKey: Key.wordsPerMinute) as? Int
        let savedKeyDownMilliseconds = defaults.object(forKey: Key.keyDownMilliseconds) as? Int
        let savedCharacterDelayMilliseconds = defaults.object(forKey: Key.characterDelayMilliseconds) as? Int
        let savedWordDelayMilliseconds = defaults.object(forKey: Key.wordDelayMilliseconds) as? Int
        let hasLegacyTypingDefaults = savedWordsPerMinute == 60
            && savedKeyDownMilliseconds == 8
            && savedCharacterDelayMilliseconds == 0
            && savedWordDelayMilliseconds == 0

        let restoredWordsPerMinute = hasLegacyTypingDefaults
            ? Default.wordsPerMinute
            : min(max(savedWordsPerMinute ?? Default.wordsPerMinute, 0), 200)
        wordsPerMinute = restoredWordsPerMinute
        customWordsPerMinute = min(
            max(
                defaults.object(forKey: Key.customWordsPerMinute) as? Int
                    ?? (restoredWordsPerMinute > 0 ? restoredWordsPerMinute : Default.customWordsPerMinute),
                1
            ),
            200
        )
        keyDownMilliseconds = hasLegacyTypingDefaults ? 0 : (savedKeyDownMilliseconds ?? Default.keyDownMilliseconds)
        characterDelayMilliseconds = savedCharacterDelayMilliseconds ?? Default.characterDelayMilliseconds
        wordDelayMilliseconds = savedWordDelayMilliseconds ?? 0
        let hasSavedShortcutConfiguration = defaults.object(forKey: Key.shortcutKeyCode) != nil
            || defaults.object(forKey: Key.shortcutDisplayName) != nil
        let savedShortcutKeyCode = (defaults.object(forKey: Key.shortcutKeyCode) as? NSNumber)?.int64Value
        let legacyShortcut = ShortcutKey(rawValue: defaults.string(forKey: Key.shortcutKey) ?? "")
        let migratedShortcut = legacyShortcut?.shortcutConfiguration ?? .defaultRightOption
        shortcutConfiguration = ShortcutConfiguration(
            keyCode: hasSavedShortcutConfiguration ? savedShortcutKeyCode : migratedShortcut.keyCode,
            modifierFlagsRawValue: (defaults.object(forKey: Key.shortcutModifierFlags) as? NSNumber)?.uint64Value
                ?? migratedShortcut.modifierFlagsRawValue,
            displayName: defaults.string(forKey: Key.shortcutDisplayName)
                ?? (hasSavedShortcutConfiguration ? "Disabled" : migratedShortcut.displayName)
        )
        shortcutActivationModeID = ShortcutActivationMode(
            rawValue: defaults.string(forKey: Key.shortcutActivationMode) ?? ""
        )?.rawValue ?? ShortcutActivationMode.doublePress.rawValue
        shortcutDoublePressIntervalMilliseconds = min(
            max(defaults.object(forKey: Key.shortcutDoublePressInterval) as? Int ?? 350, 200),
            800
        )
        autoCapitalizeFirstSentence = defaults.object(forKey: Key.autoCapitalize) as? Bool ?? true
        pressEnterAfterTranscription = defaults.object(forKey: Key.pressEnter) as? Bool ?? false
        transcriptionModeID = TranscriptionMode(rawValue: defaults.string(forKey: Key.transcriptionMode) ?? "")?.rawValue
            ?? TranscriptionMode.live.rawValue
        let savedInputDeviceID = (defaults.object(forKey: Key.inputDeviceID) as? NSNumber)?.uint32Value
        inputDeviceID = savedInputDeviceID == 0 ? nil : savedInputDeviceID
        showInDock = defaults.object(forKey: Key.showInDock) as? Bool ?? Default.showInDock
        appearanceID = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "")?.rawValue ?? AppAppearance.system.rawValue
        needsOnboarding = !defaults.bool(forKey: Key.onboardingCompleted)
        let savedOnboardingStep = defaults.object(forKey: Key.onboardingResumeStep) as? Int ?? 0
        let savedOnboardingFlowVersion = defaults.integer(forKey: Key.onboardingFlowVersion)
        onboardingResumeStep = Self.migrateOnboardingStep(
            savedOnboardingStep,
            fromFlowVersion: savedOnboardingFlowVersion
        )
        defaults.set(Self.currentOnboardingFlowVersion, forKey: Key.onboardingFlowVersion)

        let loginItemStatus = SMAppService.mainApp.status
        startAtLogin = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        startAtLoginRequiresApproval = loginItemStatus == .requiresApproval
        startAtLoginError = nil
    }

    var selectedModel: WhisperModel { WhisperModel(rawValue: whisperModelID) ?? .tiny }
    var shortcutActivationMode: ShortcutActivationMode {
        ShortcutActivationMode(rawValue: shortcutActivationModeID) ?? .doublePress
    }
    var shortcutIsEnabled: Bool { shortcutConfiguration.isEnabled }
    var shortcutActionDescription: String {
        guard shortcutIsEnabled else { return "Use the menu bar to start and stop dictation." }
        switch shortcutActivationMode {
        case .singlePress:
            return "Press \(shortcutConfiguration.displayName) to start or stop dictation."
        case .doublePress:
            return "Double-press \(shortcutConfiguration.displayName) to start or stop dictation."
        case .hold:
            return "Hold \(shortcutConfiguration.displayName) to dictate, then release to transcribe."
        }
    }
    var appearance: AppAppearance { AppAppearance(rawValue: appearanceID) ?? .system }
    var transcriptionMode: TranscriptionMode { TranscriptionMode(rawValue: transcriptionModeID) ?? .live }
    var usesFastestTypingSpeed: Bool { wordsPerMinute == 0 }

    var typingConfiguration: TypingConfiguration {
        TypingConfiguration(
            wordsPerMinute: wordsPerMinute,
            keyDownMilliseconds: keyDownMilliseconds,
            extraCharacterDelayMilliseconds: characterDelayMilliseconds,
            extraWordDelayMilliseconds: wordDelayMilliseconds
        )
    }

    func setUsesFastestTypingSpeed(_ usesFastestTypingSpeed: Bool) {
        wordsPerMinute = usesFastestTypingSpeed ? 0 : customWordsPerMinute
    }

    func setCustomWordsPerMinute(_ wordsPerMinute: Int) {
        let normalized = min(max(wordsPerMinute, 1), 200)
        customWordsPerMinute = normalized
        self.wordsPerMinute = normalized
    }

    func setShortcut(keyCode: Int64, modifierFlagsRawValue: UInt64, displayName: String) {
        shortcutConfiguration = ShortcutConfiguration(
            keyCode: keyCode,
            modifierFlagsRawValue: modifierFlagsRawValue,
            displayName: displayName
        )
    }

    func disableShortcut() {
        shortcutConfiguration = ShortcutConfiguration(
            keyCode: nil,
            modifierFlagsRawValue: 0,
            displayName: "Disabled"
        )
    }

    /// Updates the app's Login Items registration. The system, rather than UserDefaults,
    /// is the source of truth because users can also change this setting in System Settings.
    func setStartAtLogin(_ enabled: Bool) {
        guard enabled != startAtLogin else { return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshStartAtLoginStatus()
        } catch {
            updateStartAtLoginStatus(clearError: false)
            startAtLoginError = "WhisperKeys could not update Start at Login. \(error.localizedDescription)"
        }
    }

    func refreshStartAtLoginStatus() {
        updateStartAtLoginStatus(clearError: true)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Clears only values owned by WhisperKeys' UserDefaults domain. The app exits immediately
    /// afterward, so a future launch reads its normal first-run defaults without rewriting them.
    func removeAllStoredValues() {
        defaults.removePersistentDomain(forName: defaultsDomainName)
        defaults.synchronize()
    }

    /// Onboarding is intentionally opt-in after first completion; Settings is the only place
    /// that starts it again for an existing installation.
    func resetOnboarding() {
        onboardingResumeStep = 0
        needsOnboarding = true
    }

    func completeOnboarding() {
        onboardingResumeStep = 0
        needsOnboarding = false
    }

    /// Preserves the exact setup page so an app relaunch never makes the user repeat steps.
    func resumeOnboarding(at step: Int) {
        onboardingResumeStep = min(max(step, 0), 4)
        needsOnboarding = true
    }

    /// Starts setup at Permissions when the reset was initiated from Settings.
    func resumeOnboardingAtPermissions() {
        resumeOnboarding(at: 3)
    }

    private static let currentOnboardingFlowVersion = 2

    private static func migrateOnboardingStep(_ step: Int, fromFlowVersion version: Int) -> Int {
        guard version < currentOnboardingFlowVersion else {
            return min(max(step, 0), 4)
        }

        // Version 1 included a Preferences page between Shortcut and Permissions.
        // Resume that page, and the later pages, at their nearest equivalent.
        return switch step {
        case 0...2: step
        case 3, 4: 3
        default: 4
        }
    }

    private func updateStartAtLoginStatus(clearError: Bool) {
        let loginItemStatus = SMAppService.mainApp.status
        startAtLogin = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        startAtLoginRequiresApproval = loginItemStatus == .requiresApproval
        if clearError {
            startAtLoginError = nil
        }
    }
}
