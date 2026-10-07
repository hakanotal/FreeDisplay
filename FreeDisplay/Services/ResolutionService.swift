import Foundation
@preconcurrency import CoreGraphics

/// Service responsible for reading and changing display resolution modes.
@MainActor
final class ResolutionService: @unchecked Sendable {
    static let shared = ResolutionService()
    private init() {}

    // MARK: - Sleep / wake

    /// Active mode ID per display UUID, captured right before sleep.
    private var modesBeforeSleep: [String: Int32] = [:]

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    func snapshotModesBeforeSleep() {
        var snapshot: [String: Int32] = [:]
        for displayID in Self.onlineDisplayIDs() {
            if let mode = CGDisplayCopyDisplayMode(displayID) {
                snapshot[DisplayInfo.uuidString(for: displayID)] = mode.ioDisplayModeID
            }
        }
        modesBeforeSleep = snapshot
    }

    /// Puts back any mode that changed while the displays slept. Only the pre-sleep state is
    /// restored, so a mode the user picks later (here or in System Settings) is never undone.
    func restoreModesAfterWake() {
        let snapshot = modesBeforeSleep
        modesBeforeSleep = [:]
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        for displayID in Self.onlineDisplayIDs() {
            guard let savedID = snapshot[DisplayInfo.uuidString(for: displayID)],
                  CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID != savedID,
                  let rawModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
                  let cgMode = rawModes.first(where: { $0.ioDisplayModeID == savedID }) else { continue }

            Task.detached(priority: .userInitiated) {
                let ok = await ResolutionService.applyModeSync(cgMode, on: displayID)
                #if DEBUG
                print("[ResolutionService] wake restore modeID=\(savedID) on displayID=\(displayID) success=\(ok)")
                #endif
            }
        }
    }

    // MARK: - Apply

    /// Sets a display mode on `displayID`. `mode` must come from this display's own mode list:
    /// mode IDs are per display. Mirror targets are refused (their mode follows the mirror
    /// source; change the resolution there).
    func setDisplayMode(_ mode: DisplayMode, for displayID: CGDirectDisplayID) async -> Bool {
        guard CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay else { return false }

        // Enumerate modes off the main thread to avoid blocking the UI.
        let cgMode: CGDisplayMode? = await Task.detached(priority: .userInitiated) {
            let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            guard let allRaw = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return nil }
            return allRaw.first(where: { $0.ioDisplayModeID == mode.ioDisplayModeID })
                ?? ResolutionService.bestMatchingMode(in: allRaw, for: mode)
        }.value

        guard let cgMode else {
#if DEBUG
            print("[ResolutionService] No matching CGDisplayMode for \(mode.width)×\(mode.height) hiDPI=\(mode.isHiDPI) on displayID=\(displayID)")
#endif
            return false
        }

        if await ResolutionService.applyModeSync(cgMode, on: displayID) {
            return true
        }
#if DEBUG
        print("[ResolutionService] Standard API failed, trying CGS fallback modeID=\(cgMode.ioDisplayModeID)")
#endif
        return await Self.cgsFallback(modeID: cgMode.ioDisplayModeID, on: displayID)
    }

    // MARK: - Mode attribute matching

    /// Finds the mode in `rawModes` with `mode`'s logical size, preferring the same HiDPI flag.
    nonisolated static func bestMatchingMode(in rawModes: [CGDisplayMode], for mode: DisplayMode) -> CGDisplayMode? {
        let sameSize = rawModes.filter {
            $0.width == mode.width && $0.height == mode.height && $0.isUsableForDesktopGUI()
        }
        return sameSize.first(where: { ($0.pixelWidth > $0.width) == mode.isHiDPI }) ?? sameSize.first
    }

    // MARK: - Commit via public CG API (async, call off main thread)

    /// Applies a display mode change off the calling thread.
    /// The entire Begin→Configure→Complete transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    nonisolated static func applyModeSync(_ cgMode: CGDisplayMode, on displayID: CGDirectDisplayID) async -> Bool {
        await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else {
                #if DEBUG
                print("[ResolutionService] CGBeginDisplayConfiguration failed")
                #endif
                return false
            }

            let result = CGConfigureDisplayWithDisplayMode(cfg, displayID, cgMode, nil)
            guard result == .success else {
                CGCancelDisplayConfiguration(cfg)
                #if DEBUG
                print("[ResolutionService] CGConfigureDisplayWithDisplayMode failed (\(result.rawValue)) displayID=\(displayID) modeID=\(cgMode.ioDisplayModeID)")
                #endif
                return false
            }

            // .permanently, like System Settings: WindowServer then restores this mode itself
            // after reconnect, wake and restart (.forSession changes get reverted).
            let complete = CGCompleteDisplayConfiguration(cfg, .permanently)
            #if DEBUG
            if complete != .success {
                print("[ResolutionService] CGCompleteDisplayConfiguration failed (\(complete.rawValue))")
            }
            #endif
            return complete == .success
        }
    }

    // MARK: - CGSConfigureDisplayMode fallback (private API)

    /// Applies a mode by its raw modeID using the CGS private API.
    /// CGSConfigureDisplayMode(config, displayID, modeNum) bypasses some of the
    /// restrictions that CGConfigureDisplayWithDisplayMode has on certain display configs.
    /// It must run inside a CGBeginDisplayConfiguration transaction. Completing the
    /// transaction can succeed without the mode actually changing, so success is verified
    /// by reading the active mode back.
    private nonisolated static func cgsFallback(modeID: Int32, on displayID: CGDirectDisplayID) async -> Bool {
        let completed = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
            guard CGSConfigureDisplayMode(cfg, displayID, modeID) == .success else {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            // On return the configuration is no longer valid, whether or not it succeeded.
            // Its result isn't reliable here; the read-back below decides.
            _ = CGCompleteDisplayConfiguration(cfg, .permanently)
            return true
        }
        guard completed else { return false }

        // Wait for the mode change to propagate before reading back.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let success = CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID == modeID
#if DEBUG
        print("[ResolutionService] CGS fallback: success=\(success) modeID=\(modeID) displayID=\(displayID)")
#endif
        return success
    }
}
