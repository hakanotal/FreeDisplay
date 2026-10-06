import Foundation
import CoreGraphics
import IOKit
import AppKit

@MainActor
class DisplayInfo: ObservableObject, Identifiable {
    /// Localized name for the built-in panel (re-applied after an in-app language switch).
    static var builtinDisplayName: String { L("Dahili Ekran", "Built-in Display") }

    nonisolated var id: CGDirectDisplayID { displayID }
    let displayID: CGDirectDisplayID
    @Published var name: String
    @Published var isBuiltin: Bool
    @Published var isMain: Bool
    @Published var isOnline: Bool
    /// True when this display mirrors another one (it then shares that display's bounds).
    @Published var isMirrorTarget: Bool
    @Published var bounds: CGRect
    @Published var pixelWidth: Int
    @Published var pixelHeight: Int
    @Published var brightness: Double
    @Published var availableModes: [DisplayMode]
    @Published var currentDisplayMode: DisplayMode?
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32

    /// A stable identifier for the physical display that persists across sleep/wake
    /// even if macOS reassigns the CGDirectDisplayID.
    var displayUUID: String { Self.uuidString(for: displayID) }

    /// Stable per-display key for persisted settings. CGDirectDisplayIDs can be reassigned
    /// (reconnects, other ports), so never key saved state by the raw display ID.
    nonisolated static func uuidString(for displayID: CGDirectDisplayID) -> String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID),
           let uuidStr = CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) {
            return uuidStr as String
        }
        // Fallback: vendor+model+serial is more stable than the raw displayID
        return "v\(CGDisplayVendorNumber(displayID))-m\(CGDisplayModelNumber(displayID))-s\(CGDisplaySerialNumber(displayID))"
    }

    /// The native (highest non-HiDPI) resolution, used for HiDPI enablement and presets.
    var nativeResolution: (width: Int, height: Int) {
        let nativeMode = availableModes
            .filter { !$0.isHiDPI }
            .max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
        return (nativeMode?.width ?? pixelWidth, nativeMode?.height ?? pixelHeight)
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        let builtin = CGDisplayIsBuiltin(displayID) != 0
        self.isBuiltin = builtin
        self.isMain = CGDisplayIsMain(displayID) != 0
        self.isOnline = CGDisplayIsOnline(displayID) != 0
        self.isMirrorTarget = CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
        self.bounds = CGDisplayBounds(displayID)
        self.pixelWidth = CGDisplayPixelsWide(displayID)
        self.pixelHeight = CGDisplayPixelsHigh(displayID)
        // Start from the last brightness FreeDisplay set for this display, otherwise 50.
        // BrightnessService overwrites this with the real hardware value once probed.
        self.brightness = SettingsService.shared.brightness(forDisplayUUID: Self.uuidString(for: displayID)) ?? 50.0
        self.availableModes = []
        self.currentDisplayMode = DisplayMode.currentMode(for: displayID)
        self.vendorNumber = CGDisplayVendorNumber(displayID)
        self.modelNumber = CGDisplayModelNumber(displayID)
        self.serialNumber = CGDisplaySerialNumber(displayID)
        self.name = builtin ? Self.builtinDisplayName : L("Ekran \(displayID)", "Display \(displayID)")
        refreshName()
    }

    /// Picks up the system name for external displays. NSScreen may not know a display yet
    /// right after it is plugged in, so this is retried on every refresh.
    func refreshName() {
        guard !isBuiltin, let screenName = NSScreen.screen(for: displayID)?.localizedName,
              screenName != name else { return }
        name = screenName
    }

    func loadDetails() async {
        let displayID = self.displayID

        let modes = await Task.detached(priority: .userInitiated) {
            DisplayMode.availableModes(for: displayID)
        }.value

        self.availableModes = modes
    }
}
