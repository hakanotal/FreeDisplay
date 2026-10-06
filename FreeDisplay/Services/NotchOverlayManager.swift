import AppKit
import CoreGraphics

/// Manages black overlay windows that fill the menu bar row of notched built-in displays,
/// so the notch blends in. The choice is saved per display and re-applied at launch and
/// whenever screens change (lid opened, display reconnected, arrangement changed).
@MainActor
final class NotchOverlayManager {
    static let shared = NotchOverlayManager()

    private static let hiddenDisplaysKey = "fd.notch.hiddenDisplays"

    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]
    /// Display UUIDs whose notch the user chose to hide (persisted).
    private var hiddenDisplayUUIDs: Set<String>

    private init() {
        hiddenDisplayUUIDs = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenDisplaysKey) ?? [])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // MARK: - Public API

    func isNotchHidden(for displayID: CGDirectDisplayID) -> Bool {
        hiddenDisplayUUIDs.contains(DisplayInfo.uuidString(for: displayID))
    }

    func setNotchHidden(_ hidden: Bool, for displayID: CGDirectDisplayID) {
        let uuid = DisplayInfo.uuidString(for: displayID)
        if hidden {
            hiddenDisplayUUIDs.insert(uuid)
        } else {
            hiddenDisplayUUIDs.remove(uuid)
        }
        UserDefaults.standard.set(hiddenDisplayUUIDs.sorted(), forKey: Self.hiddenDisplaysKey)
        syncOverlays()
    }

    /// Shows the overlays saved from the last session. Called once at launch.
    func restoreSavedOverlays() {
        syncOverlays()
    }

    // MARK: - Overlay windows

    @objc private func screenParametersChanged() {
        syncOverlays()
    }

    /// Creates, moves or closes overlay windows so that exactly the online notched displays
    /// the user chose are covered.
    private func syncOverlays() {
        var wanted: [CGDirectDisplayID: NSRect] = [:]
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  hiddenDisplayUUIDs.contains(DisplayInfo.uuidString(for: displayID)),
                  let frame = Self.notchRowFrame(on: screen) else { continue }
            wanted[displayID] = frame
        }

        // Collect first: don't mutate the dictionary while iterating it.
        let stale = overlayWindows.keys.filter { wanted[$0] == nil }
        for displayID in stale {
            overlayWindows.removeValue(forKey: displayID)?.close()
        }

        for (displayID, frame) in wanted {
            if let window = overlayWindows[displayID] {
                window.setFrame(frame, display: true)
            } else {
                overlayWindows[displayID] = Self.makeOverlayWindow(frame: frame)
            }
        }
    }

    /// The menu bar row of a notched screen in global Cocoa coordinates, or nil if the
    /// screen has no notch.
    private static func notchRowFrame(on screen: NSScreen) -> NSRect? {
        let notchHeight = screen.safeAreaInsets.top
        guard notchHeight > 0 else { return nil }
        let screenFrame = screen.frame
        return NSRect(x: screenFrame.minX, y: screenFrame.maxY - notchHeight,
                      width: screenFrame.width, height: notchHeight)
    }

    private static func makeOverlayWindow(frame: NSRect) -> NSWindow {
        // No `screen:` argument: with one, AppKit treats the rect as relative to that screen's
        // origin, which pushes a global rect off-screen for any display not at (0, 0).
        let window = NotchOverlayWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false  // Prevent dangling pointer after close()
        window.backgroundColor = .black
        // Just below the menu bar: the notch row turns black while the menu bar items
        // drawn on top of it stay visible and clickable.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = true
        window.hasShadow = false
        window.animationBehavior = .none
        window.orderFrontRegardless()
        // AppKit may have adjusted the frame while ordering in; pin it to the menu bar row.
        window.setFrame(frame, display: true)
        return window
    }
}

/// AppKit moves ordinary windows so they don't sit under the menu bar; this one belongs
/// exactly there, so frame constraining is turned off.
private final class NotchOverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
