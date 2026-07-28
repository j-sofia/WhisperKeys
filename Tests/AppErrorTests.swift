import XCTest

@testable import WhisperKeys

final class AppErrorTests: XCTestCase {
    func testMicrophoneFailurePreservesCategoryAndRecovery() {
        let error = AppError.recording(SpeechError.microphoneUnavailable)

        XCTAssertEqual(error, .microphoneUnavailable)
        XCTAssertEqual(error.category, .microphone)
        XCTAssertEqual(error.recoveryActions, [.chooseAnotherMicrophone])
        XCTAssertEqual(error.primaryRecoveryAction?.title, "Choose Another Microphone")
    }

    func testMissingModelPreservesModelAndRetryAction() {
        let error = AppError.recording(SpeechError.modelMissing(.small))

        XCTAssertEqual(error, .modelUnavailable(.small))
        XCTAssertEqual(error.category, .model)
        XCTAssertEqual(error.recoveryActions, [.retryModel])
        XCTAssertTrue(error.localizedDescription.contains("Small"))
    }

    func testTypingPermissionMapsToSettingsRecovery() {
        let error = AppError.typing(TypingError.accessibilityPermissionRequired)

        XCTAssertEqual(error, .accessibilityPermissionRequired)
        XCTAssertEqual(error.category, .permission)
        XCTAssertEqual(error.recoveryActions, [.openAccessibilitySettings])
        XCTAssertEqual(error.primaryRecoveryAction?.title, "Open Settings")
    }

    func testUnknownRecordingFailureRemainsARecoverableTranscriptionFailure() {
        let underlying = NSError(
            domain: "AppErrorTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Decoder stopped unexpectedly."]
        )

        let error = AppError.recording(underlying)

        XCTAssertEqual(error.category, .transcription)
        XCTAssertEqual(error.recoveryActions, [.retryDictation])
        XCTAssertEqual(error.localizedDescription, "Decoder stopped unexpectedly.")
    }
}
