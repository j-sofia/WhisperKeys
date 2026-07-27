import XCTest

@testable import WhisperKeys

final class LiveVoiceActivityTests: XCTestCase {
    func testRecentVoiceIgnoresSpeechThatEndedBeforeTheRecentWindow() {
        let energy = Array(repeating: Float(0.8), count: 20)
            + Array(repeating: Float(0.05), count: 20)

        XCTAssertFalse(LiveVoiceActivity.containsRecentVoice(in: energy))
    }

    func testRecentVoiceAcceptsSpeechInsideTheRecentWindow() {
        let energy = Array(repeating: Float(0.05), count: 19) + [Float(0.8)]

        XCTAssertTrue(LiveVoiceActivity.containsRecentVoice(in: energy))
    }

    func testPauseDetectorReportsOnlyOnePauseUntilVoiceResumes() {
        var detector = LivePauseDetector()

        XCTAssertFalse(detector.registerSilence())
        detector.registerVoice()
        XCTAssertTrue(detector.registerSilence())
        XCTAssertFalse(detector.registerSilence())

        detector.registerVoice()
        XCTAssertTrue(detector.registerSilence())
    }
}
