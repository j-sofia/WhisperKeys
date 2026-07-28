import CoreGraphics
import Foundation

/// Serial, cancellable producer of individual key-down/key-up pairs.
/// All waits happen on `typingQueue`, never on the SwiftUI main thread.
final class TypingEngine {
    var onTyped: ((TypingLogEntry) -> Void)?
    var onTypedBatch: (([TypingLogEntry]) -> Void)?
    var onCompleted: ((UUID) -> Void)?
    var onError: ((Error) -> Void)?

    private let typingQueue = DispatchQueue(label: "com.whisperkeys.typing", qos: .userInteractive)
    private let mapper: KeyboardMapper
    private let emitter: KeyEventEmitting
    private let focusedApplicationTypingConfigurationAdjuster: FocusedApplicationTypingConfigurationAdjusting
    private let clock: any ClockProviding
    private let stateLock = NSLock()
    private var activeBatch: TypingBatch?

    init(
        mapper: KeyboardMapper = KeyboardMapper(),
        emitter: KeyEventEmitting = CGEventKeyEmitter(),
        focusedApplicationTypingConfigurationAdjuster: FocusedApplicationTypingConfigurationAdjusting = WindowsAppTypingConfigurationAdjuster(),
        clock: any ClockProviding = SystemClock.shared
    ) {
        self.mapper = mapper
        self.emitter = emitter
        self.focusedApplicationTypingConfigurationAdjuster = focusedApplicationTypingConfigurationAdjuster
        self.clock = clock
    }

    /// Replaces any text still waiting to be typed and begins a new batch.
    ///
    /// Use `enqueue` for live transcription updates: each update must be sent only after all
    /// earlier updates have reached the focused app.
    @discardableResult
    func type(_ text: String, configuration: TypingConfiguration) -> UUID? {
        cancel()
        return enqueue(text, configuration: configuration)
    }

    /// Adds text to the current batch without interrupting keystrokes that are already queued.
    /// Returns the batch identifier so callers can distinguish its completion from an older run.
    @discardableResult
    func enqueue(_ text: String, configuration: TypingConfiguration) -> UUID? {
        let preparedEmission: (strokes: [KeyStroke], configuration: TypingConfiguration)
        do {
            let prepare = { () throws -> (strokes: [KeyStroke], configuration: TypingConfiguration) in
                let strokes = try self.mapper.map(text)
                let effectiveConfiguration = self.focusedApplicationTypingConfigurationAdjuster
                    .configuration(forFocusedApplication: configuration)
                return (strokes, effectiveConfiguration)
            }
            if Thread.isMainThread {
                preparedEmission = try prepare()
            } else {
                preparedEmission = try DispatchQueue.main.sync(execute: prepare)
            }
        } catch {
            // A mapping failure means this transcription can no longer be emitted safely; do
            // not let any already queued fragment continue typing after reporting the error.
            cancel()
            DispatchQueue.main.async { [weak self] in self?.onError?(error) }
            return nil
        }

        let emitter = self.emitter
        stateLock.lock()
        let batch: TypingBatch
        if let activeBatch, !activeBatch.token.isCancelled {
            batch = activeBatch
        } else {
            batch = TypingBatch()
            activeBatch = batch
        }
        batch.pendingOperations += 1
        stateLock.unlock()

        typingQueue.async { [weak self] in
            self?.perform(
                text: text,
                strokes: preparedEmission.strokes,
                configuration: preparedEmission.configuration,
                batch: batch,
                emitter: emitter
            )
        }
        return batch.id
    }

    /// Cancellation is observed between every small sleep slice. If a key is already down,
    /// its key-up event is still emitted before stopping so modifiers/keys cannot get stuck.
    func cancel() {
        stateLock.lock()
        activeBatch?.token.cancel()
        activeBatch = nil
        stateLock.unlock()
    }

    private func perform(
        text: String,
        strokes: [KeyStroke],
        configuration: TypingConfiguration,
        batch: TypingBatch,
        emitter: KeyEventEmitting
    ) {
        defer { finishOperation(in: batch) }

        let started = clock.now
        let token = batch.token
        guard !token.isCancelled, isCurrent(batch) else { return }
        guard !strokes.isEmpty else {
            return
        }
        let fastestMode = configuration.isFastest

        do {
            try emitter.beginTyping()
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onError?(error) }
            cancel(batch)
            return
        }

