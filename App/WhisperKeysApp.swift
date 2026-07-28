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
        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}
