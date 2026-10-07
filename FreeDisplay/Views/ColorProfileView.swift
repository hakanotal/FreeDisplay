import SwiftUI

/// Expandable section for ICC color profile selection.
/// Lists all installed profiles alphabetically; highlights the active one.
struct ColorProfileView: View {
    /// Only the (constant) display ID is read, so brightness changes don't re-render this.
    let display: DisplayInfo
    @State private var recommended: [ICCProfile]
    @State private var others: [ICCProfile]
    @State private var isLoading: Bool
    @State private var selectedPath: URL?
    @State private var applyingPath: URL? = nil
    @State private var applyError: String?
    @State private var applySuccess = false

    /// Shows the cached list right away; the first scan of the session shows a spinner.
    init(display: DisplayInfo) {
        self.display = display
        let cached = ColorProfileService.shared.cachedProfiles
        let groups = Self.split(cached ?? [])
        _recommended = State(initialValue: groups.recommended)
        _others = State(initialValue: groups.others)
        _isLoading = State(initialValue: cached == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 14, height: 14)
                    Text(L("Profiller yükleniyor…", "Loading profiles…"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else if recommended.isEmpty && others.isEmpty {
                Text(L("Profil bulunamadı", "No profiles found"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                if applySuccess {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text(L("Uygulandı", "Applied"))
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                if let error = applyError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }

                // Recommended profiles (display-specific or well-known)
                if !recommended.isEmpty {
                    SectionBadge(title: L("Önerilen", "Recommended"))
                    ForEach(recommended) { profile in
                        ProfileRow(
                            profile: profile,
                            isSelected: selectedPath == profile.path,
                            isApplying: applyingPath == profile.path,
                            isDisabled: applyingPath != nil,
                            onTap: { applyProfile(profile) }
                        )
                        .help(L("Bu renk profiline geç", "Switch to this color profile"))
                    }
                }

                if !others.isEmpty {
                    SectionBadge(title: L("Tüm Profiller", "All Profiles"))
                    ForEach(others) { profile in
                        ProfileRow(
                            profile: profile,
                            isSelected: selectedPath == profile.path,
                            isApplying: applyingPath == profile.path,
                            isDisabled: applyingPath != nil,
                            onTap: { applyProfile(profile) }
                        )
                        .help(L("Bu renk profiline geç", "Switch to this color profile"))
                    }
                }
            }
        }
        .task { await loadProfiles() }
    }

    // MARK: - Grouping

    /// Display-specific or well-known profiles first, the rest after.
    private static func split(_ profiles: [ICCProfile]) -> (recommended: [ICCProfile], others: [ICCProfile]) {
        let keywords = ["sRGB", "P3", "Display", "LCD", "Apple", "Color LCD"]
        var recommended: [ICCProfile] = []
        var others: [ICCProfile] = []
        for profile in profiles {
            if keywords.contains(where: { profile.name.localizedCaseInsensitiveContains($0) }) {
                recommended.append(profile)
            } else {
                others.append(profile)
            }
        }
        return (recommended, others)
    }

    // MARK: - Actions

    private func loadProfiles() async {
        let service = ColorProfileService.shared
        selectedPath = service.currentProfileURL(for: display.displayID)
        let loaded = await service.enumerateProfiles()
        let groups = Self.split(loaded)
        if groups.recommended != recommended { recommended = groups.recommended }
        if groups.others != others { others = groups.others }
        isLoading = false
    }

    private func applyProfile(_ profile: ICCProfile) {
        guard applyingPath == nil else { return }
        applyError = nil
        applySuccess = false
        applyingPath = profile.path
        let displayID = display.displayID
        Task { @MainActor in
            // Off the main thread, so the row's spinner shows while ColorSync works.
            // (AppDelegate re-applies FreeDisplay's gamma when the color space changes.)
            let success = await Task.detached(priority: .userInitiated) {
                ColorProfileService.shared.setProfile(profile, for: displayID)
            }.value
            applyingPath = nil
            if success {
                selectedPath = profile.path
                applySuccess = true
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                applySuccess = false
            } else {
                applyError = L("Uygulanamadı, tekrar deneyin", "Couldn't apply, please try again")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                applyError = nil
            }
        }
    }
}

// MARK: - Sub-views

private struct SectionBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.blue)
            .cornerRadius(4)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

private struct ProfileRow: View {
    let profile: ICCProfile
    let isSelected: Bool
    let isApplying: Bool
    let isDisabled: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if isApplying {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.caption)
                        .foregroundColor(isSelected ? .blue : .secondary)
                        .frame(width: 14)
                }
                Text(profile.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled && !isApplying)
        .opacity(isDisabled && !isApplying ? 0.45 : 1.0)
        .background(isSelected ? Color.blue.opacity(0.05) : Color.primary.opacity(isHovered ? 0.06 : 0))
        .onHover { isHovered = $0 }
    }
}
