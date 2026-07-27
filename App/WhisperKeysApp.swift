import SwiftUI

@main
struct WhisperKeysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: AppViewModel

    init() {
        let viewModel = AppViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        AppRuntime.viewModel = viewModel
        viewModel.configure()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(viewModel: viewModel)
                .task {
                    appDelegate.configure(viewModel: viewModel)
                }
        } label: {
            Label("WhisperKeys", systemImage: menuIcon)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }

    private var menuIcon: String {
        switch viewModel.activity {
        case .recording: "record.circle.fill"
        case .transcribing, .typing, .installingModel: "ellipsis.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .idle: "waveform"
        }
    }
}
