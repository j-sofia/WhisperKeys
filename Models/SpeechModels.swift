import Foundation

enum SpeechError: LocalizedError {
    case microphoneUnavailable
    case noRecording
    case modelMissing(WhisperModel)
    case modelInstallationInProgress
    case liveTranscriptionInProgress
    case emptyTranscription
    case whisperKitUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            "No microphone input is available."
        case .noRecording:
            "There is no recording to transcribe."
        case .modelMissing(let model):
            "The \(model.displayName) Whisper model is not ready yet. Please wait while the model loads."
        case .modelInstallationInProgress:
            "A Whisper model installation is already in progress. Please wait for it to finish."
        case .liveTranscriptionInProgress:
            "A live transcription is already in progress."
        case .emptyTranscription:
            "No speech was recognized."
        case .whisperKitUnavailable:
            "WhisperKit is not linked. Resolve the Swift package in Xcode and rebuild."
        }
    }
}
