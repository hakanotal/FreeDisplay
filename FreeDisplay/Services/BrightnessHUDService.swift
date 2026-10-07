import AppKit
import CoreGraphics

// MARK: - OSDUIHelper Protocol (Private API)

/// OSDImage values for the native macOS OSD.
/// Brightness up/down uses value 1 (brightness icon with level bar).
@objc enum OSDImage: CLong {
    case brightness = 1
    case volume = 3
    case mute = 4
    case eject = 6
}

/// XPC protocol matching OSDUIHelper's interface.
/// This version (with filledChiclets/totalChiclets) shows the brightness level bar.
@objc protocol OSDUIHelperProtocol {
    func showImage(
        _ img: OSDImage,
        onDisplayID displayID: CGDirectDisplayID,
        priority: CUnsignedInt,
        msecUntilFade: CUnsignedInt,
        filledChiclets: CUnsignedInt,
        totalChiclets: CUnsignedInt,
        locked: Bool
    )
}

// MARK: - BrightnessHUDService

/// Shows the native macOS brightness OSD via the private OSDUIHelper XPC service.
/// This produces the exact same brightness indicator that macOS uses natively.
///
/// Used by MonitorControl and BetterDisplay for the same purpose. One connection is kept
/// open and reused for every key press; it is recreated if the system invalidates it.
@MainActor
final class BrightnessHUDService: @unchecked Sendable {
    static let shared = BrightnessHUDService()
    private init() {}

    private var connection: NSXPCConnection?

    // MARK: - Public API

    /// Shows the native macOS brightness OSD on the specified display.
    /// - Parameters:
    ///   - brightness: Brightness level 0–100
    ///   - screen: The NSScreen on which the OSD should appear
    func show(brightness: Double, on screen: NSScreen) {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let helper = helperProxy() else { return }

        let totalChiclets: CUnsignedInt = 16
        let filledChiclets = CUnsignedInt((max(0, min(100, brightness)) / 100.0 * Double(totalChiclets)).rounded())
        helper.showImage(
            .brightness,
            onDisplayID: displayID,
            priority: 0x1f4,
            msecUntilFade: 1500,
            filledChiclets: filledChiclets,
            totalChiclets: totalChiclets,
            locked: false
        )
    }

    private func helperProxy() -> OSDUIHelperProtocol? {
        let connection = self.connection ?? makeConnection()
        // @Sendable: XPC calls this on its own queue; an implicitly main-isolated closure would trap.
        return connection.remoteObjectProxyWithErrorHandler { @Sendable error in
            NSLog("[BrightnessHUD] XPC error: %@", error.localizedDescription)
        } as? OSDUIHelperProtocol
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: OSDUIHelperProtocol.self)
        let id = ObjectIdentifier(connection)
        // @Sendable: XPC calls these on its own queue, never the main thread.
        // After an interruption the connection stays usable (XPC relaunches the service).
        connection.interruptionHandler = { @Sendable in NSLog("[BrightnessHUD] XPC connection interrupted") }
        connection.invalidationHandler = { @Sendable in
            Task { @MainActor in BrightnessHUDService.shared.connectionInvalidated(id) }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func connectionInvalidated(_ id: ObjectIdentifier) {
        if let connection, ObjectIdentifier(connection) == id {
            self.connection = nil
        }
    }
}
