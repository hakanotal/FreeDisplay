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
    @Published private(set) var displays: [DisplayInfo] = []

    // nonisolated(unsafe) allows deinit (which is nonisolated in Swift 6) to access this value.
    nonisolated(unsafe) private var callbackContext: UnsafeMutableRawPointer?

    /// Flags collected from the callbacks of one reconfiguration (one callback per display).
    private var pendingFlags: CGDisplayChangeSummaryFlags = []
    private var reconfigTask: Task<Void, Never>?
    private var autoArrangeTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var gammaTask: Task<Void, Never>?
    /// Pending gamma reapply passes (absolute times), merged across triggers.
    private var gammaDeadlines: [Date] = []
    /// Recent gamma reapply passes, for the storm guard in `allowGammaPass`.
    private var gammaPassTimes: [Date] = []

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

    /// Syncs the display list with CoreGraphics. Kept displays are updated in place (their
    /// @Published state survives); an ID that now belongs to another monitor is treated as a
    /// removal plus an addition. Publishes only when something changed.
    func refreshDisplays() {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        let onlineIDs = Array(displayIDs.prefix(Int(displayCount)))

        let existingByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })
        var updated: [DisplayInfo] = []
        var added: [DisplayInfo] = []
        var forgotten: [CGDirectDisplayID] = []
        var changed = false

        for id in onlineIDs {
            if let existing = existingByID[id], existing.isSameMonitor(as: id) {
                if existing.refreshState() { changed = true }
                updated.append(existing)
            } else {
                if existingByID[id] != nil { forgotten.append(id) }  // same ID, other monitor
                let info = DisplayInfo(displayID: id)
                updated.append(info)
                added.append(info)
            }
        }
        forgotten += existingByID.keys.filter { !onlineIDs.contains($0) }

        // Clear per-ID state so a monitor that later gets one of these IDs starts clean.
        for id in forgotten {
            DDCService.shared.clearCache(for: id)
            BrightnessService.shared.forgetDisplay(id)
            GammaService.shared.forgetDisplay(id)
        }

        if !added.isEmpty || !forgotten.isEmpty || updated.map(\.displayID) != displays.map(\.displayID) {
            changed = true
        }
        guard changed else { return }

        displays = updated
        DisplayManagerAccessor.shared.displays = updated
        publishDisplayDependents()

        if !added.isEmpty || !forgotten.isEmpty {
            BrightnessService.shared.noteTopologyChange()
        }
        for display in added {
            prepareNewDisplay(display)
        }
    }

    /// Hands the current display set to services that need it outside the main actor.
    private func publishDisplayDependents() {
        let externals = displays.filter { !$0.isBuiltin && !$0.isVirtual }
        DDCService.shared.updateCandidates(externals.map {
            DDCCandidate(displayID: $0.displayID, vendor: $0.vendorNumber, model: $0.modelNumber,
                         serial: $0.serialNumber, name: NSScreen.screen(for: $0.displayID)?.localizedName)
        })
        BrightnessKeyService.shared.updateManagedDisplays(Set(externals.map(\.displayID)))
        PresetService.shared.updateCurrentMatch()
    }

    private func prepareNewDisplay(_ display: DisplayInfo) {
        Task { await BrightnessService.shared.refreshBrightness(for: display) }
        Task {
            await display.loadDetails()
            // Auto-enable HiDPI for new external 2K+ displays that don't have it yet
            if !display.isBuiltin && !display.isVirtual {
                self.autoEnableHiDPIIfNeeded(for: display)
            }
        }
        // Restore saved adjustments, software brightness and night mode for the new display
        // once WindowServer has set it up (its profile loads after it appears).
        scheduleGammaReapply(after: [0.3, 2.0], reason: "display added")
    }

    /// Refreshes the current mode of every tracked display (after setMode / setMain events).
    func refreshCurrentModes() {
        for display in displays {
            display.refreshCurrentMode()
        }
        PresetService.shared.updateCurrentMatch()
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
            // Completing any display configuration (arrangement, main display, mode, mirroring,
            // a display added or removed, the lid opened) makes macOS reload the profiles,
            // which resets transfer tables, sometimes a moment later. Reapply as it settles.
            self.scheduleGammaReapply(after: [0, 0.5, 2.0], reason: "reconfiguration")
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

    // MARK: - Transfer tables

    /// Rewrites the transfer function of every display with active state (image adjustment,
    /// software brightness, night mode). Idempotent and cheap; displays with nothing to apply
    /// are not touched.
    func reapplyGamma() {
        for display in displays {
            GammaService.shared.reapplyIfNeeded(for: display.displayID)
        }
    }

    /// Runs `reapplyGamma` at each of `delays` (seconds from now). Requests are merged: a new
    /// trigger adds its passes to the pending ones, and passes due within 50 ms of each other
    /// run once. Transfer-table writes post neither a color-space change nor a display
    /// reconfiguration, so this can't feed itself; the storm guard caps it if a macOS version
    /// ever does.
    func scheduleGammaReapply(after delays: [Double], reason: String) {
#if DEBUG
        print("[DisplayManager] gamma reapply scheduled: \(reason)")
#endif
        let now = Date()
        gammaDeadlines = (gammaDeadlines + delays.map { now.addingTimeInterval($0) }).sorted()
        // Restart the loop so it sleeps until the (possibly new) earliest deadline; the
        // deadlines themselves live in `gammaDeadlines`, so nothing is lost.
        gammaTask?.cancel()
        gammaTask = Task { [weak self] in
            while !Task.isCancelled, let self, let next = self.gammaDeadlines.first {
                let wait = next.timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    if Task.isCancelled { return }
                }
                let cutoff = Date().addingTimeInterval(0.05)
                self.gammaDeadlines.removeAll { $0 <= cutoff }
                if self.allowGammaPass() { self.reapplyGamma() }
            }
        }
    }

    private func allowGammaPass() -> Bool {
        let now = Date()
        gammaPassTimes = gammaPassTimes.filter { now.timeIntervalSince($0) < 5 } + [now]
        guard gammaPassTimes.count <= 20 else {
#if DEBUG
            print("[DisplayManager] gamma reapply storm: skipping pass")
#endif
            return false
        }
        return true
    }

    /// A display profile changed (here or in System Settings): ColorSync rewrote the table.
    func handleColorSpaceChange() {
        GammaService.shared.invalidateCalibration()
        scheduleGammaReapply(after: [0.1, 1.0], reason: "color space changed")
    }

    /// Displays woke from display sleep (without system sleep).
    func handleScreensWake() {
        scheduleGammaReapply(after: [0, 0.5, 2.0], reason: "screens woke")
    }

    // MARK: - Wake

    /// Restores display state after system wake. Sleep resets every transfer table, displays
    /// may come back with new IOKit services, and macOS can reset modes.
    func reapplyDisplayStateAfterWake() {
        // In-memory state survives sleep: put it back right away instead of showing full
        // brightness (or no night mode) until WindowServer has settled.
        reapplyGamma()
        BrightnessService.shared.noteTopologyChange()

        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            // Give WindowServer time to stabilize after wake before touching display state.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.refreshDisplays()
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            // Modes first: a mode change can reset the table (the reconfiguration it causes
            // schedules another gamma pass).
            ResolutionService.shared.restoreModesAfterWake()
            for display in self.displays where !display.isBuiltin && !display.isVirtual {
                // Detect DDC again so one failure while a monitor was waking isn't permanent.
                DDCService.shared.clearCache(for: display.displayID)
                BrightnessService.shared.invalidateDDCState(for: display.displayID)
                Task { await BrightnessService.shared.refreshBrightness(for: display) }
            }
            GammaService.shared.invalidateCalibration()
            // Panels power up at different speeds (a lid opened at wake): keep reapplying
            // for a few seconds.
            self.scheduleGammaReapply(after: [0, 1.0, 3.0], reason: "wake")
        }
    }

    // MARK: - HiDPI

    /// Auto-enables the HiDPI plist override for external 2K+ displays that don't have it
    /// yet, so a new monitor "just works". Skipped when the user turned HiDPI off for this
    /// monitor, or when it would need an admin password (never prompt unasked).
    private func autoEnableHiDPIIfNeeded(for display: DisplayInfo) {
        let vendor = display.vendorNumber
        let product = display.modelNumber
        guard vendor != 0, product != 0 else { return }

        let hiDPI = HiDPIService.shared
        guard !hiDPI.isHiDPIEnabled(vendor: vendor, product: product),
              hiDPI.allowsAutoEnable(vendor: vendor, product: product) else { return }

        // Determine native resolution from available modes
        let (nativeW, nativeH) = display.nativeResolution

        // Only auto-enable for 2K+ displays (width >= 2560 or total pixels >= 2560*1440)
        guard nativeW >= 2560 || (nativeW * nativeH >= 2560 * 1440) else { return }

#if DEBUG
        print("[DisplayManager] Auto-enabling HiDPI for \(display.name) (\(nativeW)×\(nativeH), vendor=\(vendor), product=\(product))")
#endif
        if hiDPI.enableHiDPI(vendor: vendor, product: product, nativeWidth: nativeW, nativeHeight: nativeH) == nil {
            hiDPI.refreshModes(for: display)
        }
    }
}
