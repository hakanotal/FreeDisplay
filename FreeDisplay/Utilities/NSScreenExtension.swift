import AppKit
import CoreGraphics

extension NSScreen {
    /// Returns the NSScreen corresponding to the given CGDirectDisplayID, or nil if not found.
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }
}
