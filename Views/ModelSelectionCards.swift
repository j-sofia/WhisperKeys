import SwiftUI

/// A single model chooser shared by setup and Settings so the recommendation and
/// resource estimates never drift apart.
struct ModelSelectionCards: View {
    @Binding private var selection: String
    private let isDisabled: Bool
    private let hardware: MacHardwareProfile

    init(
        selection: Binding<String>,
        isDisabled: Bool = false,
        hardware: MacHardwareProfile = .current
    ) {
        _selection = selection
        self.isDisabled = isDisabled
        self.hardware = hardware
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            recommendationBanner

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 240), spacing: 10),
                    GridItem(.flexible(minimum: 240), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(WhisperModel.selectionOrder) { model in
                    ModelSelectionCard(
                        model: model,
                        isSelected: selection == model.rawValue,
                        isRecommended: hardware.recommendedModel == model
                    ) {
                        selection = model.rawValue
                    }
                    .disabled(isDisabled)
                }
            }

            Text("Download size and memory use are estimates. Models run entirely on this Mac after download.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recommendationBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .font(.subheadline)
                .frame(width: 24, height: 24)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Recommended for this Mac: \(hardware.recommendedModel.displayName)")
                    .font(.subheadline.weight(.semibold))
                Text("\(hardware.recommendedModel.cardSummary) \(hardware.shortDescription).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ModelSelectionCard: View {
    let model: WhisperModel
    let isSelected: Bool
    let isRecommended: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.displayName)
                        .font(.headline)

                    if isRecommended {
                        Text("RECOMMENDED")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.45)
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(.tint.opacity(0.12), in: Capsule())
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .font(.title3)
                }

                Text(model.cardSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    ModelCardMetric(icon: "arrow.down.circle", text: "\(model.downloadSize) download")
                    Spacer(minLength: 10)
                    ModelCardMetric(icon: "memorychip", text: "\(model.estimatedMemory) RAM")
                }

                HStack(spacing: 5) {
                    ModelCardMetric(icon: "checkmark.seal", text: "\(model.accuracyLabel) accuracy")
                    Spacer(minLength: 10)
                    ModelCardMetric(icon: "bolt", text: "\(model.speedLabel) speed")
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(10)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("\(model.displayName). \(model.cardSummary) Download \(model.downloadSize), estimated RAM \(model.estimatedMemory), accuracy \(model.accuracyLabel), speed \(model.speedLabel).\(isRecommended ? " Recommended for this Mac." : "")")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private struct ModelCardMetric: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        } icon: {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
