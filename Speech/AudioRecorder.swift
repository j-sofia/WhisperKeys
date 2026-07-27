import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Fallback recorder for recognizers that support only file-based transcription.
/// WhisperKit's live recognizer captures directly through its own 16 kHz audio processor.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let recordingOperationLock = NSRecursiveLock()
    private let recordingStateLock = NSLock()
    private let audioLevelHandlerLock = NSLock()
    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var recordingWriteError: Error?
    private var audioLevelHandler: (@Sendable (Float) -> Void)?

    /// Receives a normalized microphone level for every captured audio buffer. The callback is
    /// invoked from AVAudioEngine's realtime thread, so consumers must hop to their own queue
    /// before updating UI.
    func setAudioLevelHandler(_ handler: (@Sendable (Float) -> Void)?) {
        audioLevelHandlerLock.lock()
        audioLevelHandler = handler
        audioLevelHandlerLock.unlock()
    }

    func start(inputDeviceID: UInt32? = nil) throws -> URL {
        recordingOperationLock.lock()
        defer { recordingOperationLock.unlock() }

        stopAndDiscardIfNeeded()

        let input = engine.inputNode
        if let inputDeviceID {
            try selectInputDevice(inputDeviceID, on: input)
        }
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
        recordingStateLock.lock()
        outputFile = file
        outputURL = url
        recordingWriteError = nil
        recordingStateLock.unlock()

        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.publishAudioLevel(from: buffer)
            self?.writeRecordingBuffer(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            recordingStateLock.lock()
            outputFile = nil
            outputURL = nil
            recordingWriteError = nil
            recordingStateLock.unlock()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    private func selectInputDevice(_ deviceID: UInt32, on inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw SpeechError.microphoneUnavailable
        }

        var selectedDeviceID = AudioDeviceID(deviceID)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw SpeechError.microphoneUnavailable
        }
    }

    private func publishAudioLevel(from buffer: AVAudioPCMBuffer) {
        audioLevelHandlerLock.lock()
        let handler = audioLevelHandler
        audioLevelHandlerLock.unlock()
        guard let handler else { return }

        guard let samples = buffer.floatChannelData?.pointee,
              buffer.frameLength > 0
        else {
            handler(0)
            return
        }

        var sumOfSquares: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let sample = samples[index]
            sumOfSquares += sample * sample
        }
        // RMS represents the energy across the buffer instead of one brief spike. It leaves
        // headroom for louder speech, rather than pinning the preview at full height normally.
        let rootMeanSquare = (sumOfSquares / Float(buffer.frameLength)).squareRoot()
        handler(min(1, rootMeanSquare * 4))
    }

    private func writeRecordingBuffer(_ buffer: AVAudioPCMBuffer) {
        recordingStateLock.lock()
        defer { recordingStateLock.unlock() }

        guard recordingWriteError == nil, let outputFile else { return }

        do {
            try outputFile.write(from: buffer)
        } catch {
            // The tap callback runs on AVAudioEngine's realtime thread, where presenting or
            // throwing is not possible. Preserve the first write failure so stop() can report
            // the recording as unavailable instead of returning a corrupt/partial file URL.
            recordingWriteError = error
        }
    }

    func stop() -> URL? {
        recordingOperationLock.lock()
        defer { recordingOperationLock.unlock() }

        recordingStateLock.lock()
        let hasRecording = outputURL != nil
        recordingStateLock.unlock()

        guard engine.isRunning || hasRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        recordingStateLock.lock()
        let url = outputURL
        let writeError = recordingWriteError
        outputFile = nil
        outputURL = nil
        recordingWriteError = nil
        recordingStateLock.unlock()

        if writeError != nil, let url {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func stopAndDiscardIfNeeded() {
        if let oldURL = stop() {
            try? FileManager.default.removeItem(at: oldURL)
        }
    }

    private func makeRecordingURL() throws -> URL {
        let localDataStore = LocalDataStore()
        let folder = localDataStore.recordingsDirectory
        try localDataStore.createDirectory(at: folder)
        return folder.appendingPathComponent("dictation-\(UUID().uuidString).wav")
    }
}
