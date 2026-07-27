import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var settings: AppSettings
    private let onStartDictation: () -> Void
    @State private var isStatusAnimating = false

    init(viewModel: AppViewModel, onStartDictation: (() -> Void)? = nil) {
        self.viewModel = viewModel
        _settings = ObservedObject(wrappedValue: viewModel.settings)
        self.onStartDictation = onStartDictation ?? { viewModel.startDictation() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .padding(.vertical, 10)

            primaryAction

            if viewModel.activity == .recording,
               !viewModel.debugLog.recognizedText.isEmpty {
                liveTranscript
                    .padding(.top, 10)
            }

            if viewModel.activity == .installingModel {
                installationProgress
                    .padding(.top, 10)
            }

            Divider()
                .padding(.vertical, 10)

            shortcutCard

            VStack(spacing: 0) {
                popoverRow(
                    "Open Settings",
                    symbol: "gearshape",
                    action: AppDelegate.presentSettings
                )

                Divider()
                    .padding(.leading, settingsContentInset)

                compactToggleRow("Start at Login", isOn: startAtLoginBinding)

                Divider()
                    .padding(.leading, settingsContentInset)

                compactToggleRow("Show in Dock", isOn: $settings.showInDock)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(surfaceFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 10)

            Divider()
                .padding(.vertical, 10)

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit WhisperKeys", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 294, alignment: .leading)
        .onAppear {
            settings.refreshStartAtLoginStatus()
            isStatusAnimating = viewModel.activity == .recording
        }
        .onChange(of: viewModel.activity) { _, activity in
            isStatusAnimating = activity == .recording
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(status.color.opacity(0.16))
                    .frame(width: 38, height: 38)
                    .scaleEffect(isStatusAnimating ? 1.15 : 1)
                Image(systemName: status.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(status.color)
            }
            .animation(
                isStatusAnimating
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isStatusAnimating
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("WhisperKeys")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(status.title)
                    .font(.subheadline)
                    .foregroundStyle(status.color)
                    .lineLimit(2)
            }

            Spacer()

            BrandAppIcon(size: 34, cornerRadius: 8)
                .accessibilityLabel("WhisperKeys")
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch viewModel.activity {
        case .recording:
            actionButton(
                "Stop & Transcribe",
                symbol: "stop.fill",
                tint: .red,
                action: viewModel.stopAndTranscribe
            )
        case .transcribing, .typing:
            actionButton(
                "Cancel Current Operation",
                symbol: "xmark",
                tint: .orange,
                action: viewModel.cancelCurrentOperation
            )
        case .installingModel:
            Label("Installing local model…", systemImage: "arrow.down.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(surfaceFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .idle:
            actionButton(
                "Start Dictation",
                symbol: "mic.fill",
                tint: .accentColor,
                action: onStartDictation
            )
        case .error:
            actionButton(
                "Try Dictation Again",
                symbol: "mic.fill",
                tint: .accentColor,
                action: onStartDictation
            )
        }
    }

    private var liveTranscript: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Live transcription", systemImage: "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(viewModel.debugLog.recognizedText)
                .font(.subheadline)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(surfaceFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var installationProgress: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView(value: viewModel.modelInstallationProgress ?? 0)
                .tint(.accentColor)
            Text(viewModel.modelInstallationStatus ?? "Preparing download…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(surfaceFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var shortcutCard: some View {
        HStack(spacing: 10) {
            Image(systemName: settings.shortcutKey == .disabled ? "menubar.rectangle" : "command")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.shortcutKey == .disabled ? "Menu bar control" : "Double-tap to dictate")
                    .font(.caption.weight(.semibold))
                Text(shortcutDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(.tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var shortcutDescription: String {
        guard settings.shortcutKey != .disabled else {
            return "Start and stop from this popover."
        }
        return settings.shortcutKey.displayName + " starts and stops dictation."
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.regular)
    }

    private func popoverRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 20)
                Text(title)
            }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func compactToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, settingsContentInset)
        .padding(.vertical, 7)
    }

    private var status: (title: String, symbol: String, color: Color) {
        switch viewModel.activity {
        case .idle:
            ("Ready when you are", "checkmark", .green)
        case .recording:
            ("Listening…", "waveform", .red)
        case .transcribing:
            ("Transcribing locally…", "text.badge.checkmark", .orange)
        case .typing:
            ("Typing…", "keyboard", .orange)
        case .installingModel:
            ("Setting things up…", "arrow.down", .accentColor)
        case .error(let message):
            (message, "exclamationmark", .red)
        }
    }

    private var surfaceFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    private var settingsContentInset: CGFloat { 30 }

    private var startAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.startAtLogin },
            set: { settings.setStartAtLogin($0) }
        )
    }
}

/// Uses the app bundle's actual icon everywhere the product is introduced, so the visual
/// identity stays consistent even if the asset is refreshed later.
struct BrandAppIcon: View {
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: size * 0.1, y: size * 0.045)
    }
}
