import Carbon.HIToolbox
import XCTest

@testable import WhisperKeys

@MainActor
final class AppSettingsTests: XCTestCase {
    func testShortcutKeyUsesItsMatchingMenuBarSymbol() {
        XCTAssertEqual(ShortcutKey.rightOption.symbolName, "option")
        XCTAssertEqual(ShortcutKey.leftOption.symbolName, "option")
        XCTAssertEqual(ShortcutKey.rightCommand.symbolName, "command")
        XCTAssertEqual(ShortcutKey.leftCommand.symbolName, "command")
        XCTAssertEqual(ShortcutKey.rightControl.symbolName, "control")
        XCTAssertEqual(ShortcutKey.leftControl.symbolName, "control")
        XCTAssertEqual(ShortcutKey.disabled.symbolName, "menubar.rectangle")
    }

    func testFirstRunDefaultsToDoublePressRightOption() {
        let suiteName = "AppSettingsTests.defaultShortcut"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.shortcutConfiguration, .defaultRightOption)
        XCTAssertEqual(settings.shortcutActivationMode, .doublePress)
        XCTAssertEqual(settings.shortcutDoublePressIntervalMilliseconds, 350)
    }

    func testRecordedHoldShortcutPersists() {
        let suiteName = "AppSettingsTests.recordedShortcut"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.setShortcut(keyCode: 40, modifierFlagsRawValue: 1 << 20, displayName: "⌘K")
        settings.shortcutActivationModeID = ShortcutActivationMode.hold.rawValue
        settings.shortcutDoublePressIntervalMilliseconds = 500

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.shortcutConfiguration.keyCode, 40)
        XCTAssertEqual(restored.shortcutConfiguration.modifierFlagsRawValue, 1 << 20)
        XCTAssertEqual(restored.shortcutConfiguration.displayName, "⌘K")
        XCTAssertEqual(restored.shortcutActivationMode, .hold)
        XCTAssertEqual(restored.shortcutDoublePressIntervalMilliseconds, 500)
    }

    func testLegacyModifierShortcutMigratesToRecordedShortcut() {
        let suiteName = "AppSettingsTests.legacyShortcut"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ShortcutKey.leftCommand.rawValue, forKey: "shortcutKey")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.shortcutConfiguration.keyCode, Int64(kVK_Command))
        XCTAssertEqual(settings.shortcutConfiguration.displayName, "Left Command")
        XCTAssertEqual(settings.shortcutActivationMode, .doublePress)
    }

    func testFirstRunDefaultsUseFastestTypingAndHideTheDockIcon() {
        let suiteName = "AppSettingsTests.firstRunDefaults"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.wordsPerMinute, 0)
        XCTAssertEqual(settings.customWordsPerMinute, 60)
        XCTAssertTrue(settings.usesFastestTypingSpeed)
        XCTAssertEqual(settings.keyDownMilliseconds, 1)
        XCTAssertEqual(settings.characterDelayMilliseconds, 2)
        XCTAssertFalse(settings.typingConfiguration.isFastest)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertFalse(settings.showInDock)
        XCTAssertEqual(settings.transcriptionMode, .live)
    }

    func testAppearanceSelectionPersists() {
        let suiteName = "AppSettingsTests.appearance"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.appearanceID = AppAppearance.dark.rawValue

        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(AppSettings(defaults: defaults).appearance, .dark)

        settings.appearanceID = AppAppearance.system.rawValue

        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(AppSettings(defaults: defaults).appearance, .system)
    }

    func testCustomTypingSpeedIsRetainedWhenFastestIsSelected() {
        let suiteName = "AppSettingsTests.typingSpeedSelection"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        settings.setCustomWordsPerMinute(125)
        XCTAssertEqual(settings.wordsPerMinute, 125)
        XCTAssertEqual(settings.customWordsPerMinute, 125)
        XCTAssertFalse(settings.usesFastestTypingSpeed)

        settings.setUsesFastestTypingSpeed(true)
        XCTAssertEqual(settings.wordsPerMinute, 0)
        XCTAssertTrue(settings.usesFastestTypingSpeed)

        settings.setUsesFastestTypingSpeed(false)
        XCTAssertEqual(settings.wordsPerMinute, 125)
        XCTAssertEqual(settings.customWordsPerMinute, 125)
    }

    func testReviewBeforeTypingSelectionPersists() {
        let suiteName = "AppSettingsTests.transcriptionMode"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.transcriptionModeID = TranscriptionMode.reviewBeforeTyping.rawValue

        XCTAssertEqual(settings.transcriptionMode, .reviewBeforeTyping)
        XCTAssertEqual(AppSettings(defaults: defaults).transcriptionMode, .reviewBeforeTyping)
    }

    func testInputDeviceSelectionPersistsAndCanReturnToSystemDefault() {
        let suiteName = "AppSettingsTests.inputDevice"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.inputDeviceID)

        settings.inputDeviceID = 123
        XCTAssertEqual(AppSettings(defaults: defaults).inputDeviceID, 123)

        settings.inputDeviceID = nil
        XCTAssertNil(AppSettings(defaults: defaults).inputDeviceID)
    }

    func testInProgressOnboardingSkipsRemovedPreferencesPage() {
        let suiteName = "AppSettingsTests.onboardingMigration"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for (oldStep, expectedNewStep) in [(3, 3), (4, 3), (5, 4)] {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(oldStep, forKey: "onboardingResumeStep")

            let settings = AppSettings(defaults: defaults)

            XCTAssertEqual(settings.onboardingResumeStep, expectedNewStep)
            XCTAssertEqual(defaults.integer(forKey: "onboardingFlowVersion"), 2)
        }
    }

    func testRemovingStoredValuesClearsTheAppDefaultsDomain() {
        let suiteName = "AppSettingsTests.deleteAllLocalData"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults, defaultsDomainName: suiteName)
        settings.appearanceID = AppAppearance.dark.rawValue
        settings.completeOnboarding()
        settings.removeAllStoredValues()

        XCTAssertNil(defaults.object(forKey: "appearance"))
        XCTAssertNil(defaults.object(forKey: "onboardingCompleted"))
    }

    func testRemovingLocalDataRemovesOnlyTheWhisperKeysSupportDirectory() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperKeysTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let dataStore = LocalDataStore(applicationSupportDirectory: temporaryDirectory)
        try dataStore.createDirectory(at: dataStore.modelsDirectory)
        try dataStore.createDirectory(at: dataStore.recordingsDirectory)
        try Data("model".utf8).write(to: dataStore.modelsDirectory.appendingPathComponent("model.bin"))
        try Data("recording".utf8).write(to: dataStore.recordingsDirectory.appendingPathComponent("dictation.wav"))

        let unrelatedFile = temporaryDirectory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelatedFile)

        try dataStore.removeAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dataStore.dataDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    func testModelRecommendationScalesWithMacMemoryAndProcessor() {
        let gigabyte = UInt64(1_073_741_824)

        XCTAssertEqual(
            MacHardwareProfile(isAppleSilicon: true, memoryBytes: 8 * gigabyte, activeProcessorCount: 8).recommendedModel,
            .base
        )
        XCTAssertEqual(
            MacHardwareProfile(isAppleSilicon: true, memoryBytes: 16 * gigabyte, activeProcessorCount: 10).recommendedModel,
            .base
        )
        XCTAssertEqual(
            MacHardwareProfile(isAppleSilicon: true, memoryBytes: 24 * gigabyte, activeProcessorCount: 10).recommendedModel,
            .small
        )
        XCTAssertEqual(
            MacHardwareProfile(isAppleSilicon: true, memoryBytes: 32 * gigabyte, activeProcessorCount: 12).recommendedModel,
            .largeV3
        )
        XCTAssertEqual(
            MacHardwareProfile(isAppleSilicon: false, memoryBytes: 8 * gigabyte, activeProcessorCount: 4).recommendedModel,
            .tiny
        )
    }
}
