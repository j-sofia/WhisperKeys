import AppKit
import SwiftUI
import WhisperKit

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var settings: AppSettings
    private var permissions: any PermissionManaging { viewModel.permissions }
    @Environment(\.dismiss) private var dismiss
    @State private var permissionResetError: String?
    @State private var permissionRestartError: String?
    @State private var showPermissionResetConfirmation = false
    @State private var showPermissionRestartPrompt = false
    @State private var permissionChangeNeedsRestart = false
    @State private var showOnboardingResetConfirmation = false
    @State private var showDeleteAllDataConfirmation = false
    @State private var deleteAllDataError: String?
    @State private var inputDevices: [AudioDevice] = []
    private let onDismiss: (() -> Void)?

    init(viewModel: AppViewModel, onDismiss: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
        _settings = ObservedObject(wrappedValue: viewModel.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
            Section("Local Whisper model") {
                Text("Choose the balance of speed and accuracy that fits your Mac. The recommendation uses only its processor and memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ModelSelectionCards(
                    selection: $settings.whisperModelID,
                    isDisabled: viewModel.activity == .installingModel
                )
                HStack {
                    Button("Install \(settings.selectedModel.displayName)") { viewModel.installSelectedModel() }
                        .disabled(viewModel.activity == .installingModel)
                    Button("Show Models Folder") { viewModel.openModelsFolder() }
                }
                if viewModel.activity == .installingModel {
                    VStack(alignment: .leading, spacing: 9) {
                        ProgressView(value: viewModel.modelInstallationProgress ?? 0)
                        Text(viewModel.modelInstallationStatus ?? "Preparing download…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                Text("The saved model is installed when WhisperKeys opens. Dictation runs with downloads disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Picker("Input device", selection: $settings.inputDeviceID) {
                    Text("System Default").tag(Optional<UInt32>.none)
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                    if let inputDeviceID = settings.inputDeviceID,
                       !inputDevices.contains(where: { $0.id == inputDeviceID }) {
                        Text("Unavailable device (\(inputDeviceID))").tag(Optional(inputDeviceID))
                    }
                }
                HStack {
                    Text("System Default follows macOS Sound settings. A selected device is used for every new dictation until you change it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh Devices", action: refreshInputDevices)
                }
                Text("Changes apply when you next start dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Typing") {
                Picker("Transcription mode", selection: $settings.transcriptionModeID) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Live mode types confirmed words while you speak. Review before typing shows the transcript in the waveform popup and types it only after you accept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Typing speed", selection: fastestTypingSpeedBinding) {
                    Text("Fastest").tag(true)
                    Text("Custom").tag(false)
                }
                .pickerStyle(.radioGroup)

                if !settings.usesFastestTypingSpeed {
                    LabeledContent("Words per minute") {
                        HStack(spacing: 6) {
                            TextField("", value: customWordsPerMinuteBinding, format: .number)
                                .labelsHidden()
                                .accessibilityLabel("Words per minute")
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Text("WPM")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Enter a value from 1 to 200 WPM.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Stepper("Key down → key up: \(settings.keyDownMilliseconds) ms", value: $settings.keyDownMilliseconds, in: 0...250)
                Stepper("Extra delay between characters: \(settings.characterDelayMilliseconds) ms", value: $settings.characterDelayMilliseconds, in: 0...5_000, step: 1)
                Stepper("Extra delay between words: \(settings.wordDelayMilliseconds) ms", value: $settings.wordDelayMilliseconds, in: 0...5_000, step: 5)
                Toggle("Auto-capitalize first sentence", isOn: $settings.autoCapitalizeFirstSentence)
                Toggle("Press Enter after transcription", isOn: $settings.pressEnterAfterTranscription)
                Text("Windows App sessions use the same key-event path as macOS, paced to ensure remote Windows receives every key-up event. In Windows App, choose Connections → Keyboard Mode → Unicode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Activation") {
                Picker("Activation style", selection: $settings.shortcutActivationModeID) {
                    ForEach(ShortcutActivationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.shortcutActivationMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ShortcutRecorder(settings: settings)

                if settings.shortcutActivationMode == .doublePress {
                    Stepper(
                        "Double-press speed: \(settings.shortcutDoublePressIntervalMilliseconds) ms",
                        value: $settings.shortcutDoublePressIntervalMilliseconds,
                        in: 200...800,
                        step: 25
                    )
                }
                Text(settings.shortcutActionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Application") {
                Toggle("Start at Login", isOn: startAtLoginBinding)
                if settings.startAtLoginRequiresApproval {
                    HStack {
                        Text("Approve WhisperKeys in Login Items to finish enabling it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { settings.openLoginItemsSettings() }
                    }
                }
                if let startAtLoginError = settings.startAtLoginError {
                    Text(startAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Show in Dock", isOn: $settings.showInDock)
                Text("Shows WhisperKeys in the Dock while it is running, where its Dock menu also provides Quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Appearance", selection: $settings.appearanceID) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Link(destination: URL(string: "https://streamelements.com/qdqd/tip")!) {
                    Label("Buy the developer a coffee", systemImage: "cup.and.saucer.fill")
                }
                .buttonStyle(.bordered)
            }

            Section("Permissions") {
                PermissionRow(title: "Microphone", state: permissions.microphone) {
                    Task {
                        if !(await permissions.requestMicrophone()) {
                            permissions.openMicrophonePrivacySettings()
                        }
                    }
                }
                PermissionRow(title: "Accessibility (typing)", state: permissions.accessibility) {
                    permissions.requestAccessibility()
                }
                PermissionRow(title: "Input Monitoring (shortcut)", state: permissions.inputMonitoring) {
                    permissions.openInputMonitoringPrivacySettings()
                }
                Button("Refresh Permission Settings") {
                    showPermissionResetConfirmation = true
                }
                Text("Clears only WhisperKeys’ Accessibility and Input Monitoring decisions, then restarts directly into the permissions setup step. It never runs during normal app launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if permissionChangeNeedsRestart {
                    Button("Restart WhisperKeys Now") { restartWhisperKeys() }
                }
                if let permissionResetError {
                    Text(permissionResetError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let permissionRestartError {
                    Text(permissionRestartError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Advanced") {
                Button("Reset Onboarding…") {
                    showOnboardingResetConfirmation = true
                }
                Text("Shows the first-run setup again. Your current model, shortcut, and preferences are kept until you change them during setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Delete All Local Data…", role: .destructive) {
                    showDeleteAllDataConfirmation = true
                }
                .disabled(!canDeleteAllLocalData)
                Text("Deletes downloaded models, temporary recordings, and all WhisperKeys preferences, then quits the app. macOS permissions and Login Items are not changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let deleteAllDataError {
                    Text(deleteAllDataError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            }
            .formStyle(.grouped)
            .frame(maxHeight: .infinity)
            .padding([.top, .horizontal])

            Divider()

            HStack {
                Spacer()
                Button("Quit WhisperKeys", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding()
        }
        .frame(width: 610, height: 620)
        .onAppear {
            settings.refreshStartAtLoginStatus()
            refreshInputDevices()
        }
        .onChange(of: settings.shortcutConfiguration) { _, _ in viewModel.restartShortcutMonitor() }
        .onChange(of: settings.shortcutActivationModeID) { _, _ in viewModel.restartShortcutMonitor() }
        .onChange(of: settings.shortcutDoublePressIntervalMilliseconds) { _, _ in viewModel.restartShortcutMonitor() }
        .onChange(of: permissions.accessibility) { oldState, newState in
            handlePermissionChange(from: oldState, to: newState)
        }
        .onChange(of: permissions.inputMonitoring) { oldState, newState in
            handlePermissionChange(from: oldState, to: newState)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // A user commonly changes an app setting in System Settings, then returns here.
            settings.refreshStartAtLoginStatus()
            permissions.refresh()
            refreshInputDevices()
        }
        .confirmationDialog(
            "Refresh Permission Settings?",
            isPresented: $showPermissionResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Refresh & Restart", role: .destructive) { refreshPermissionSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only WhisperKeys’ saved decisions, then restarts setup at Permissions. You will need to approve both permissions again in System Settings.")
        }
        .confirmationDialog(
            "Reset Onboarding?",
            isPresented: $showOnboardingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Onboarding") { resetOnboarding() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This opens the setup flow again without changing your current preferences.")
        }
        .confirmationDialog(
            "Delete All Local Data?",
            isPresented: $showDeleteAllDataConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete & Quit", role: .destructive) { deleteAllLocalData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All downloaded models, temporary recordings, and preferences will be removed from this Mac. WhisperKeys will quit and start fresh the next time you open it. This cannot be undone.")
        }
        .alert("Restart WhisperKeys?", isPresented: $showPermissionRestartPrompt) {
            Button("Restart Now") { restartWhisperKeys() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Restart the app to ensure the changed Accessibility or Input Monitoring permission is applied.")
        }
    }

    private var fastestTypingSpeedBinding: Binding<Bool> {
        Binding(
            get: { settings.usesFastestTypingSpeed },
            set: { settings.setUsesFastestTypingSpeed($0) }
        )
    }

    private var customWordsPerMinuteBinding: Binding<Int> {
        Binding(
            get: { settings.customWordsPerMinute },
            set: { settings.setCustomWordsPerMinute($0) }
        )
    }

    private var startAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.startAtLogin },
            set: { settings.setStartAtLogin($0) }
        )
    }

    private func refreshInputDevices() {
        inputDevices = AudioProcessor.getAudioDevices().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var canDeleteAllLocalData: Bool {
        switch viewModel.activity {
        case .idle, .error:
            true
        case .recording, .transcribing, .reviewing, .typing, .installingModel:
            false
        }
    }

    private func handlePermissionChange(from oldState: PermissionState, to newState: PermissionState) {
        guard oldState != newState else { return }
        permissionChangeNeedsRestart = true
        showPermissionRestartPrompt = true
    }

    private func refreshPermissionSettings() {
        do {
            try permissions.resetAccessibilityAndInputMonitoring()
            settings.resumeOnboardingAtPermissions()
            viewModel.restartShortcutMonitor()
            restartWhisperKeys()
        } catch {
            permissionResetError = error.localizedDescription
        }
    }

    private func restartWhisperKeys() {
        AppRestarter.restart { error in
            if let error {
                permissionRestartError = "WhisperKeys could not restart. \(error.localizedDescription)"
            }
        }
    }

    private func resetOnboarding() {
        settings.resetOnboarding()
        AppDelegate.presentOnboarding()
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private func deleteAllLocalData() {
        do {
            try viewModel.deleteAllLocalData()
            viewModel.shutdown()
            NSApplication.shared.terminate(nil)
        } catch {
            deleteAllDataError = "WhisperKeys could not delete all local data. \(error.localizedDescription)"
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let state: PermissionState
    let request: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(state.rawValue)
                .foregroundStyle(state == .granted ? .green : (state == .restricted ? .red : .secondary))
            if state != .granted && state != .restricted {
                Button(state == .notDetermined ? "Grant" : "Open Settings", action: request)
            }
        }
    }
}
