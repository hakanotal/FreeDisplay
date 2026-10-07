import SwiftUI
import AppKit

/// Displays notch information and provides a toggle to cover the notch with a black overlay.
/// Only visible for built-in displays that actually have a notch (safeAreaInsets.top > 0).
struct NotchView: View {
    /// Only constant properties are read, so brightness changes don't re-render this.
    let display: DisplayInfo
    private let notchHeight: CGFloat
    @State private var isHidingNotch: Bool
    @State private var isHovered = false

    init(display: DisplayInfo) {
        self.display = display
        notchHeight = display.isBuiltin ? NSScreen.screen(for: display.displayID)?.safeAreaInsets.top ?? 0 : 0
        _isHidingNotch = State(initialValue: NotchOverlayManager.shared.isNotchHidden(for: display.displayID))
    }

    var body: some View {
        if notchHeight > 0 {
            VStack(alignment: .leading, spacing: 0) {
                // Info row
                HStack {
                    MenuItemIcon(systemName: "camera.aperture", color: .blue)
                    Text(L("Çentik", "Notch"))
                        .font(.body)
                    Text(String(format: "%.0f pt", notchHeight))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)

                // Hide/show toggle
                HStack {
                    MenuItemIcon(systemName: isHidingNotch ? "eye.slash" : "eye", color: .secondary)
                    Text(L("Çentik alanını gizle", "Hide notch area"))
                        .font(.body)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isHidingNotch },
                        set: { newValue in
                            isHidingNotch = newValue
                            NotchOverlayManager.shared.setNotchHidden(newValue, for: display.displayID)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help(L("Çentiği gizlemek için menü çubuğu alanında siyah bir maske göster", "Show a black mask in the menu bar area to hide the notch"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(isHovered ? 0.06 : 0))
                .onHover { isHovered = $0 }
            }
        }
    }
}
