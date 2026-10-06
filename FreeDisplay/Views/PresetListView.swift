import SwiftUI

// MARK: - PresetListView

/// Section in MenuBarView listing user-created presets.
struct PresetListView: View {
    @ObservedObject private var presetService = PresetService.shared

    var body: some View {
        let currentMatch = presetService.currentPresetMatch()
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presetService.presets) { preset in
                PresetRow(
                    preset: preset,
                    isCurrentMatch: currentMatch == preset.id,
                    isApplying: presetService.applyingPresetID == preset.id
                )
            }

            // Save preset button
            SavePresetView()
        }
    }
}

// MARK: - PresetRow

struct PresetRow: View {
    let preset: DisplayPreset
    let isCurrentMatch: Bool
    let isApplying: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if isApplying {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 20, height: 20)
            } else {
                MenuItemIcon(systemName: preset.icon, color: isCurrentMatch ? .accentColor : .gray)
            }

            Text(preset.name)
                .font(.body)
                .lineLimit(1)

            Spacer()

            if isCurrentMatch {
                Text(L("Mevcut", "Current"))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !PresetService.shared.isApplying else { return }
            Task { await PresetService.shared.applyPreset(preset) }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(role: .destructive) {
                PresetService.shared.deletePreset(id: preset.id)
            } label: {
                Label(L("Sil", "Delete"), systemImage: "trash")
            }
        }
        .disabled(PresetService.shared.isApplying)
    }
}
