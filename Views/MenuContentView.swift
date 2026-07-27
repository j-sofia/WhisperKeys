import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var settings: AppSettings

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _settings = ObservedObject(wrappedValue: viewModel.settings)
    }

    var body: some View {
        Group {
            Text(viewModel.activity.displayName)
                .foregroundStyle(statusColor)
                .onAppear { settings.refreshStartAtLoginStatus() }

            Divider()

            Button("Start Dictation") { viewModel.startDictation() }
                .disabled(viewModel.activity == .installingModel || viewModel.activity == .recording)
            Button("Stop Dictation") { viewModel.stopAndTranscribe() }
                .disabled(viewModel.activity != .recording)

            if viewModel.activity == .typing || viewModel.activity == .transcribing {
                Button("Cancel Current Operation") { viewModel.cancelCurrentOperation() }
            }

            Divider()

            Button("Settings…") {
                AppDelegate.presentSettings()
            }

            if settings.shortcutKey != .disabled {
                Text("Double-tap \(settings.shortcutKey.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Start at Login", isOn: startAtLoginBinding)
            Toggle("Show in Dock", isOn: $settings.showInDock)

            Divider()

            Button("Quit WhisperKeys") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .preferredColorScheme(settings.appearance.colorScheme)
    }

    private var statusColor: Color {
        switch viewModel.activity {
        case .error: .red
        case .recording: .red
        case .transcribing, .typing: .orange
        case .installingModel: .primary
        case .idle: .secondary
        }
    }

    private var startAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.startAtLogin },
            set: { settings.setStartAtLogin($0) }
        )
    }
}
