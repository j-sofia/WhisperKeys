import AppKit
import Foundation

@MainActor
final class DictationSession {
    enum LiveSegmentState {
        case ready
        case finalizing(task: Task<Void, Never>?, pendingPause: Bool)
        case typing(batchID: UUID, pendingPause: Bool)

        var finalizationTask: Task<Void, Never>? {
            guard case .finalizing(let task, _) = self else { return nil }
            return task
        }

        var pendingPause: Bool {
            switch self {
            case .ready:
                false
            case .finalizing(_, let pendingPause), .typing(_, let pendingPause):
                pendingPause
            }
        }

        var defersPartials: Bool {
            switch self {
            case .ready: false
            case .finalizing, .typing: true
            }
        }
    }

    let mode: TranscriptionMode
    let targetApplication: NSRunningApplication?

    var startTask: Task<Void, Never>?
    var transcriptionTask: Task<Void, Never>?
    var typingBatchID: UUID?
    var stopWhenRecordingStarts = false
    var liveSegmentState: LiveSegmentState = .ready
    var liveTypedText = ""
    var previousLiveHypothesis = ""
    var reviewFinalizedSegments: [String] = []

    init(mode: TranscriptionMode, targetApplication: NSRunningApplication?) {
        self.mode = mode
        self.targetApplication = targetApplication
    }

    func cancelTasks() {
        startTask?.cancel()
        startTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        liveSegmentState.finalizationTask?.cancel()
        liveSegmentState = .ready
        typingBatchID = nil
    }
}

enum DictationSessionPhase: Equatable {
    case idle
    case starting
    case recording
    case transcribing
    case reviewing
    case typing
}

@MainActor
enum DictationSessionState {
    case idle
    case starting(DictationSession)
    case recording(DictationSession)
    case transcribing(DictationSession)
    case reviewing(DictationSession)
    case typing(DictationSession)

    var phase: DictationSessionPhase {
        switch self {
        case .idle: .idle
        case .starting: .starting
        case .recording: .recording
        case .transcribing: .transcribing
        case .reviewing: .reviewing
        case .typing: .typing
        }
    }

    var session: DictationSession? {
        switch self {
        case .idle:
            nil
        case .starting(let session),
             .recording(let session),
             .transcribing(let session),
             .reviewing(let session),
             .typing(let session):
            session
        }
    }

    var activity: AppActivity {
        switch self {
        case .idle, .starting: .idle
        case .recording: .recording
        case .transcribing: .transcribing
        case .reviewing: .reviewing
        case .typing: .typing
        }
    }
}

struct InvalidDictationSessionTransition: Error, Equatable {
    let from: DictationSessionPhase
    let to: DictationSessionPhase
}

@MainActor
struct DictationSessionStateMachine {
    private(set) var state: DictationSessionState = .idle

    @discardableResult
    mutating func transition(
        to newState: DictationSessionState
    ) -> Result<Void, InvalidDictationSessionTransition> {
        let from = state.phase
        let to = newState.phase
        guard Self.isAllowed(from: from, to: to) else {
            return .failure(InvalidDictationSessionTransition(from: from, to: to))
        }
        guard Self.preservesSessionIdentity(from: state, to: newState) else {
            return .failure(InvalidDictationSessionTransition(from: from, to: to))
        }
        state = newState
        return .success(())
    }

    func isCurrent(_ session: DictationSession, in phases: Set<DictationSessionPhase>) -> Bool {
        state.session === session && phases.contains(state.phase)
    }

    private static func isAllowed(
        from: DictationSessionPhase,
        to: DictationSessionPhase
    ) -> Bool {
        if to == .idle { return true }
        return switch (from, to) {
        case (.idle, .starting),
             (.starting, .recording),
             (.recording, .transcribing),
             (.transcribing, .reviewing),
             (.transcribing, .typing),
             (.reviewing, .typing):
            true
        default:
            false
        }
    }

    private static func preservesSessionIdentity(
        from oldState: DictationSessionState,
        to newState: DictationSessionState
    ) -> Bool {
        guard let oldSession = oldState.session, let newSession = newState.session else {
            return true
        }
        return oldSession === newSession
    }
}
