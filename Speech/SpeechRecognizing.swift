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
    func startLiveTranscription(
        model: WhisperModel,
        onPartialTranscription: @escaping @Sendable (String) -> Void
    ) async throws
    func stopAndFinalizeLiveTranscription() async throws -> String
    func cancelLiveTranscription() async
}
