import Foundation
import CoreGraphics
import AppKit

// Global C-compatible callback for display reconfiguration.
// Must be a top-level function (not a closure) to be used as a C function pointer.
private func displayReconfigCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let ptr = userInfo else { return }

    // Skip the begin-configuration notification; only act when the change is complete.
    // (beginConfigurationFlag is set at the start of a transaction; absence means it finished.)
    guard !flags.contains(.beginConfigurationFlag) else { return }

    let relevant: CGDisplayChangeSummaryFlags = [
        .addFlag, .removeFlag, .setMainFlag, .setModeFlag, .movedFlag, .desktopShapeChangedFlag,
        .enabledFlag, .disabledFlag, .mirrorFlag, .unMirrorFlag,
    ]
    guard !flags.isDisjoint(with: relevant) else { return }

    let manager = Unmanaged<DisplayManager>.fromOpaque(ptr).takeUnretainedValue()
    let rawFlags = flags.rawValue
    Task { @MainActor in
        manager.handleReconfiguration(CGDisplayChangeSummaryFlags(rawValue: rawFlags))
    }
}

@MainActor
final class DisplayManager: ObservableObject {
    @Published var displays: [DisplayInfo] = []

    // nonisolated(unsafe) allows deinit (which is nonisolated in Swift 6) to access this value.
    nonisolated(unsafe) private var callbackContext: UnsafeMutableRawPointer?

    /// Flags collected from the callbacks of one reconfiguration (one callback per display).
    private var pendingFlags: CGDisplayChangeSummaryFlags = []
    private var reconfigTask: Task<Void, Never>?
    private var autoArrangeTask: Task<Void, Never>?

    init() {}

