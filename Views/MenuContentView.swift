import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var settings: AppSettings
    @State private var isStatusAnimating = false

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _settings = ObservedObject(wrappedValue: viewModel.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .padding(.vertical, 14)

            primaryAction

            if viewModel.activity == .recording,
               !viewModel.debugLog.recognizedText.isEmpty {
                liveTranscript
                    .padding(.top, 12)
            }

            if viewModel.activity == .installingModel {
                installationProgress
                    .padding(.top, 12)
            }

            Divider()
                .padding(.vertical, 14)

            shortcutCard

            VStack(spacing: 0) {
                popoverRow(
                    "Settings…",
                    symbol: "gearshape",
                    action: AppDelegate.presentSettings
                )

                Divider()
                    .padding(.leading, 30)

                Toggle("Start at Login", isOn: startAtLoginBinding)
                    .toggleStyle(.switch)
                    .padding(.vertical, 10)

                Divider()
                    .padding(.leading, 30)

                Toggle("Show in Dock", isOn: $settings.showInDock)
                    .toggleStyle(.switch)
                    .padding(.top, 10)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .background(surfaceFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 12)

            Divider()
                .padding(.vertical, 14)

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
        .padding(16)
        .frame(width: 326, alignment: .leading)
        .onAppear {
            settings.refreshStartAtLoginStatus()
            isStatusAnimating = viewModel.activity == .recording
        }
        .onChange(of: viewModel.activity) { _, activity in
            withAnimation(.easeInOut(duration: 0.8).repeatCount(activity == .recording ? .max : 1, autoreverses: true)) {
                isStatusAnimating = activity == .recording
            }
        }
        .preferredColorScheme(settings.appearance.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(status.color.opacity(0.16))
                    .frame(width: 46, height: 46)
                    .scaleEffect(isStatusAnimating ? 1.15 : 1)
                Image(systemName: status.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(status.color)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("WhisperKeys")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(status.title)
                    .font(.subheadline)
                    .foregroundStyle(status.color)
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
        case .idle, .error:
            actionButton(
                viewModel.activity == .error ? "Try Dictation Again" : "Start Dictation",
                symbol: "mic.fill",
                tint: .accentColor,
                action: viewModel.startDictation
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
        .padding(12)
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
        .padding(12)
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
        .padding(11)
        .background(.tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var shortcutDescription: String {
        settings.shortcutKey == .disabled
            ? "Start and stop from this popover."
            : "(settings.shortcutKey.displayName) starts and stops WhisperKeys."
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
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
    }

    private func popoverRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
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
            ("Setting things up…", "arrow.down", .tint)
        case .error(let message):
            (message, "exclamationmark", .red)
        }
    }

    private var surfaceFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

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
