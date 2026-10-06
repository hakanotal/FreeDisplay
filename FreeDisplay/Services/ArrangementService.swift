import Foundation
import CoreGraphics

/// Sets display positions in the global coordinate space.
/// The display whose origin is (0, 0) is the main display (menu bar and Dock), so every
/// change moves all displays together and pins the intended main display to the origin.
@MainActor
final class ArrangementService: @unchecked Sendable {
    static let shared = ArrangementService()
    private init() {}

    /// Moves every display in `frames` to its frame's origin in a single configuration
    /// transaction. The layout is translated first so `mainID` lands on (0, 0), which keeps
    /// (or makes) it the main display without changing the relative arrangement.
    ///
    /// Completed `.permanently`, like System Settings, so WindowServer keeps the layout
    /// across reconnects and restarts. Runs inside `CGHelpers.runWithTimeout` because
    /// `CGCompleteDisplayConfiguration` can block on WindowServer IPC.
    /// - Returns: true if the configuration was applied.
    @discardableResult
    func apply(frames: [CGDirectDisplayID: CGRect], mainID: CGDirectDisplayID) async -> Bool {
        guard frames[mainID] != nil else { return false }
        let origins = ArrangementLayout.translated(frames, mainID: mainID).map {
            (id: $0.key, x: Int32($0.value.minX.rounded()), y: Int32($0.value.minY.rounded()))
        }
        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            for origin in origins {
                guard CGConfigureDisplayOrigin(cfg, origin.id, origin.x, origin.y) == .success else {
                    // Not completed yet, so cancelling is still valid here.
                    CGCancelDisplayConfiguration(cfg)
                    return false
                }
            }
            // On return the configuration is no longer valid (even on failure) — don't cancel it.
            return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
        }
    }

    /// Makes `targetID` the main display while keeping the current relative arrangement.
    @discardableResult
    func setMainDisplay(_ targetID: CGDirectDisplayID, frames: [CGDirectDisplayID: CGRect]) async -> Bool {
        await apply(frames: frames, mainID: targetID)
    }
}
