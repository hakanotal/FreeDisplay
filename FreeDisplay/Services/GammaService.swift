import AppKit
import CoreGraphics

/// Per-display software image adjustment parameters.
/// All slider values are in the range -100...+100 with 0 = neutral,
/// except quantizationLevels (2...256, 256 = no quantization).
struct GammaAdjustment: Equatable {
    var contrast: Double = 0.0          // -100 to +100, 0 = neutral
    var gammaVal: Double = 0.0          // -100 to +100, 0 = neutral (gamma exponent 1.0)
    var gain: Double = 0.0              // -100 to +100, 0 = neutral (multiplier 1.0)
    var colorTemperature: Double = 0.0  // -100 to +100, 0 = neutral (6500 K)
    var rGamma: Double = 0.0            // per-channel gamma offset
    var gGamma: Double = 0.0
    var bGamma: Double = 0.0
    var rGain: Double = 0.0             // per-channel gain offset
    var gGain: Double = 0.0
    var bGain: Double = 0.0
    var quantizationLevels: Int = 256   // 256 = no quantization
    var isInverted: Bool = false
    var isPaused: Bool = false

    /// True when no slider or toggle changes the image (the paused flag is ignored).
    var isNeutral: Bool {
        contrast == 0 && gammaVal == 0 && gain == 0 && colorTemperature == 0 &&
        rGamma == 0 && gGamma == 0 && bGamma == 0 &&
        rGain == 0 && gGain == 0 && bGain == 0 &&
        quantizationLevels >= 256 && !isInverted
    }
}

/// The only writer of display transfer functions (`CGSetDisplayTransferByFormula/Table`).
/// Each write combines three inputs: the per-display image adjustment, the global night
/// mode tint and BrightnessService's per-display software brightness factor.
final class GammaService: @unchecked Sendable {
    static let shared = GammaService()
    private var terminateObserver: NSObjectProtocol?
    private let adjustmentsLock = NSLock()

    /// Set once this process writes a transfer function (guarded by adjustmentsLock).
    /// A process that never wrote one (e.g. a duplicate launch that quits right away)
    /// must not reset the tables another instance owns.
    private var hasWrittenTransfer = false

