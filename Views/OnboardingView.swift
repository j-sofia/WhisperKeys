import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var permissions: PermissionManager
    private let onFinish: () -> Void

    @State private var step: OnboardingStep
    @State private var modelDownloadRequested = false
    @State private var modelWasInstalled = false
    @State private var practiceText = ""
    @State private var showPermissionRestartConfirmation = false
    @State private var permissionRestartError: String?
    @FocusState private var practiceFieldIsFocused: Bool

    init(viewModel: AppViewModel, onFinish: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onFinish = onFinish
        _settings = ObservedObject(wrappedValue: viewModel.settings)
        _permissions = ObservedObject(wrappedValue: viewModel.permissions)
        _step = State(
            initialValue: OnboardingStep(rawValue: viewModel.settings.onboardingResumeStep) ?? .welcome
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            onboardingPage
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 38)
            .padding(.vertical, 30)

            Divider()
            footer
        }
        .frame(width: 700, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            permissions.refresh()
            settings.refreshStartAtLoginStatus()
            settings.resumeOnboarding(at: step.rawValue)
            if step == .model {
                modelDownloadRequested = viewModel.activity == .installingModel
                modelWasInstalled = viewModel.activity == .idle && viewModel.modelInstallationProgress == 1
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .onChange(of: settings.shortcutKeyID) { _, _ in
            viewModel.restartShortcutMonitor()
        }
        .onChange(of: settings.whisperModelID) { _, _ in
            modelWasInstalled = false
        }
        .onChange(of: viewModel.activity) { _, newActivity in
            guard step == .model, modelDownloadRequested else { return }
            switch newActivity {
            case .idle:
                modelDownloadRequested = false
                modelWasInstalled = true
            case .error:
                modelDownloadRequested = false
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
            settings.refreshStartAtLoginStatus()
            viewModel.restartShortcutMonitor()
        }
        .confirmationDialog(
            "Restart and recheck permissions?",
            isPresented: $showPermissionRestartConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restart & Recheck") {
                restartAndRecheckPermissions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("WhisperKeys will restart, re-detect its current permission status, and return to this exact page. It will not change any macOS permission settings.")
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                BrandAppIcon(size: 40, cornerRadius: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text("WhisperKeys")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Setup assistant")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 7) {
                    Image(systemName: step.symbolName)
                        .font(.caption.weight(.bold))
                    Text("\(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.primary.opacity(0.055), in: Capsule())
            }

            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { page in
                    Capsule()
                        .fill(page.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.11))
                        .frame(height: 5)
                        .animation(.easeInOut(duration: 0.25), value: step)
                }
            }
        }
        .padding(.horizontal, 38)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var onboardingPage: some View {
        switch step {
        case .welcome:
            welcomePage
        case .model:
            modelPage
        case .shortcut:
            shortcutPage
        case .preferences:
            preferencesPage
        case .permissions:
            permissionsPage
        case .tryIt:
            tryItPage
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 20) {
                BrandAppIcon(size: 78, cornerRadius: 19)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Dictation that stays on your Mac.")
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                    Text("A quiet, local-first way to turn your voice into text wherever you work.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("WhisperKeys listens only when you ask it to, transcribes with a local Whisper model, and types into the app you already have open.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                FeatureRow(icon: "lock.fill", title: "Private by design", detail: "Your recordings and recognized text stay on this Mac.")
                FeatureRow(icon: "keyboard", title: "Works where you work", detail: "Dictate into native apps, remote desktops, and focused text fields.")
                FeatureRow(icon: "waveform", title: "Always within reach", detail: "Use the menu bar or a double-tap shortcut when inspiration strikes.")
            }
            .padding(10)
            .background(onboardingSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var modelPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingPageTitle("Choose a local model", eyebrow: "PERFORMANCE & PRIVACY")
            Text("The model is downloaded once, then dictation runs locally. Tiny is a good first choice; you can change models later in Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Whisper model", selection: $settings.whisperModelID) {
                ForEach(WhisperModel.allCases) { model in
                    Text(model.displayName).tag(model.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(viewModel.activity == .installingModel)

            if viewModel.activity == .installingModel {
                VStack(alignment: .leading, spacing: 9) {
                    ProgressView(value: viewModel.modelInstallationProgress ?? 0)
                    Text(viewModel.modelInstallationStatus ?? "Preparing download…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if modelWasInstalled {
                Label("\(settings.selectedModel.displayName) is ready to use.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                .padding(16)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if case .error(let message) = viewModel.activity {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                .padding(16)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var shortcutPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingPageTitle("Choose your shortcut", eyebrow: "ACTIVATION")
            Text("Double-tap the selected modifier key to start or stop dictation. The original key press is never blocked.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Global shortcut", selection: $settings.shortcutKeyID) {
                ForEach(ShortcutKey.allCases) { key in
                    Text(key.displayName).tag(key.rawValue)
                }
            }
            .pickerStyle(.radioGroup)

            if settings.shortcutKey == .disabled {
                Label("You can always start dictation from the menu bar.", systemImage: "menubar.rectangle")
                    .foregroundStyle(.secondary)
            } else {
                Label("Input Monitoring is needed for the global shortcut. You can approve it in the next step.", systemImage: "hand.raised.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var preferencesPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingPageTitle("Make it feel like yours", eyebrow: "PREFERENCES")
            Text("These choices can be changed at any time in Settings.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                Toggle("Start WhisperKeys when I log in", isOn: startAtLoginBinding)
                if settings.startAtLoginRequiresApproval {
                    HStack {
                        Text("macOS needs you to approve this in Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { settings.openLoginItemsSettings() }
                    }
                }
                if let error = settings.startAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Divider()
                Toggle("Show WhisperKeys in the Dock", isOn: $settings.showInDock)
                Text("When enabled, the Dock menu includes Quit while the app is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                Picker("Appearance", selection: $settings.appearanceID) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(18)
            .background(onboardingSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingPageTitle("Allow WhisperKeys to work", eyebrow: "PERMISSIONS")
            Text("Permissions are required only for the features that use them. You can continue now and approve any of them later in Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PermissionSetupRow(
                title: "Microphone",
                detail: "Lets WhisperKeys hear your dictation.",
                state: permissions.microphone,
                actionTitle: permissions.microphone == .granted ? nil : "Allow"
            ) {
                Task {
                    if !(await permissions.requestMicrophone()) {
                        permissions.openMicrophonePrivacySettings()
                    }
                }
            }

            PermissionSetupRow(
                title: "Accessibility",
                detail: "Lets WhisperKeys type the transcription into the focused app.",
                state: permissions.accessibility,
                actionTitle: permissions.accessibility == .granted ? nil : "Request Access"
            ) {
                permissions.requestAccessibility()
            }

            Text("For typing permission, if WhisperKeys is not listed in Accessibility, click the + button and add WhisperKeys from your Applications folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            if settings.shortcutKey != .disabled {
                PermissionSetupRow(
                    title: "Input Monitoring",
                    detail: "Lets WhisperKeys notice your global shortcut.",
                state: permissions.inputMonitoring,
                actionTitle: permissions.inputMonitoring == .granted ? nil : "Open Settings"
            ) {
                permissions.openInputMonitoringPrivacySettings()
            }
            }

            HStack {
                Button("Restart & Recheck Permissions…") {
                    showPermissionRestartConfirmation = true
                }
                Spacer()
                if let permissionRestartError {
                    Text(permissionRestartError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text("Use this after changing a permission in System Settings. WhisperKeys restarts and re-detects the current status without resetting anything.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tryItPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingPageTitle("Try it out", eyebrow: "ONE LAST THING")
            Text(practiceInstructions)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("PRACTICE PAD")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                TextEditor(text: $practiceText)
                    .font(.body)
                    .focused($practiceFieldIsFocused)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 165)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(10)
            .background(onboardingSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 12) {
                Button {
                    togglePracticeDictation()
                } label: {
                    Label(
                        viewModel.activity == .recording ? "Stop & Transcribe" : "Start Dictation",
                        systemImage: viewModel.activity == .recording ? "stop.fill" : "mic.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.activity == .installingModel || viewModel.activity == .transcribing || viewModel.activity == .typing)

                if viewModel.activity == .installingModel {
                    Text("Please wait while the model loads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .error(let message) = viewModel.activity {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("Tip: leave this field focused before you stop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { move(to: step.previous) }
                .disabled(step == .welcome || viewModel.activity == .installingModel)
            Spacer()

            switch step {
            case .model:
                Button(modelWasInstalled ? "Continue" : "Download Model") {
                    if modelWasInstalled {
                        move(to: .shortcut)
                    } else {
                        modelDownloadRequested = true
                        viewModel.installSelectedModel()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.activity == .installingModel)
            case .tryIt:
                Button("Finish Setup") { finishOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.activity == .recording || viewModel.activity == .transcribing || viewModel.activity == .typing)
            default:
                Button("Continue") { move(to: step.next) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 38)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial)
    }

    private var startAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.startAtLogin },
            set: { settings.setStartAtLogin($0) }
        )
    }

    private var practiceInstructions: String {
        if settings.shortcutKey == .disabled {
            return "Click in this box, then use Start Dictation and speak. WhisperKeys will type the transcription here just as it will in your other apps."
        }
        return "Click in this box, then double-tap \(settings.shortcutKey.displayName) to start dictation. Double-tap it again when you finish speaking; WhisperKeys will type the transcription here just as it will in your other apps."
    }

    private func move(to newStep: OnboardingStep) {
        settings.resumeOnboarding(at: newStep.rawValue)
        withAnimation(.easeInOut(duration: 0.18)) {
            step = newStep
        }
    }

    private func togglePracticeDictation() {
        if viewModel.activity == .recording {
            viewModel.stopAndTranscribe()
            return
        }

        practiceFieldIsFocused = true
        DispatchQueue.main.async {
            viewModel.startDictation()
        }
    }

    private func restartAndRecheckPermissions() {
        settings.resumeOnboarding(at: step.rawValue)
        AppRestarter.restart { error in
            if let error {
                permissionRestartError = "WhisperKeys could not restart. \(error.localizedDescription)"
            }
        }
    }

    private func finishOnboarding() {
        viewModel.restartShortcutMonitor()
        settings.completeOnboarding()
        onFinish()
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case model
    case shortcut
    case preferences
    case permissions
    case tryIt

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .model: "Local model"
        case .shortcut: "Shortcut"
        case .preferences: "Preferences"
        case .permissions: "Permissions"
        case .tryIt: "Try it out"
        }
    }

    var symbolName: String {
        switch self {
        case .welcome: "waveform"
        case .model: "arrow.down.circle"
        case .shortcut: "keyboard"
        case .preferences: "slider.horizontal.3"
        case .permissions: "lock.shield"
        case .tryIt: "text.cursor"
        }
    }

    var previous: Self { Self(rawValue: rawValue - 1) ?? self }
    var next: Self { Self(rawValue: rawValue + 1) ?? self }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }
}

private struct PermissionSetupRow: View {
    let title: String
    let detail: String
    let state: PermissionState
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(state == .granted ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
            } else {
                Text(state.rawValue)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(14)
        .background(onboardingSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct OnboardingPageTitle: View {
    let title: String
    let eyebrow: String

    init(_ title: String, eyebrow: String) {
        self.title = title
        self.eyebrow = eyebrow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tint)
                .tracking(1)
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
        }
    }
}

private var onboardingSurface: Color {
    Color(nsColor: .controlBackgroundColor).opacity(0.74)
}
