import Foundation
import CoreGraphics
import IOKit
import AppKit

/// How FreeDisplay changes a display's brightness.
enum BrightnessControl: Equatable {
    /// The display's own backlight through DisplayServices (built-in panels, Apple displays).
    case native
    /// DDC/CI over I2C (VCP 0x10).
    case ddc
    /// Gamma dimming through GammaService (no hardware control available).
    case software
}

@MainActor
final class DisplayInfo: ObservableObject, Identifiable {
    /// Localized name for the built-in panel (re-applied after an in-app language switch).
    static var builtinDisplayName: String { L("Dahili Ekran", "Built-in Display") }

    nonisolated var id: CGDirectDisplayID { displayID }
    let displayID: CGDirectDisplayID
    /// Stable key for persisted per-display settings, captured once. CGDirectDisplayIDs can be
    /// reassigned to another monitor; DisplayManager then replaces this object (it compares
    /// identities on every refresh), so the UUID never goes stale.
    let displayUUID: String
    let isBuiltin: Bool
    /// One of FreeDisplay's own CGVirtualDisplays (no hardware behind it).
    let isVirtual: Bool
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32
    /// Pixel size of the mode active when the display appeared (fallback before modes load).
    let initialPixelWidth: Int
    let initialPixelHeight: Int

    @Published var name: String
    @Published var isMain: Bool
    /// True when this display mirrors another one (it then shares that display's bounds).
    @Published var isMirrorTarget: Bool
    @Published var bounds: CGRect
    @Published var brightness: Double
    /// Set by BrightnessService once it knows how this display's brightness is controlled.
    @Published var brightnessControl: BrightnessControl?
    @Published var availableModes: [DisplayMode]
    @Published var currentDisplayMode: DisplayMode?

    /// Stable per-display key for persisted settings. Prefer the stored `displayUUID` of a
    /// `DisplayInfo`; this performs a ColorSync lookup on every call.
    nonisolated static func uuidString(for displayID: CGDirectDisplayID) -> String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID),
           let uuidStr = CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) {
            return uuidStr as String
        }
        // Fallback: vendor+model+serial is more stable than the raw displayID
        return fallbackUUIDPrefix + "\(CGDisplayVendorNumber(displayID))-m\(CGDisplayModelNumber(displayID))-s\(CGDisplaySerialNumber(displayID))"
    }

    private nonisolated static let fallbackUUIDPrefix = "v"

    /// The native (highest non-HiDPI) resolution, used for HiDPI enablement and presets.
    var nativeResolution: (width: Int, height: Int) {
        let nativeMode = availableModes
            .filter { !$0.isHiDPI }
            .max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
        return (nativeMode?.width ?? initialPixelWidth, nativeMode?.height ?? initialPixelHeight)
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        let uuid = Self.uuidString(for: displayID)
        self.displayUUID = uuid
        let builtin = CGDisplayIsBuiltin(displayID) != 0
        self.isBuiltin = builtin
        self.vendorNumber = CGDisplayVendorNumber(displayID)
        self.modelNumber = CGDisplayModelNumber(displayID)
        self.serialNumber = CGDisplaySerialNumber(displayID)
        self.isVirtual = vendorNumber == VirtualDisplayService.vendorID
        self.initialPixelWidth = CGDisplayPixelsWide(displayID)
        self.initialPixelHeight = CGDisplayPixelsHigh(displayID)
        self.isMain = CGDisplayIsMain(displayID) != 0
        self.isMirrorTarget = CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
        self.bounds = CGDisplayBounds(displayID)
        // Start from the last brightness FreeDisplay set for this display, otherwise 50.
        // BrightnessService overwrites this with the real hardware value once probed.
        self.brightness = SettingsService.shared.brightness(forDisplayUUID: uuid) ?? 50.0
        self.availableModes = []
        self.currentDisplayMode = DisplayMode.currentMode(for: displayID)
        self.name = builtin ? Self.builtinDisplayName : L("Ekran \(displayID)", "Display \(displayID)")
        refreshName()
    }

    /// Whether `displayID` still refers to the monitor this object was created for. IDs can be
    /// handed to another monitor (fast swap, re-enumeration after wake).
    func isSameMonitor(as displayID: CGDirectDisplayID) -> Bool {
        guard CGDisplayVendorNumber(displayID) == vendorNumber,
              CGDisplayModelNumber(displayID) == modelNumber,
              CGDisplaySerialNumber(displayID) == serialNumber else { return false }
        let uuid = Self.uuidString(for: displayID)
        // A failed ColorSync lookup yields the vendor/model/serial fallback, which was already
        // compared above; don't treat that as a different monitor.
        return uuid == displayUUID || uuid.hasPrefix(Self.fallbackUUIDPrefix) || displayUUID.hasPrefix(Self.fallbackUUIDPrefix)
    }

    /// Re-reads geometry, main/mirror state and the name. Returns true if anything changed.
    @discardableResult
    func refreshState() -> Bool {
        var changed = false
        let newBounds = CGDisplayBounds(displayID)
        if bounds != newBounds { bounds = newBounds; changed = true }
        let newIsMain = CGDisplayIsMain(displayID) != 0
        if isMain != newIsMain { isMain = newIsMain; changed = true }
        let newIsMirrorTarget = CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
        if isMirrorTarget != newIsMirrorTarget { isMirrorTarget = newIsMirrorTarget; changed = true }
        if refreshName() { changed = true }
        return changed
    }

    /// Picks up the system name for external displays. NSScreen may not know a display yet
    /// right after it is plugged in, so this is retried on every refresh.
    @discardableResult
    func refreshName() -> Bool {
        guard !isBuiltin, let screenName = NSScreen.screen(for: displayID)?.localizedName,
              screenName != name else { return false }
        name = screenName
        return true
    }

    /// Refreshes the active mode; publishes only when it changed.
    func refreshCurrentMode() {
        let mode = DisplayMode.currentMode(for: displayID)
        if currentDisplayMode != mode { currentDisplayMode = mode }
    }

    func loadDetails() async {
        let displayID = self.displayID

        let modes = await Task.detached(priority: .userInitiated) {
            DisplayMode.availableModes(for: displayID)
        }.value

        if availableModes != modes { availableModes = modes }
    }
}
