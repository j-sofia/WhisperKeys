import Foundation
import WhisperKit

/// Local WhisperKit backend. Audio files and recognized text remain on-device.
///
/// The saved model is installed when the app opens. Normal dictation initializes WhisperKit with
/// `download: false`, so it never turns a dictation into a network request when a model is absent.
actor WhisperKitSpeechRecognizer: LiveSpeechRecognizing {
    private let modelStore: any ModelStoring
    private var pipeline: WhisperKit?
    private var loadedModel: WhisperModel?
    private var loadingModel: WhisperModel?
    private var liveWhisperKit: WhisperKit?
    private var partialTranscriptionTask: Task<Void, Never>?
    private var inputDeviceID: UInt32?
    private var liveInputDeviceID: UInt32?
    private var liveAudioLevelHandler: (@Sendable (Float) -> Void)?
    private var liveAudioLevelGeneration = 0
    private var livePreviewStartSample = 0
    private var rollingLiveHypothesis = RollingLiveHypothesis()
    private var livePauseDetector = LivePauseDetector()
    private var areLivePreviewsSuspended = false

    /// Keep each preview below Whisper's 30-second decoder window. Every handoff retains a
    /// substantial overlap, which lets `RollingLiveHypothesis` produce a continuous hypothesis
    /// without repeatedly decoding the complete recording.
    private let livePreviewMaximumSamples = WhisperKit.sampleRate * 24
    private let livePreviewAdvanceSamples = WhisperKit.sampleRate * 6

    init(modelStore: any ModelStoring = ModelStore()) {
        self.modelStore = modelStore
    }

    func setLiveAudioLevelHandler(_ handler: (@Sendable (Float) -> Void)?) async {
        liveAudioLevelHandler = handler
    }

    func setInputDeviceID(_ inputDeviceID: UInt32?) async {
        self.inputDeviceID = inputDeviceID
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
    /// snapshots while the user is still speaking. Each completed segment later receives a full
    /// buffer pass to reconcile its live preview.
    func startLiveTranscription(
        model: WhisperModel,
        onPartialTranscription: @escaping @Sendable (String) -> Void,
        onPauseDetected: @escaping @Sendable () -> Void
    ) async throws {
        guard liveWhisperKit == nil else { throw SpeechError.liveTranscriptionInProgress }

        let whisperKit = try await pipeline(for: model, allowingDownload: false)
        areLivePreviewsSuspended = false
        liveInputDeviceID = inputDeviceID
        try startLiveCapture(
            with: whisperKit,
            inputDeviceID: liveInputDeviceID,
            onPartialTranscription: onPartialTranscription,
            onPauseDetected: onPauseDetected
        )
    }

    /// Ends the current segment on a detected pause, starts recording its successor immediately,
    /// then returns the finalized text for the segment that ended. Recording and final decoding
    /// can therefore overlap without losing the user's first words after the pause.
    func rolloverLiveTranscription(
        onPartialTranscription: @escaping @Sendable (String) -> Void,
        onPauseDetected: @escaping @Sendable () -> Void
    ) async throws -> String {
        guard let whisperKit = liveWhisperKit else { throw SpeechError.noRecording }

        whisperKit.audioProcessor.stopRecording()
        let previousPartialTask = partialTranscriptionTask
        partialTranscriptionTask = nil
        previousPartialTask?.cancel()
        let capturedSamples = Array(whisperKit.audioProcessor.audioSamples)
        guard !capturedSamples.isEmpty,
              containsSpeech(in: capturedSamples, audioProcessor: whisperKit.audioProcessor)
        else {
            areLivePreviewsSuspended = false
            try startLiveCapture(
                with: whisperKit,
                inputDeviceID: liveInputDeviceID,
                onPartialTranscription: onPartialTranscription,
                onPauseDetected: onPauseDetected
            )
            throw SpeechError.emptyTranscription
        }
        let samples = capturedSamples

        // Start capture before waiting for the cancelled preview to return. The next segment is
        // therefore recorded immediately, while its preview decoding stays suspended until this
        // segment's final decoder pass is complete.
        areLivePreviewsSuspended = true
        try startLiveCapture(
            with: whisperKit,
            inputDeviceID: liveInputDeviceID,
            onPartialTranscription: onPartialTranscription,
            onPauseDetected: onPauseDetected
        )
        await previousPartialTask?.value
        defer { areLivePreviewsSuspended = false }
        let results = try await transcribeLongForm(samples, with: whisperKit)
        return try text(from: results)
    }

    /// Stops live capture, waits for any in-flight preview, and makes one final full-buffer
    /// transcription so the caller receives stable, complete text.
    func stopAndFinalizeLiveTranscription() async throws -> String {
        guard let whisperKit = liveWhisperKit else { throw SpeechError.noRecording }

        whisperKit.audioProcessor.stopRecording()
        liveWhisperKit = nil
        liveInputDeviceID = nil
        stopLiveAudioLevelPublishing()

        await stopPartialTranscriptionTask()
        areLivePreviewsSuspended = false

        let capturedSamples = Array(whisperKit.audioProcessor.audioSamples)
        guard !capturedSamples.isEmpty else { throw SpeechError.emptyTranscription }
        guard containsSpeech(in: capturedSamples, audioProcessor: whisperKit.audioProcessor) else {
            throw SpeechError.emptyTranscription
        }
        let samples = capturedSamples
        resetLivePreviewState()
        let results = try await transcribeLongForm(samples, with: whisperKit)
        return try text(from: results)
    }

    func cancelLiveTranscription() async {
        liveWhisperKit?.audioProcessor.stopRecording()
        liveWhisperKit = nil
        liveInputDeviceID = nil
        stopLiveAudioLevelPublishing()
        await stopPartialTranscriptionTask()
        areLivePreviewsSuspended = false
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
        _ onPartialTranscription: @escaping @Sendable (String) -> Void,
        onPauseDetected: @escaping @Sendable () -> Void
    ) async {
        guard let whisperKit = liveWhisperKit else { return }
        let samples = Array(whisperKit.audioProcessor.audioSamples)
        // Avoid asking Whisper to infer words from a very short clip; those clips are prone to
        // familiar-looking hallucinations such as “thank you.” The UI still receives previews
        // every half second as soon as one second of audio with detected voice is captured.
        guard samples.count >= WhisperKit.sampleRate else { return }
        // Checking the complete recording here makes every later silent poll look like speech
        // once the user has talked at least once. Decode previews only while the recent audio is
        // active; otherwise Whisper can repeatedly supply familiar silence phrases such as
        // “thank you.” The final pass still checks the complete capture below.
        guard containsRecentVoice(in: whisperKit.audioProcessor) else {
            if livePauseDetector.registerSilence() {
                onPauseDetected()
            }
            return
        }
        livePauseDetector.registerVoice()
        guard !areLivePreviewsSuspended else { return }

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
        livePauseDetector.reset()
    }

    private func startLiveCapture(
        with whisperKit: WhisperKit,
        inputDeviceID: UInt32?,
        onPartialTranscription: @escaping @Sendable (String) -> Void,
        onPauseDetected: @escaping @Sendable () -> Void
    ) throws {
        resetLivePreviewState()
        liveAudioLevelGeneration &+= 1
        let audioLevelGeneration = liveAudioLevelGeneration
        try whisperKit.audioProcessor.startRecordingLive(inputDeviceID: inputDeviceID) { [weak self] samples in
            Task { [weak self] in
                await self?.publishLiveAudioLevels(
                    from: samples,
                    generation: audioLevelGeneration
                )
            }
        }
        liveWhisperKit = whisperKit
        partialTranscriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.publishPartialTranscription(
                    onPartialTranscription,
                    onPauseDetected: onPauseDetected
                )
            }
        }
    }

    private func stopPartialTranscriptionTask() async {
        let partialTask = partialTranscriptionTask
        partialTranscriptionTask = nil
        partialTask?.cancel()
        await partialTask?.value
    }

    private func stopLiveAudioLevelPublishing() {
        liveAudioLevelGeneration &+= 1
        liveAudioLevelHandler = nil
    }

    /// WhisperKit supplies 100 ms audio buffers. Split each in two and release its levels 50 ms
    /// apart, which makes the visualizer scroll at 20 fps without changing transcription's VAD
    /// timing or opening a second microphone capture.
    private func publishLiveAudioLevels(from samples: [Float], generation: Int) {
        guard generation == liveAudioLevelGeneration,
              liveWhisperKit != nil,
              let handler = liveAudioLevelHandler,
              !samples.isEmpty
        else {
            return
        }

        let half = max(1, samples.count / 2)
        for index in 0..<2 {
            let start = index * half
            guard start < samples.count else { break }
            let end = index == 1 ? samples.count : min(start + half, samples.count)
            let level = waveformLevel(in: samples[start..<end])

            guard index > 0 else {
                handler(level)
                continue
            }
            Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
                await self?.emitLiveAudioLevel(level, generation: generation)
            }
        }
    }

    private func emitLiveAudioLevel(_ level: Float, generation: Int) {
        guard generation == liveAudioLevelGeneration,
              let handler = liveAudioLevelHandler
        else {
            return
        }
        handler(level)
    }

    /// RMS reflects the sustained strength of each 50 ms audio slice. A brief waveform spike
    /// can no longer make ordinary speech look like it has reached the preview's ceiling.
    private func waveformLevel(in samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        let rootMeanSquare = (sumOfSquares / Float(samples.count)).squareRoot()
        return min(1, rootMeanSquare * 4)
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

    /// Relative energy is excellent for suppressing repeated preview decodes, but a very short
    /// recording may stop between its rolling-baseline updates. Fall back to WhisperKit's
    /// raw-sample VAD so an early stop does not report “no speech recognized.”
    private func containsSpeech(in samples: [Float], audioProcessor: any AudioProcessing) -> Bool {
        containsVoice(in: audioProcessor)
            || EnergyVAD(energyThreshold: 0.02).voiceActivity(in: samples).contains(true)
    }

    private func containsRecentVoice(in audioProcessor: any AudioProcessing) -> Bool {
        LiveVoiceActivity.containsRecentVoice(in: audioProcessor.relativeEnergy)
    }
}

/// Each live relative-energy reading covers one 100 ms input buffer. Preview transcription only
/// needs a short, recent slice; final transcription separately considers the entire recording.
enum LiveVoiceActivity {
    static func containsRecentVoice(
        in relativeEnergy: [Float],
        recentFrameCount: Int = 20,
        threshold: Float = 0.3
    ) -> Bool {
        relativeEnergy.suffix(max(1, recentFrameCount)).contains {
            $0.isFinite && $0 > threshold
        }
    }

}

/// Reports a single pause after live speech becomes silent. It ignores startup silence and stays
/// quiet until voice resumes, so one pause produces one segment rollover.
struct LivePauseDetector {
    private var hasDetectedVoice = false
    private var hasReportedPause = false

    mutating func registerVoice() {
        hasDetectedVoice = true
        hasReportedPause = false
    }

    mutating func registerSilence() -> Bool {
        guard hasDetectedVoice, !hasReportedPause else { return false }
        hasReportedPause = true
        return true
    }

    mutating func reset() {
        hasDetectedVoice = false
        hasReportedPause = false
    }
}
