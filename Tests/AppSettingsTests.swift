import XCTest

@testable import WhisperKeys

@MainActor
final class AppSettingsTests: XCTestCase {
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
        XCTAssertEqual(settings.characterDelayMilliseconds, 5)
        XCTAssertFalse(settings.typingConfiguration.isFastest)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertFalse(settings.showInDock)
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
}