        for (character, stroke) in zip(text, strokes) {
            if token.isCancelled { return }

            do {
                if fastestMode {
                    try emitter.emitImmediateKeyStroke(stroke)
                } else {
                    try emitter.emitKeyDown(stroke)
                    wait(milliseconds: configuration.keyDownMilliseconds, token: token)
                    // Always release a key after it has been pressed, even after cancellation.
                    try emitter.emitKeyUp(stroke)
                    let entry = logEntry(for: character, stroke: stroke, started: started)
                    DispatchQueue.main.async { [weak self] in self?.onTyped?(entry) }
                }

                if token.isCancelled { return }
                if !fastestMode {
                    let baseGap = max(0, configuration.characterIntervalMilliseconds - Double(configuration.keyDownMilliseconds))
                    let wordGap = character.isWhitespace ? configuration.extraWordDelayMilliseconds : 0
                    wait(
                        milliseconds: Int(baseGap) + configuration.extraCharacterDelayMilliseconds + wordGap,
                        token: token
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.onError?(error) }
                cancel(batch)
                return
            }
        }

        guard !token.isCancelled, isCurrent(batch) else { return }
        if fastestMode, onTypedBatch != nil {
            let entries = fastLogEntries(text: text, strokes: strokes, started: started)
            if !entries.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.onTypedBatch?(entries) }
            }
        }
    }

    /// Debug bookkeeping happens after the fast event loop, never between key posts.
    private func fastLogEntries(text: String, strokes: [KeyStroke], started: Date) -> [TypingLogEntry] {
        let firstLoggedIndex = max(0, strokes.count - 1_000)
        return zip(text, strokes).enumerated().compactMap { index, pair in
            guard index >= firstLoggedIndex else { return nil }
            return logEntry(for: pair.0, stroke: pair.1, started: started)
        }
    }

    private func logEntry(for character: Character, stroke: KeyStroke, started: Date) -> TypingLogEntry {
        TypingLogEntry(
            character: printable(character),
            keyCode: stroke.keyCode,
            modifierDescription: modifierDescription(stroke.modifiers),
            elapsedMilliseconds: clock.now.timeIntervalSince(started) * 1_000,
            timestamp: clock.now
        )
    }

    private func wait(milliseconds: Int, token: CancellationToken) {
        var remaining = max(0, milliseconds)
        while remaining > 0 && !token.isCancelled {
            let slice = min(remaining, 2)
            clock.sleep(for: Double(slice) / 1_000)
            remaining -= slice
        }
    }

    private func isCurrent(_ batch: TypingBatch) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeBatch === batch
    }

    private func finishOperation(in batch: TypingBatch) {
        let completed: Bool
        stateLock.lock()
        batch.pendingOperations -= 1
        completed = activeBatch === batch
            && !batch.token.isCancelled
            && batch.pendingOperations == 0
        if completed { activeBatch = nil }
        stateLock.unlock()

        if completed {
            DispatchQueue.main.async { [weak self] in self?.onCompleted?(batch.id) }
        }
    }

    private func cancel(_ batch: TypingBatch) {
        stateLock.lock()
        batch.token.cancel()
        if activeBatch === batch { activeBatch = nil }
        stateLock.unlock()
    }

    private func printable(_ character: Character) -> String {
        switch character {
        case "\n", "\r": "↵"
        case "\t": "⇥"
        case "\u{08}", "\u{7F}": "⌫"
        case " ": "␠"
        default: String(character)
        }
    }

    private func modifierDescription(_ flags: CGEventFlags) -> String {
        var names: [String] = []
        if flags.contains(.maskShift) { names.append("Shift") }
        if flags.contains(.maskAlternate) { names.append("Option") }
        if flags.contains(.maskControl) { names.append("Control") }
        if flags.contains(.maskCommand) { names.append("Command") }
        return names.isEmpty ? "—" : names.joined(separator: "+")
    }
}

private final class TypingBatch {
    let id = UUID()
    let token = CancellationToken()
    var pendingOperations = 0
}

private final class CancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
