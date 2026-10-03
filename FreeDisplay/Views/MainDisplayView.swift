import SwiftUI

/// Displays the "Set as Main Display" control inside DisplayDetailView.
/// Shows a status row when this display is already main, or a tappable button otherwise.
struct MainDisplayView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @State private var errorMessage: String?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if display.isMain {
                HStack {
                    MenuItemIcon(systemName: "m.circle.fill", color: .blue)
                    Text("Mevcut ana ekran")
                        .font(.body)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            } else {
                HStack {
                    MenuItemIcon(systemName: "m.circle.fill", color: .blue)
                    Text("Ana ekran yap")
                        .font(.body)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(isHovered ? 0.06 : 0))
                .onHover { isHovered = $0 }
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { @MainActor in
                        let success = await ArrangementService.shared.setAsMainDisplay(
                            display.displayID,
                            among: displayManager.displays
                        )
                        if !success {
                            errorMessage = "Ana ekran ayarlanamadı"
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                errorMessage = nil
                            }
                        }
                    }
                }
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
    }
}
