import SwiftUI

struct HiDPIRowView: View {
    /// Only constant properties are read (mode list at toggle time), so brightness changes
    /// don't re-render this.
    let display: DisplayInfo
    @ObservedObject private var service = HiDPIService.shared
    @State private var isHovered = false
    @State private var isLoading = false
    @State private var isHiDPIOn: Bool
    @State private var requiresAdmin: Bool
    /// Set after enabling: new modes only appear once the display reconnects.
    @State private var showReconnectHint = false

    init(display: DisplayInfo) {
        self.display = display
        let service = HiDPIService.shared
        _isHiDPIOn = State(initialValue: !display.isBuiltin && service.isHiDPIEnabled(
            vendor: display.vendorNumber, product: display.modelNumber))
        _requiresAdmin = State(initialValue: !display.isBuiltin && service.requiresAdmin(vendor: display.vendorNumber))
    }

    var body: some View {
        if display.isBuiltin {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    MenuItemIcon(systemName: "sparkles", color: .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("HiDPI Modu", "HiDPI Mode"))
                            .font(.body)
                        if requiresAdmin {
                            Text(L("Yönetici izni gerekir (bir kez)", "Requires administrator permission (once)"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else if isHiDPIOn {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(isHovered ? 0.06 : 0))
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isLoading else { return }
                    toggle()
                }
                .onHover { isHovered = $0 }

                if let error = service.lastError(vendor: display.vendorNumber, product: display.modelNumber) {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                } else if showReconnectHint {
                    Text(L("Yeni modlar, ekranın bağlantısı kesilip yeniden takıldığında görünür.",
                           "The new modes appear after you disconnect and reconnect the display."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    private func toggle() {
        isLoading = true
        let vendor = display.vendorNumber
        let product = display.modelNumber
        let enable = !isHiDPIOn
        Task { @MainActor in
            // Let the spinner render before the (possibly blocking) admin prompt.
            try? await Task.sleep(nanoseconds: 50_000_000)
            let err: String?
            if enable {
                // Use the highest available mode as native resolution,
                // not the current mode's pixel size.
                let (nativeW, nativeH) = display.nativeResolution
                err = HiDPIService.shared.enableHiDPI(vendor: vendor, product: product,
                                                      nativeWidth: nativeW, nativeHeight: nativeH)
            } else {
                err = HiDPIService.shared.disableHiDPI(vendor: vendor, product: product)
            }
            isLoading = false
            requiresAdmin = HiDPIService.shared.requiresAdmin(vendor: vendor)
            if err == nil {
                isHiDPIOn = enable
                showReconnectHint = enable
                if enable { HiDPIService.shared.refreshModes(for: display) }
            }
        }
    }
}
