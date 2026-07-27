import Combine
import Foundation

@MainActor
final class DebugLogStore: ObservableObject {
    @Published private(set) var recognizedText = ""
    @Published private(set) var typedEvents: [TypingLogEntry] = []
    @Published private(set) var lastError: String?

    func setRecognized(_ text: String) {
        recognizedText = text
        lastError = nil
    }

    func append(_ event: TypingLogEntry) {
        typedEvents.append(event)
        if typedEvents.count > 1_000 { typedEvents.removeFirst(typedEvents.count - 1_000) }
    }

    func append(_ events: [TypingLogEntry]) {
        typedEvents.append(contentsOf: events)
        if typedEvents.count > 1_000 { typedEvents.removeFirst(typedEvents.count - 1_000) }
    }

    func setError(_ error: Error) {
        lastError = error.localizedDescription
    }

    func clear() {
        recognizedText = ""
        typedEvents = []
        lastError = nil
    }
}
