import SwiftUI

struct HiDPIRowView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isHovered = false
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var isHiDPIOn: Bool = false

    var body: some View {
        if display.isBuiltin {
            EmptyView()
        } else {
            HStack {
                MenuItemIcon(systemName: "sparkles", color: .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("HiDPI Modu", "HiDPI Mode"))
                        .font(.body)
                    if HiDPIService.shared.requiresAdmin(vendor: display.vendorNumber) {
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
            .onAppear {
                isHiDPIOn = HiDPIService.shared.isHiDPIEnabled(
                    vendor: display.vendorNumber,
                    product: display.modelNumber
                )
            }
            .alert(L("HiDPI işlemi başarısız", "HiDPI operation failed"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L("Tamam", "OK")) { errorMessage = nil }
            } message: {
                if let msg = errorMessage {
                    Text(msg)
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
                // not display.pixelWidth which is the CURRENT resolution
                let (nativeW, nativeH) = display.nativeResolution
                err = HiDPIService.shared.enableHiDPI(vendor: vendor, product: product,
                                                      nativeWidth: nativeW, nativeHeight: nativeH)
            } else {
                err = HiDPIService.shared.disableHiDPI(vendor: vendor, product: product)
            }
            isLoading = false
            if let err {
                errorMessage = err
            } else {
                isHiDPIOn = enable
                if enable { HiDPIService.shared.refreshModes(for: display) }
            }
        }
    }
}
