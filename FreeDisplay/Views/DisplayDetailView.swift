import SwiftUI

// MARK: - DisplayDetailView

struct DisplayDetailView: View {
    /// Not observed: the rows that show changing values observe the display themselves, so a
    /// brightness tick doesn't rebuild the whole panel.
    let display: DisplayInfo
    @State private var showModeList: Bool
    @State private var showColorProfile: Bool
    @State private var showImageAdjustment: Bool
    @State private var colorSpaceName: String = ""

    /// Expanded sections are read here, not in onAppear, so the panel opens at its final
    /// height instead of growing a frame later.
    init(display: DisplayInfo) {
        self.display = display
        _showModeList = State(initialValue: Self.loadExpanded("modeList", for: display, default: false))
        _showColorProfile = State(initialValue: Self.loadExpanded("colorProfile", for: display, default: false))
        _showImageAdjustment = State(initialValue: Self.loadExpanded("imageAdjust", for: display, default: false))
    }

    private static func sectionKey(_ name: String, for display: DisplayInfo) -> String {
        "fd.expanded.\(display.displayUUID).\(name)"
    }

    private static func loadExpanded(_ name: String, for display: DisplayInfo, default value: Bool) -> Bool {
        let key = sectionKey(name, for: display)
        guard UserDefaults.standard.object(forKey: key) != nil else { return value }
        return UserDefaults.standard.bool(forKey: key)
    }

    private func saveExpanded(_ name: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.sectionKey(name, for: display))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Brightness slider
            BrightnessSliderView(display: display)

            Divider().opacity(0.3).padding(.vertical, 2)

            // HiDPI toggle — before mode list (natural workflow: enable HiDPI → pick resolution)
            HiDPIRowView(display: display)

            // Display mode list toggle row
            DisplayModesRow(display: display, isExpanded: $showModeList)

            if showModeList {
                DisplayModeListView(display: display)
                    .padding(.leading, 8)
                    .transition(Disclosure.content)
            }

            Divider().opacity(0.3).padding(.vertical, 2)

            // Color profile section
            ExpandableRow(
                icon: "paintpalette.fill",
                iconColor: .purple,
                label: L("Renk Profili", "Color Profile"),
                subtitle: colorSpaceName,
                isExpanded: $showColorProfile
            )

            if showColorProfile {
                ColorProfileView(display: display)
                    .padding(.leading, 8)
                    .transition(Disclosure.content)
            }

            // Image adjustment section
            ExpandableRow(
                icon: "slider.horizontal.3",
                label: L("Görüntü Ayarları", "Image Adjustments"),
                isExpanded: $showImageAdjustment
            )

            if showImageAdjustment {
                ImageAdjustmentView(display: display)
                    .padding(.leading, 8)
                    .transition(Disclosure.content)
            }

            Divider().opacity(0.3).padding(.vertical, 2)

            // Set as main display
            MainDisplayView(display: display)

            // Notch management (built-in with notch only)
            NotchView(display: display)

        }
        .padding(.leading, 32)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .onChange(of: showModeList) { _, v in saveExpanded("modeList", v) }
        .onChange(of: showColorProfile) { _, v in saveExpanded("colorProfile", v) }
        .onChange(of: showImageAdjustment) { _, v in saveExpanded("imageAdjust", v) }
        .task(id: display.displayID) {
            colorSpaceName = ColorProfileService.shared.currentColorSpaceName(for: display.displayID)
        }
        // Keep the subtitle current after a profile switch (from this app or System Settings).
        .onReceive(
            NotificationCenter.default.publisher(for: NSScreen.colorSpaceDidChangeNotification)
                .receive(on: DispatchQueue.main)
        ) { _ in
            colorSpaceName = ColorProfileService.shared.currentColorSpaceName(for: display.displayID)
        }
    }
}

/// The "Display Modes" section header; observes the display for the current mode.
private struct DisplayModesRow: View {
    @ObservedObject var display: DisplayInfo
    @Binding var isExpanded: Bool

    var body: some View {
        ExpandableRow(
            icon: "rectangle.on.rectangle",
            label: L("Ekran Modları", "Display Modes"),
            subtitle: subtitle,
            isExpanded: $isExpanded
        )
    }

    private var subtitle: String {
        guard let mode = display.currentDisplayMode else { return "" }
        return mode.isHiDPI ? "\(mode.resolutionString) · HiDPI" : mode.resolutionString
    }
}