    private init() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restoreIdentityOnQuit()
        }
    }

    deinit {
        if let obs = terminateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func restoreIdentityOnQuit() {
        guard adjustmentsLock.withLock({ hasWrittenTransfer }) else { return }
        for displayID in onlineDisplayIDs() {
            let size = 256
            var r = (0..<size).map { CGGammaValue($0) / CGGammaValue(size - 1) }
            var g = r; var b = r
            CGSetDisplayTransferByTable(displayID, UInt32(size), &r, &g, &b)
        }
    }

    // MARK: - Active Adjustment Tracking

    /// The current image adjustment per display (including paused ones).
    private var activeAdjustments: [CGDirectDisplayID: GammaAdjustment] = [:]

    /// The adjustment to show in the UI: the live one, else the saved one.
    func currentAdjustment(for displayID: CGDirectDisplayID) -> GammaAdjustment? {
        adjustmentsLock.withLock { activeAdjustments[displayID] } ?? loadSavedState(for: displayID)
    }

    /// Rewrites the display's transfer function from the current state: the image
    /// adjustment (neutral if none or paused), the night tint and software brightness.
    func reapply(for displayID: CGDirectDisplayID) {
        let adj = adjustmentsLock.withLock { activeAdjustments[displayID] }
        if let adj, !adj.isPaused {
            applyInternal(adj, for: displayID)
        } else {
            applyInternal(GammaAdjustment(), for: displayID)
        }
    }

    // MARK: - Night Mode Tint

    private static let neutralTint = (r: 1.0, g: 1.0, b: 1.0)

    /// Global per-channel white-point multiplier set by NightModeService (guarded by adjustmentsLock).
    private var nightTint = GammaService.neutralTint

    var isNightTintActive: Bool {
        adjustmentsLock.withLock { nightTint != Self.neutralTint }
    }

    /// Sets the night tint and rewrites every online display so it takes effect immediately.
    /// Displays without an image adjustment get a neutral formula (tint × software brightness),
    /// which is the identity curve once the tint returns to neutral.
    func setNightTint(r: Double, g: Double, b: Double) {
        adjustmentsLock.withLock { nightTint = (r, g, b) }
        for displayID in onlineDisplayIDs() {
            reapply(for: displayID)
        }
    }

    /// Per-channel multipliers for a colour temperature in kelvin, normalised so 6500 K → (1, 1, 1).
    func whitePointFactors(kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let (r, g, b) = kelvinToRGB(kelvin)
        let (rN, gN, bN) = kelvinToRGB(6500.0)
        return (
            rN > 0 ? r / rN : r,
            gN > 0 ? g / gN : g,
            bN > 0 ? b / bN : b
        )
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        return Array(displays.prefix(Int(displayCount)))
    }

    /// Scales each channel's output range by the night tint and the software brightness
    /// factor. Both ends are scaled so inverted curves are dimmed and tinted too.
    private func applyTintAndBrightness(_ p: inout ChannelParams, for displayID: CGDirectDisplayID) {
        let tint = adjustmentsLock.withLock { nightTint }
        let brightnessFactor = max(0.05, BrightnessService.shared.currentSoftwareBrightness(for: displayID) ?? 1.0)
        let r = brightnessFactor * tint.r
        let g = brightnessFactor * tint.g
        let b = brightnessFactor * tint.b
        p.rLo *= r; p.rHi *= r
        p.gLo *= g; p.gHi *= g
        p.bLo *= b; p.bHi *= b
    }

    // MARK: - Public API

    /// Applies an image adjustment to a display and saves it. A paused adjustment is kept
    /// but the display shows the unadjusted image (software brightness and night mode stay).
    /// A neutral adjustment removes the adjustment altogether.
    func apply(_ adj: GammaAdjustment, for displayID: CGDirectDisplayID) {
        guard !adj.isNeutral else {
            resetSingleDisplay(displayID)
            return
        }
        adjustmentsLock.withLock { activeAdjustments[displayID] = adj }
        saveState(adj, for: displayID)
        applyInternal(adj.isPaused ? GammaAdjustment() : adj, for: displayID)
    }

    /// Removes the image adjustment for a single display (in memory and saved) and rewrites
    /// its transfer function without it. Software brightness and night mode stay applied.
    /// Use this instead of the global `CGDisplayRestoreColorSyncSettings()`. It does not touch
    /// the display's ColorSync profile.
    func resetSingleDisplay(_ displayID: CGDirectDisplayID) {
        adjustmentsLock.withLock { _ = activeAdjustments.removeValue(forKey: displayID) }
        clearSavedState(for: displayID)
        applyInternal(GammaAdjustment(), for: displayID)
    }

    private static func stateKey(for displayID: CGDirectDisplayID) -> String {
        "fd.GammaService.savedAdjustment.\(DisplayInfo.uuidString(for: displayID))"
    }

    private func saveState(_ adj: GammaAdjustment, for displayID: CGDirectDisplayID) {
        let dict: [String: Any] = [
            "contrast": adj.contrast,
            "gammaVal": adj.gammaVal,
            "gain": adj.gain,
            "colorTemperature": adj.colorTemperature,
            "rGamma": adj.rGamma, "gGamma": adj.gGamma, "bGamma": adj.bGamma,
            "rGain": adj.rGain,   "gGain": adj.gGain,   "bGain": adj.bGain,
            "quantizationLevels": adj.quantizationLevels,
            "isInverted": adj.isInverted,
            "isPaused": adj.isPaused
        ]
        UserDefaults.standard.set(dict, forKey: GammaService.stateKey(for: displayID))
    }

    private func loadSavedState(for displayID: CGDirectDisplayID) -> GammaAdjustment? {
        guard let dict = UserDefaults.standard.dictionary(forKey: GammaService.stateKey(for: displayID)) else { return nil }
        var adj = GammaAdjustment()
        adj.contrast           = dict["contrast"]           as? Double ?? 0
        adj.gammaVal           = dict["gammaVal"]           as? Double ?? 0
        adj.gain               = dict["gain"]               as? Double ?? 0
        adj.colorTemperature   = dict["colorTemperature"]   as? Double ?? 0
        adj.rGamma             = dict["rGamma"]             as? Double ?? 0
        adj.gGamma             = dict["gGamma"]             as? Double ?? 0
        adj.bGamma             = dict["bGamma"]             as? Double ?? 0
        adj.rGain              = dict["rGain"]              as? Double ?? 0
        adj.gGain              = dict["gGain"]              as? Double ?? 0
        adj.bGain              = dict["bGain"]              as? Double ?? 0
        adj.quantizationLevels = dict["quantizationLevels"] as? Int    ?? 256
        adj.isInverted         = dict["isInverted"]         as? Bool   ?? false
        adj.isPaused           = dict["isPaused"]           as? Bool   ?? false
        return adj
    }

    private func clearSavedState(for displayID: CGDirectDisplayID) {
        UserDefaults.standard.removeObject(forKey: GammaService.stateKey(for: displayID))
    }

    /// Re-applies the display's state after wake from sleep, reconnect or launch (the system
    /// resets transfer tables). Prefers the live adjustment over the saved one. No-op when
    /// there is nothing to apply.
    func reapplyIfNeeded(for displayID: CGDirectDisplayID) {
        var adj = adjustmentsLock.withLock { activeAdjustments[displayID] }
        if adj == nil, let saved = loadSavedState(for: displayID), !saved.isNeutral {
            adjustmentsLock.withLock { activeAdjustments[displayID] = saved }
            adj = saved
        }
        let hasAdjustment = adj.map { !$0.isPaused } ?? false
        let hasSoftwareBrightness = BrightnessService.shared.currentSoftwareBrightness(for: displayID) != nil
        guard hasAdjustment || hasSoftwareBrightness || isNightTintActive else { return }
        reapply(for: displayID)
    }

    // MARK: - Transfer function

    private struct ChannelParams {
        var rLo, rHi, rGam: Double
        var gLo, gHi, gGam: Double
        var bLo, bHi, bGam: Double

        /// Positive contrast or gain pushes the range past [0, 1]. The formula API can't
        /// express that (the values get clamped and the change is lost), so the table path
        /// is used, which clips per sample.
        var exceedsUnitRange: Bool {
            [rLo, rHi, gLo, gHi, bLo, bHi].contains { $0 < 0 || $0 > 1 }
        }
    }

    private func applyInternal(_ adj: GammaAdjustment, for displayID: CGDirectDisplayID) {
        var p = channelParams(for: adj)
        // Incorporate software brightness and night tint so the three inputs never
        // overwrite each other's transfer function.
        applyTintAndBrightness(&p, for: displayID)
        adjustmentsLock.withLock { hasWrittenTransfer = true }
        if adj.quantizationLevels < 256 || p.exceedsUnitRange {
            applyTable(p, levels: adj.quantizationLevels, for: displayID)
        } else {
            CGSetDisplayTransferByFormula(displayID,
                CGGammaValue(p.rLo), CGGammaValue(p.rHi), CGGammaValue(p.rGam),
                CGGammaValue(p.gLo), CGGammaValue(p.gHi), CGGammaValue(p.gGam),
                CGGammaValue(p.bLo), CGGammaValue(p.bHi), CGGammaValue(p.bGam))
        }
    }

    private func channelParams(for adj: GammaAdjustment) -> ChannelParams {
        // ── Gamma exponent ──────────────────────────────────────────────
        // slider=0 → exp=1.0; +100 → 0.5 (brighter curve); -100 → 2.0 (darker)
        let globalGammaExp = pow(2.0, -adj.gammaVal / 100.0)
        let rGammaExp = globalGammaExp * pow(2.0, -adj.rGamma / 100.0)
        let gGammaExp = globalGammaExp * pow(2.0, -adj.gGamma / 100.0)
        let bGammaExp = globalGammaExp * pow(2.0, -adj.bGamma / 100.0)

        // ── Gain (output ceiling / brightness scale) ────────────────────
        // slider=0 → 1.0; +100 → 2.0; -100 → 0.0
        let globalGain = max(0.0, 1.0 + adj.gain / 100.0)
        let rGain = max(0.0, globalGain * (1.0 + adj.rGain / 100.0))
        let gGain = max(0.0, globalGain * (1.0 + adj.gGain / 100.0))
        let bGain = max(0.0, globalGain * (1.0 + adj.bGain / 100.0))

        // ── Color temperature ───────────────────────────────────────────
        let (tempR, tempG, tempB) = colorTempFactors(adj.colorTemperature)

        // ── Contrast (symmetric push/pull of min and max) ───────────────
        // ±100% → ±0.4 shift, widening/narrowing the output range
        let contrastShift = adj.contrast / 250.0

        var rLo = 0.0 - contrastShift
        var gLo = 0.0 - contrastShift
        var bLo = 0.0 - contrastShift
        var rHi = rGain * tempR + contrastShift
        var gHi = gGain * tempG + contrastShift
        var bHi = bGain * tempB + contrastShift

        // ── Inversion (swap min ↔ max per channel) ─────────────────────
        if adj.isInverted {
            swap(&rLo, &rHi)
            swap(&gLo, &gHi)
            swap(&bLo, &bHi)
        }

        // Not clamped here: the formula path only runs when everything is within [0, 1],
        // and the table path clamps per sample.
        return ChannelParams(
            rLo: rLo, rHi: rHi, rGam: rGammaExp,
            gLo: gLo, gHi: gHi, gGam: gGammaExp,
            bLo: bLo, bHi: bHi, bGam: bGammaExp)
    }

    // MARK: - Color temperature (Tanner Helland algorithm)

    /// Returns per-channel gain multipliers normalised so that 6500 K → (1, 1, 1).
    private func colorTempFactors(_ sliderValue: Double) -> (r: Double, g: Double, b: Double) {
        guard sliderValue != 0.0 else { return (1.0, 1.0, 1.0) }
        // positive slider = warmer (lower K); negative = cooler (higher K)
        let kelvin: Double
        if sliderValue > 0 {
            kelvin = 6500.0 - sliderValue / 100.0 * 4500.0  // 6500 K → 2000 K
        } else {
            kelvin = 6500.0 - sliderValue / 100.0 * 5500.0  // 6500 K → 12000 K
        }
        return whitePointFactors(kelvin: kelvin)
    }

    private func kelvinToRGB(_ kelvin: Double) -> (Double, Double, Double) {
        let temp = max(1000.0, min(40000.0, kelvin)) / 100.0

        let r: Double
        if temp <= 66 {
            r = 1.0
        } else {
            r = max(0, min(1, 1.292936186 * pow(temp - 60, -0.1332047592)))
        }

        let g: Double
        if temp <= 66 {
            g = max(0, min(1, 0.390081579 * log(temp) - 0.631841444))
        } else {
            g = max(0, min(1, 1.129890861 * pow(temp - 60, -0.0755148492)))
        }

        let b: Double
        if temp >= 66 {
            b = 1.0
        } else if temp <= 19 {
            b = 0.0
        } else {
            b = max(0, min(1, 0.543206789 * log(temp - 10) - 1.196254089))
        }

        return (r, g, b)
    }

    // MARK: - Table mode (quantization, out-of-range curves)

    private func applyTable(_ p: ChannelParams, levels: Int, for displayID: CGDirectDisplayID) {
        let capacity = 256
        let quantize = levels < 256
        let steps = Double(max(2, min(255, levels)))

        var redTable   = [CGGammaValue](repeating: 0, count: capacity)
        var greenTable = [CGGammaValue](repeating: 0, count: capacity)
        var blueTable  = [CGGammaValue](repeating: 0, count: capacity)

        for i in 0..<capacity {
            let input = Double(i) / Double(capacity - 1)

            func tableValue(lo: Double, hi: Double, gam: Double) -> CGGammaValue {
                let raw = lo + (hi - lo) * pow(input, gam)
                let clamped = max(0.0, min(1.0, raw))
                // Quantize to `levels` discrete steps
                return CGGammaValue(quantize ? floor(clamped * steps) / steps : clamped)
            }

            redTable[i]   = tableValue(lo: p.rLo, hi: p.rHi, gam: p.rGam)
            greenTable[i] = tableValue(lo: p.gLo, hi: p.gHi, gam: p.gGam)
            blueTable[i]  = tableValue(lo: p.bLo, hi: p.bHi, gam: p.bGam)
        }

        CGSetDisplayTransferByTable(displayID, UInt32(capacity),
                                    &redTable, &greenTable, &blueTable)
    }
}
