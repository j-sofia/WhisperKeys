import Foundation

protocol SpeechRecognizing: AnyObject {
    func transcribe(audioURL: URL, model: WhisperModel) async throws -> String
    func install(
        model: WhisperModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

extension SpeechRecognizing {
    func install(model: WhisperModel) async throws {
        try await install(model: model, progress: { _ in })
    }
}

/// An optional live-recognition capability. Keeping it separate preserves the file-based
/// recognizer seam for tests and alternate recognizers.
protocol LiveSpeechRecognizing: SpeechRecognizing {
    /// Selects the input used by the next live dictation. `nil` follows the system default.
    func setInputDeviceID(_ inputDeviceID: UInt32?) async
    /// Supplies normalized microphone amplitudes while the live capture is active. A default
    /// no-op keeps alternate live recognizers and test doubles source-compatible.
    func setLiveAudioLevelHandler(_ handler: (@Sendable (Float) -> Void)?) async
    func startLiveTranscription(
        model: WhisperModel,
        onPartialTranscription: @escaping @Sendable (String) -> Void,
        onPauseDetected: @escaping @Sendable () -> Void
    ) async throws
    /// Starts a new live capture before returning the completed transcript from the previous
    /// segment. The caller can keep listening while it transcribes and types that segment.
    func rolloverLiveTranscription(
        onPartialTranscription: @escaping @Sendable (String) -> Void,
        onPauseDetected: @escaping @Sendable () -> Void
    ) async throws -> String
    func stopAndFinalizeLiveTranscription() async throws -> String
    func cancelLiveTranscription() async
}

extension LiveSpeechRecognizing {
    func setInputDeviceID(_ inputDeviceID: UInt32?) async {}

    func setLiveAudioLevelHandler(_ handler: (@Sendable (Float) -> Void)?) async {}
}

/// An explicit stop can arrive while a silence rollover is decoding the segment that just ended.
/// The rollover owns that segment's final text, so it must complete before the successor capture
/// is stopped and finalized. Otherwise cancelling the rollover loses the first segment entirely.
enum LiveTranscriptionStopSequencer {
    static func finalize(
        after rolloverTask: Task<Void, Never>?,
        using recognizer: any LiveSpeechRecognizing
    ) async throws -> String {
        await rolloverTask?.value
        try Task.checkCancellation()
        return try await recognizer.stopAndFinalizeLiveTranscription()
    }
}
