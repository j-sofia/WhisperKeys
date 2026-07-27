import Foundation
import WhisperKit

/// Local WhisperKit backend. Audio files and recognized text remain on-device.
///
/// The saved model is installed when the app opens. Normal dictation initializes WhisperKit with
/// `download: false`, so it never turns a dictation into a network request when a model is absent.
actor WhisperKitSpeechRecognizer: LiveSpeechRecognizing {
    private let modelStore: ModelStore
    private var pipeline: WhisperKit?
    private var loadedModel: WhisperModel?
    private var loadingModel: WhisperModel?
    private var liveWhisperKit: WhisperKit?
    private var partialTranscriptionTask: Task<Void, Never>?
    private var livePreviewStartSample = 0
    private var rollingLiveHypothesis = RollingLiveHypothesis()

    /// Keep each preview below Whisper's 30-second decoder window. Every handoff retains a
    /// substantial overlap, which lets `RollingLiveHypothesis` produce a continuous hypothesis
    /// without repeatedly decoding the complete recording.
    private let livePreviewMaximumSamples = WhisperKit.sampleRate * 24
    private let livePreviewAdvanceSamples = WhisperKit.sampleRate * 6

    init(modelStore: ModelStore = ModelStore()) {
        self.modelStore = modelStore
    }

    func transcribe(audioURL: URL, model: WhisperModel) async throws -> String {
        let whisperKit = try await pipeline(for: model, allowingDownload: false)
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
        let results = try await transcribeLongForm(samples, with: whisperKit)
        let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechError.emptyTranscription }
        return text
    }

    /// Starts recording through WhisperKit's 16 kHz audio processor and begins recognizing
    /// snapshots while the user is still speaking. The final pass always uses the complete
    /// captured buffer, so partial hypotheses never affect text that is typed.
    func startLiveTranscription(
        model: WhisperModel,
        onPartialTranscription: @escaping @Sendable (String) -> Void
    ) async throws {
        guard liveWhisperKit == nil else { throw SpeechError.liveTranscriptionInProgress }

        let whisperKit = try await pipeline(for: model, allowingDownload: false)
        resetLivePreviewState()
        try whisperKit.audioProcessor.startRecordingLive(callback: nil)
        liveWhisperKit = whisperKit

        partialTranscriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.publishPartialTranscription(onPartialTranscription)
            }
        }
    }

    /// Stops live capture, waits for any in-flight preview, and makes one final full-buffer
    /// transcription so the caller receives stable, complete text.
    func stopAndFinalizeLiveTranscription() async throws -> String {
        guard let whisperKit = liveWhisperKit else { throw SpeechError.noRecording }

        whisperKit.audioProcessor.stopRecording()
        liveWhisperKit = nil

        let partialTask = partialTranscriptionTask
        partialTranscriptionTask = nil
        partialTask?.cancel()
        await partialTask?.value

        let samples = Array(whisperKit.audioProcessor.audioSamples)
        guard !samples.isEmpty else { throw SpeechError.emptyTranscription }
        guard containsVoice(in: whisperKit.audioProcessor) else {
            throw SpeechError.emptyTranscription
        }
        resetLivePreviewState()
        let results = try await transcribeLongForm(samples, with: whisperKit)
        return try text(from: results)
    }

    func cancelLiveTranscription() async {
        liveWhisperKit?.audioProcessor.stopRecording()
        liveWhisperKit = nil
        partialTranscriptionTask?.cancel()
        partialTranscriptionTask = nil
        resetLivePreviewState()
    }

    func install(
        model: WhisperModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        do {
            let modelFolder = try await download(model: model, progress: progress)
            progress(1)
            _ = try await pipeline(
                for: model,
                allowingDownload: false,
                downloadedModelFolder: modelFolder
            )
        } catch let error as SpeechError {
            throw error
        } catch {
            // WhisperKit's Hub downloader writes resumable `.incomplete` files. If a file
            // move was interrupted, clear only those artifacts and retry once; all completed
            // model files remain cached, so retrying normally downloads just the missing file.
            modelStore.removeIncompleteDownloads()
            let modelFolder = try await download(model: model, progress: progress)
            progress(1)
            _ = try await pipeline(
                for: model,
                allowingDownload: false,
                downloadedModelFolder: modelFolder
            )
        }
    }

    private func download(
        model: WhisperModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(
            variant: model.rawValue,
            downloadBase: modelStore.modelsDirectory,
            progressCallback: { downloadProgress in
                let fraction = downloadProgress.fractionCompleted
                guard fraction.isFinite else { return }
                progress(min(max(fraction, 0), 1))
            }
        )
    }

    private func pipeline(
        for model: WhisperModel,
        allowingDownload: Bool,
        downloadedModelFolder: URL? = nil
    ) async throws -> WhisperKit {
        if let pipeline, loadedModel == model { return pipeline }
        if loadingModel != nil { throw SpeechError.modelInstallationInProgress }

        loadingModel = model
        defer { loadingModel = nil }

        do {
            let config = WhisperKitConfig(
                model: model.rawValue,
                downloadBase: modelStore.modelsDirectory,
                modelFolder: downloadedModelFolder?.path,
                verbose: false,
                prewarm: true,
                load: true,
                download: allowingDownload
            )
            let newPipeline = try await WhisperKit(config)
            pipeline = newPipeline
            loadedModel = model
            return newPipeline
        } catch {
            if let speechError = error as? SpeechError { throw speechError }
            if !allowingDownload { throw SpeechError.modelMissing(model) }
            throw error
        }
    }

    private func publishPartialTranscription(
        _ onPartialTranscription: @escaping @Sendable (String) -> Void
    ) async {
        guard let whisperKit = liveWhisperKit else { return }
        let samples = Array(whisperKit.audioProcessor.audioSamples)
        // Avoid asking Whisper to infer words from a very short clip; those clips are prone to
        // familiar-looking hallucinations such as “thank you.” The UI still receives previews
        // every half second as soon as one second of audio with detected voice is captured.
        guard samples.count >= WhisperKit.sampleRate else { return }
        guard containsVoice(in: whisperKit.audioProcessor) else { return }

        do {
            let previewStart = nextLivePreviewStart(for: samples.count)
            let previewSamples = Array(samples[previewStart...])
            let results = try await whisperKit.transcribe(audioArray: previewSamples)
            let transcription = try text(from: results)
            guard !Task.isCancelled, liveWhisperKit === whisperKit else { return }

            let hypothesis = rollingLiveHypothesis.update(
                transcription,
                windowAdvanced: previewStart > livePreviewStartSample
            )
            livePreviewStartSample = previewStart
            onPartialTranscription(hypothesis)
        } catch {
            // Preview transcription is best-effort. The final pass reports real failures.
        }
    }

    /// Advances in six-second steps instead of moving the window every poll. This leaves at
    /// least 18 seconds of decoded audio on both sides of a normal handoff while guaranteeing
    /// that each preview remains bounded even when decoding takes longer than expected.
    private func nextLivePreviewStart(for sampleCount: Int) -> Int {
        let requiredStart = max(0, sampleCount - livePreviewMaximumSamples)
        guard requiredStart > livePreviewStartSample else { return livePreviewStartSample }

        let distance = requiredStart - livePreviewStartSample
        let steps = (distance + livePreviewAdvanceSamples - 1) / livePreviewAdvanceSamples
        return livePreviewStartSample + steps * livePreviewAdvanceSamples
    }

    private func resetLivePreviewState() {
        livePreviewStartSample = 0
        rollingLiveHypothesis.reset()
    }

    /// Long recordings are split at detected silence before decoding. Decode each chunk
    /// ourselves rather than passing `.vad` to WhisperKit: that API logs and drops a failed
    /// chunk, which can silently truncate the final transcript. A chunk failure now reaches the
    /// caller instead of looking like a successful but incomplete dictation.
    private func transcribeLongForm(
        _ samples: [Float],
        with whisperKit: WhisperKit
    ) async throws -> [TranscriptionResult] {
        guard samples.count > livePreviewMaximumSamples else {
            return try await whisperKit.transcribe(audioArray: samples)
        }

        let chunks = try await VADAudioChunker(windowPadding: 0).chunkAll(
            audioArray: samples,
            maxChunkLength: livePreviewMaximumSamples,
            decodeOptions: nil
        )
        var results: [TranscriptionResult] = []
        results.reserveCapacity(chunks.count)

        for chunk in chunks {
            try Task.checkCancellation()
            results.append(contentsOf: try await whisperKit.transcribe(audioArray: chunk.audioSamples))
        }
        return results
    }

    private func text(from results: [TranscriptionResult]) throws -> String {
        let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechError.emptyTranscription }
        return text
    }

    /// Whisper's decoder can produce common phrases for silence. Relative energy is already
    /// calculated by its live audio processor, so require a clearly non-silent buffer before
    /// treating a preview or final pass as speech.
    private func containsVoice(in audioProcessor: any AudioProcessing) -> Bool {
        audioProcessor.relativeEnergy.contains { $0.isFinite && $0 > 0.3 }
    }
}
