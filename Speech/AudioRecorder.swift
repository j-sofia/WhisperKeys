import AVFoundation
import Foundation

/// Fallback recorder for recognizers that support only file-based transcription.
/// WhisperKit's live recognizer captures directly through its own 16 kHz audio processor.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private var outputURL: URL?

    func start() throws -> URL {
        stopAndDiscardIfNeeded()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechError.microphoneUnavailable
        }

        let url = try makeRecordingURL()
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        outputFile = file
        outputURL = url

        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            do {
                try self?.outputFile?.write(from: buffer)
            } catch {
                // A later stop/transcribe reports an unusable recording. AVAudioEngine's
                // tap callback cannot safely present UI from this realtime audio thread.
            }
        }
        engine.prepare()
        try engine.start()
        return url
    }

    func stop() -> URL? {
        guard engine.isRunning || outputURL != nil else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let url = outputURL
        outputFile = nil
        outputURL = nil
        return url
    }

    private func stopAndDiscardIfNeeded() {
        if let oldURL = stop() {
            try? FileManager.default.removeItem(at: oldURL)
        }
    }

    private func makeRecordingURL() throws -> URL {
        let folder = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("WhisperKeys/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("dictation-\(UUID().uuidString).wav")
    }
}
