import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    private enum Default {
        static let wordsPerMinute = 0
        static let customWordsPerMinute = 60
        static let keyDownMilliseconds = 1
        static let characterDelayMilliseconds = 5
        static let showInDock = false
    }

    private enum Key {
        static let model = "whisperModel"
        static let wordsPerMinute = "wordsPerMinute"
        static let customWordsPerMinute = "customWordsPerMinute"
        static let keyDownMilliseconds = "keyDownMilliseconds"
        static let characterDelayMilliseconds = "characterDelayMilliseconds"
        static let wordDelayMilliseconds = "wordDelayMilliseconds"
        static let shortcutKey = "shortcutKey"
        static let autoCapitalize = "autoCapitalize"
        static let pressEnter = "pressEnter"
        static let showInDock = "showInDock"
        static let appearance = "appearance"
        static let onboardingCompleted = "onboardingCompleted"
        static let onboardingResumeStep = "onboardingResumeStep"
    }

    private let defaults: UserDefaults

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
    @Published var shortcutKeyID: String { didSet { defaults.set(shortcutKeyID, forKey: Key.shortcutKey) } }
    @Published var autoCapitalizeFirstSentence: Bool { didSet { defaults.set(autoCapitalizeFirstSentence, forKey: Key.autoCapitalize) } }
    @Published var pressEnterAfterTranscription: Bool { didSet { defaults.set(pressEnterAfterTranscription, forKey: Key.pressEnter) } }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        whisperModelID = defaults.string(forKey: Key.model) ?? WhisperModel.tiny.rawValue
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
        shortcutKeyID = defaults.string(forKey: Key.shortcutKey) ?? ShortcutKey.rightOption.rawValue
        autoCapitalizeFirstSentence = defaults.object(forKey: Key.autoCapitalize) as? Bool ?? true
        pressEnterAfterTranscription = defaults.object(forKey: Key.pressEnter) as? Bool ?? false
        showInDock = defaults.object(forKey: Key.showInDock) as? Bool ?? Default.showInDock
        appearanceID = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "")?.rawValue ?? AppAppearance.system.rawValue
        needsOnboarding = !defaults.bool(forKey: Key.onboardingCompleted)
        onboardingResumeStep = defaults.object(forKey: Key.onboardingResumeStep) as? Int ?? 0

        let loginItemStatus = SMAppService.mainApp.status
        startAtLogin = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        startAtLoginRequiresApproval = loginItemStatus == .requiresApproval
        startAtLoginError = nil
    }

    var selectedModel: WhisperModel { WhisperModel(rawValue: whisperModelID) ?? .tiny }
    var shortcutKey: ShortcutKey { ShortcutKey(rawValue: shortcutKeyID) ?? .rightOption }
    var appearance: AppAppearance { AppAppearance(rawValue: appearanceID) ?? .system }
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
        onboardingResumeStep = min(max(step, 0), 5)
        needsOnboarding = true
    }

    /// Starts setup at Permissions when the reset was initiated from Settings.
    func resumeOnboardingAtPermissions() {
        resumeOnboarding(at: 4)
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
