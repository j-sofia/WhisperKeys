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

            if case .error(let error) = viewModel.activity {
                errorDetails(error)
                    .padding(.top, 10)
            }

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
        case .transcribing, .reviewing, .typing:
            actionButton(
                "Cancel Current Operation",
                symbol: "xmark",
                tint: .orange,
                action: viewModel.cancelCurrentOperation
            )
        case .installingModel:
            actionButton(
                "Start Dictation",
                symbol: "mic.fill",
                tint: .accentColor,
                action: {},
                isDisabled: true
            )
        case .idle:
            actionButton(
                "Start Dictation",
                symbol: "mic.fill",
                tint: .accentColor,
                action: onStartDictation
            )
        case .error(let error):
            if let recovery = error.primaryRecoveryAction {
                actionButton(
                    recovery.title,
                    symbol: recovery.symbolName,
                    tint: .accentColor,
                    action: { perform(recovery) }
                )
            } else {
                actionButton(
                    "Open Settings",
                    symbol: "gearshape",
                    tint: .accentColor,
                    action: AppDelegate.presentSettings
                )
            }
        }
    }

    private func errorDetails(_ error: AppError) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(error.category.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func perform(_ recovery: AppRecoveryAction) {
        if recovery == .retryDictation {
            onStartDictation()
        } else {
            viewModel.performRecoveryAction(recovery)
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
            Image(systemName: settings.shortcutConfiguration.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcutCardTitle)
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
        guard settings.shortcutIsEnabled else {
            return "Start and stop from this popover."
        }
        return settings.shortcutActionDescription
    }

    private var shortcutCardTitle: String {
        guard settings.shortcutIsEnabled else { return "Menu bar control" }
        switch settings.shortcutActivationMode {
        case .singlePress: return "Press to dictate"
        case .doublePress: return "Double-press to dictate"
        case .hold: return "Hold to dictate"
        }
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void,
        isDisabled: Bool = false
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
        .disabled(isDisabled)
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
        case .reviewing:
            ("Review transcription", "text.badge.checkmark", .accentColor)
        case .typing:
            ("Typing…", "keyboard", .orange)
        case .installingModel:
            ("Setting things up…", "arrow.down", .accentColor)
        case .error(let error):
            (error.title, "exclamationmark", .red)
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

/// The floating recording panel's visualizer. Its levels are fed by the same microphone capture
/// that WhisperKit transcribes, so it remains useful even while dictating into another app.
struct LiveWaveformPopupView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var settings: AppSettings

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _settings = ObservedObject(wrappedValue: viewModel.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            popupHeader

            if viewModel.isReviewBeforeTyping {
                reviewModeContent
            } else {
                liveModeContent
            }
        }
        .padding(16)
        .frame(width: viewModel.isReviewBeforeTyping ? WaveformPopupLayout.reviewWidth : 294, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var popupHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(headerColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(headerTitle)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Spacer()
            Image(systemName: headerSymbol)
                .foregroundStyle(headerColor)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var liveModeContent: some View {
        LiveMicrophoneWaveform(levels: viewModel.liveAudioLevels)
            .frame(height: 48)
            .accessibilityLabel("Live microphone waveform")

        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(spacing: 4) {
                Text("Currently typing in:")
                Text(activeApplicationName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Text(stopInstruction)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var reviewModeContent: some View {
        switch viewModel.activity {
        case .recording:
            LiveMicrophoneWaveform(levels: viewModel.liveAudioLevels)
                .frame(height: 42)
                .accessibilityLabel("Live microphone waveform")
            liveReviewPreview
            Text(stopInstruction)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Finalizing your transcription…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            liveReviewPreview
        case .reviewing:
            Text("Nothing is typed until you accept.")
                .font(.caption)
                .foregroundStyle(.secondary)
            reviewedTranscription
            HStack {
                Button("Edit") {
                    AppDelegate.editReviewTranscription()
                }
                Button("Discard", role: .cancel) {
                    viewModel.cancelCurrentOperation()
                }
                Spacer()
                Button("Accept") {
                    viewModel.acceptReviewedTranscription()
                }
                .buttonStyle(.borderedProminent)
            }
        default:
            EmptyView()
        }
    }

    private var liveReviewPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            transcriptLabel("Current transcription")
            ScrollView {
                Text(reviewPlaceholder(viewModel.reviewTranscription, fallback: "No words recognized yet"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: previewTranscriptHeight)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var reviewedTranscription: some View {
        TextEditor(text: reviewedTranscriptionBinding)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(7)
            .frame(height: finalEditorHeight)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator.opacity(0.7))
        }
    }

    private func transcriptLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func reviewPlaceholder(_ text: String, fallback: String) -> String {
        text.isEmpty ? fallback : text
    }

    private var previewTranscriptHeight: CGFloat {
        WaveformPopupLayout.previewTranscriptHeight(for: viewModel.reviewTranscription)
    }

    private var finalEditorHeight: CGFloat {
        WaveformPopupLayout.finalEditorHeight(for: viewModel.reviewTranscription)
    }

    private var reviewedTranscriptionBinding: Binding<String> {
        Binding(
            get: { viewModel.reviewTranscription },
            set: { viewModel.updateReviewedTranscription($0) }
        )
    }

    private var headerTitle: String {
        switch viewModel.activity {
        case .recording: "Listening"
        case .transcribing: "Transcribing locally…"
        case .reviewing: "Review before typing"
        default: "WhisperKeys"
        }
    }

    private var headerSymbol: String {
        switch viewModel.activity {
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        case .reviewing: "text.badge.checkmark"
        default: "waveform"
        }
    }

    private var headerColor: Color {
        switch viewModel.activity {
        case .recording: .red
        case .transcribing: .orange
        case .reviewing: .accentColor
        default: .secondary
        }
    }

    private var stopInstruction: String {
        guard settings.shortcutIsEnabled else {
            return "Open WhisperKeys in the menu bar to stop"
        }
        switch settings.shortcutActivationMode {
        case .singlePress:
            return "Press \(settings.shortcutConfiguration.displayName) to stop"
        case .doublePress:
            return "Double-press \(settings.shortcutConfiguration.displayName) to stop"
        case .hold:
            return "Release \(settings.shortcutConfiguration.displayName) to stop"
        }
    }

    private var activeApplicationName: String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "No active application"
    }
}

enum WaveformPopupLayout {
    static let reviewWidth: CGFloat = 390
    private static let reviewTextWidth = reviewWidth - 52
    private static let maximumPreviewTextHeight: CGFloat = 260
    private static let minimumEditorHeight: CGFloat = 148
    private static let maximumEditorHeight: CGFloat = 360

    static func previewTranscriptHeight(for transcript: String) -> CGFloat {
        min(textHeight(for: transcript), maximumPreviewTextHeight)
    }

    static func finalEditorHeight(for transcript: String) -> CGFloat {
        min(max(textHeight(for: transcript) + 16, minimumEditorHeight), maximumEditorHeight)
    }

    static func panelSize(for activity: AppActivity, transcript: String) -> NSSize {
        let height: CGFloat
        switch activity {
        case .recording:
            height = max(230, 190 + previewTranscriptHeight(for: transcript))
        case .transcribing:
            height = max(220, 145 + previewTranscriptHeight(for: transcript))
        case .reviewing:
            height = max(300, 135 + finalEditorHeight(for: transcript))
        default:
            return NSSize(width: 294, height: 168)
        }
        return NSSize(width: reviewWidth, height: min(height, 560))
    }

    private static func textHeight(for transcript: String) -> CGFloat {
        let text = transcript.isEmpty ? "No words recognized yet" : transcript
        let font = NSFont.preferredFont(forTextStyle: .body)
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: reviewTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = font.ascender - font.descender + font.leading
        return max(lineHeight, ceil(rect.height))
    }
}

private struct LiveMicrophoneWaveform: View {
    let levels: [Double]

    var body: some View {
        Canvas { context, size in
            let count = max(levels.count, 1)
            let slotWidth = size.width / CGFloat(count)
            let barWidth = min(5, max(2, slotWidth * 0.62))

            for index in 0..<count {
                let level = index < levels.count ? levels[index] : 0.05
                let height = max(4, size.height * CGFloat(max(level, 0.05)))
                let rect = CGRect(
                    x: CGFloat(index) * slotWidth + (slotWidth - barWidth) / 2,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                let bar = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(bar, with: .color(.red))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}