    deinit {
        if let ctx = callbackContext {
            CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, ctx)
            Unmanaged<DisplayManager>.fromOpaque(ctx).release()
        }
    }

    /// Starts tracking displays. Called once by AppDelegate after the single-instance check,
    /// so a duplicate launch that is about to quit never touches display state.
    func start() {
        guard callbackContext == nil else { return }
        refreshDisplays()
        setupReconfigCallback()
    }

    // MARK: - Display list

    /// Frames of the displays that take part in the arrangement. Mirror targets share their
    /// source's frame and are left out.
    var arrangementFrames: [CGDirectDisplayID: CGRect] {
        Dictionary(uniqueKeysWithValues: displays.filter { !$0.isMirrorTarget }.map { ($0.displayID, $0.bounds) })
    }

    var mainDisplayID: CGDirectDisplayID? {
        displays.first(where: { $0.isMain })?.displayID
    }

    func refreshDisplays() {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        let currentIDs = Set(displays.map { $0.displayID })
        let newIDSet = Set((0..<Int(displayCount)).map { displayIDs[$0] })

        // Clean up DDC cache for removed displays to prevent stale entries accumulating
        let removedIDs = currentIDs.subtracting(newIDSet)
        removedIDs.forEach {
            DDCService.shared.clearCache(for: $0)
            BrightnessService.shared.invalidateDDCState(for: $0)
        }

        // Diff-based refresh: keep existing DisplayInfo objects (preserves @Published state)
        let existingByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })

        var updatedDisplays: [DisplayInfo] = []
        var addedDisplays: [DisplayInfo] = []

        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if let existing = existingByID[id] {
                updatedDisplays.append(existing)
            } else {
                let info = DisplayInfo(displayID: id)
                updatedDisplays.append(info)
                addedDisplays.append(info)
            }
        }

        // For displays that were already present, update geometry, flags and name (no DDC probe).
        let keptIDs = currentIDs.intersection(newIDSet)
        for display in updatedDisplays where keptIDs.contains(display.displayID) {
            let id = display.displayID
            let bounds = CGDisplayBounds(id)
            if display.bounds != bounds { display.bounds = bounds }
            let isMain = CGDisplayIsMain(id) != 0
            if display.isMain != isMain { display.isMain = isMain }
            let isMirrorTarget = CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
            if display.isMirrorTarget != isMirrorTarget { display.isMirrorTarget = isMirrorTarget }
            display.refreshName()
        }

        // Reassigning always publishes, so views that read bounds re-render.
        displays = updatedDisplays
        DisplayManagerAccessor.shared.displays = updatedDisplays

        // Only load details / refresh brightness for newly appeared displays
        for display in addedDisplays {
            Task { await BrightnessService.shared.refreshBrightness(for: display) }
            Task {
                await display.loadDetails()
                // Auto-enable HiDPI for new external 2K+ displays that don't have it yet
                if !display.isBuiltin {
                    await self.autoEnableHiDPIIfNeeded(for: display)
                }
            }
            // Restore saved gamma/software-brightness adjustments for the reconnected display.
            // Brief delay lets WindowServer settle before we write transfer tables.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
                GammaService.shared.reapplyIfNeeded(for: display.displayID)
            }
        }
    }

    /// Refreshes the current mode of every tracked display (after setMode / setMain events).
    func refreshCurrentModes() {
        for display in displays {
            let displayID = display.displayID
            Task {
                let newMode = await Task.detached(priority: .userInitiated) {
                    DisplayMode.currentMode(for: displayID)
                }.value
                display.currentDisplayMode = newMode
            }
        }
    }

    /// Re-applies app-generated display names after an in-app language switch.
    func relocalizeDisplayNames() {
        for display in displays where display.isBuiltin {
            display.name = DisplayInfo.builtinDisplayName
        }
    }

    // MARK: - Reconfiguration

    private func setupReconfigCallback() {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        callbackContext = ctx
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, ctx)
    }

    /// Coalesces the per-display callbacks of one reconfiguration (150 ms) and refreshes once.
    /// Moves only refresh geometry; the opt-in auto-arrange runs only for hot-plug and mode
    /// changes, so it never undoes a layout the user just set.
    func handleReconfiguration(_ flags: CGDisplayChangeSummaryFlags) {
        pendingFlags.formUnion(flags)
        reconfigTask?.cancel()
        reconfigTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            let flags = self.pendingFlags
            self.pendingFlags = []
            self.refreshDisplays()
            if !flags.isDisjoint(with: [.setModeFlag, .setMainFlag]) {
                self.refreshCurrentModes()
            }
            if !flags.isDisjoint(with: [.addFlag, .removeFlag, .setModeFlag]) {
                self.scheduleAutoArrange()
            }
        }
    }

    /// Debounces auto-arrange: bursts of config changes trigger one arrange 500 ms later.
    func scheduleAutoArrange() {
        guard SettingsService.shared.autoArrangeExternalAbove else { return }
        autoArrangeTask?.cancel()
        autoArrangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.arrangeExternalAboveBuiltin()
        }
    }

    // MARK: - Auto-arrange

    /// Places the external displays side by side in a row directly above the built-in
    /// display, centered on it, keeping their current left-to-right order and the current
    /// main display. Only runs when the opt-in setting
    /// `SettingsService.autoArrangeExternalAbove` is on.
    func arrangeExternalAboveBuiltin() async {
        guard SettingsService.shared.autoArrangeExternalAbove else { return }
        refreshDisplays()

        let participants = displays.filter { !$0.isMirrorTarget }
        guard let builtin = participants.first(where: { $0.isBuiltin }) else { return }
        let externals = participants
            .filter { !$0.isBuiltin }
            .sorted { $0.bounds.minX < $1.bounds.minX }
        guard !externals.isEmpty else { return }

        let row = ArrangementLayout.rowAbove(builtin.bounds, sizes: externals.map { $0.bounds.size })
        var target: [CGDirectDisplayID: CGRect] = [builtin.displayID: builtin.bounds]
        for (external, frame) in zip(externals, row) {
            target[external.displayID] = frame
        }

        // Already arranged: applying again would only trigger another reconfiguration.
        let current = arrangementFrames
        let alreadyArranged = target.allSatisfy { id, frame in
            guard let now = current[id] else { return false }
            return abs(now.minX - frame.minX) < 1 && abs(now.minY - frame.minY) < 1
        }
        guard !alreadyArranged else { return }

        let mainID = mainDisplayID ?? builtin.displayID
        if await ArrangementService.shared.apply(frames: target, mainID: mainID) {
            refreshDisplays()
        }
    }

    // MARK: - Wake

    /// Restores display state after wake. Sleep resets every transfer table, displays may
    /// come back with new IOKit services, and macOS can reset modes.
    func reapplyDisplayStateAfterWake() async {
        // Give WindowServer time to stabilize after wake before touching display state.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        refreshDisplays()
        try? await Task.sleep(nanoseconds: 500_000_000)
        reapplyDisplayState(reprobeDDC: true)
        ResolutionService.shared.restoreModesAfterWake()
    }

    /// Re-applies software brightness, then gamma for every display. Brightness must come
    /// first: GammaService reads its factor. With `reprobeDDC`, DDC support is detected
    /// again so one failure (e.g. a monitor still waking up) isn't permanent.
    func reapplyDisplayState(reprobeDDC: Bool) {
        for display in displays {
            if reprobeDDC && !display.isBuiltin {
                DDCService.shared.clearCache(for: display.displayID)
                BrightnessService.shared.invalidateDDCState(for: display.displayID)
                Task { await BrightnessService.shared.refreshBrightness(for: display) }
            }
            BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
            GammaService.shared.reapplyIfNeeded(for: display.displayID)
        }
    }

    // MARK: - HiDPI

    /// Auto-enables the HiDPI plist override for external 2K+ displays that don't have it
    /// yet, so a new monitor "just works". Skipped when the user turned HiDPI off for this
    /// monitor, or when it would need an admin password (never prompt unasked).
    private func autoEnableHiDPIIfNeeded(for display: DisplayInfo) async {
        let vendor = display.vendorNumber
        let product = display.modelNumber
        guard vendor != 0, product != 0 else { return }
        // Skip FreeDisplay's own virtual displays (VirtualDisplayService uses vendor 0xEEEE).
        guard vendor != 0xEEEE else { return }

        let hiDPI = HiDPIService.shared
        guard !hiDPI.isHiDPIEnabled(vendor: vendor, product: product),
              hiDPI.allowsAutoEnable(vendor: vendor, product: product) else { return }

        // Determine native resolution from available modes
        let (nativeW, nativeH) = display.nativeResolution

        // Only auto-enable for 2K+ displays (width >= 2560 or total pixels >= 2560*1440)
        guard nativeW >= 2560 || (nativeW * nativeH >= 2560 * 1440) else { return }

        print("[DisplayManager] Auto-enabling HiDPI for \(display.name) (\(nativeW)×\(nativeH), vendor=\(vendor), product=\(product))")

        if let err = hiDPI.enableHiDPI(vendor: vendor, product: product,
                                       nativeWidth: nativeW, nativeHeight: nativeH) {
            print("[DisplayManager] Auto-enable HiDPI failed: \(err)")
        } else {
            hiDPI.refreshModes(for: display)
        }
    }
}
