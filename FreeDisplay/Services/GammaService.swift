import AppKit
import CoreGraphics
@preconcurrency import ColorSync

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

/// A display's calibration curve from its ColorSync profile's `vcgt` tag, sampled at 256
/// points per channel. ColorSync loads it into the display's transfer table; writing the
/// table replaces it, so GammaService composes its own curve on top of this one.
struct CalibrationCurve: Equatable {
    static let sampleCount = 256

    var channels: [[Double]]   // red, green, blue; each `sampleCount` values in 0…1

    /// The curve's output for `channel` at input `x` (0…1), linearly interpolated.
    func value(channel: Int, at x: Double) -> Double {
        let samples = channels[channel]
        let position = max(0, min(1, x)) * Double(samples.count - 1)
        let index = Int(position)
        guard index < samples.count - 1 else { return samples[samples.count - 1] }
        let fraction = position - Double(index)
        return samples[index] + (samples[index + 1] - samples[index]) * fraction
    }

    /// Parses a `vcgt` tag (with or without its 8-byte type header). Returns nil for a
    /// malformed tag and for an identity curve (nothing to compose with).
    ///
    ///   gammaType 0, table:   channels (UInt16), entryCount (UInt16), entrySize (UInt16: 1 or 2),
    ///                         then big-endian entries, channel after channel
    ///   gammaType 1, formula: gamma, min, max per channel (s15Fixed16), red, green, blue
    static func parse(vcgt data: Data) -> CalibrationCurve? {
        let bytes = [UInt8](data)
        var offset = 0
        if bytes.count >= 4, bytes[0] == 0x76, bytes[1] == 0x63, bytes[2] == 0x67, bytes[3] == 0x74 {
            offset = 8  // 'vcgt' signature + reserved
        }
        func uint16(_ at: Int) -> Int? {
            at + 2 <= bytes.count ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : nil
        }
        func uint32(_ at: Int) -> UInt32? {
            guard at + 4 <= bytes.count else { return nil }
            return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
        }
        func fixed(_ at: Int) -> Double? {
            uint32(at).map { Double(Int32(bitPattern: $0)) / 65536.0 }
        }

        var channels: [[Double]] = []
        switch uint32(offset) {
        case 0?:
            guard let count = uint16(offset + 4), let entries = uint16(offset + 6), let size = uint16(offset + 8),
                  count == 1 || count == 3, entries >= 2, size == 1 || size == 2 else { return nil }
            let start = offset + 10
            guard start + count * entries * size <= bytes.count else { return nil }
            let maxValue = size == 1 ? 255.0 : 65535.0
            for channel in 0..<count {
                var raw: [Double] = []
                raw.reserveCapacity(entries)
                for entry in 0..<entries {
                    let at = start + (channel * entries + entry) * size
                    let value = size == 1 ? Int(bytes[at]) : Int(bytes[at]) << 8 | Int(bytes[at + 1])
                    raw.append(Double(value) / maxValue)
                }
                channels.append(resample(raw))
            }
            if count == 1 { channels = [channels[0], channels[0], channels[0]] }
        case 1?:
            for channel in 0..<3 {
                let base = offset + 4 + channel * 12
                guard let gamma = fixed(base), let low = fixed(base + 4), let high = fixed(base + 8),
                      gamma > 0 else { return nil }
                channels.append((0..<sampleCount).map {
                    low + (high - low) * pow(Double($0) / Double(sampleCount - 1), gamma)
                })
            }
        default:
            return nil
        }

        channels = channels.map { $0.map { max(0, min(1, $0)) } }
        let isIdentity = channels.allSatisfy { samples in
            samples.indices.allSatisfy { abs(samples[$0] - Double($0) / Double(sampleCount - 1)) < 0.5 / 255 }
        }
        return isIdentity ? nil : CalibrationCurve(channels: channels)
    }

    private static func resample(_ raw: [Double]) -> [Double] {
        guard raw.count != sampleCount else { return raw }
        return (0..<sampleCount).map { index in
            let position = Double(index) / Double(sampleCount - 1) * Double(raw.count - 1)
            let lower = Int(position)
            guard lower < raw.count - 1 else { return raw[raw.count - 1] }
            let fraction = position - Double(lower)
            return raw[lower] + (raw[lower + 1] - raw[lower]) * fraction
        }
    }
}

/// The only writer of display transfer functions (`CGSetDisplayTransferByFormula/Table`).
/// Each write combines four inputs: the per-display image adjustment, the global night mode
/// tint, BrightnessService's software brightness factor and the profile's calibration curve.
@MainActor
final class GammaService: @unchecked Sendable {
    static let shared = GammaService()
    private init() {}

    /// The current image adjustment per display (including paused ones).
    private var activeAdjustments: [CGDirectDisplayID: GammaAdjustment] = [:]

    /// Displays whose transfer function FreeDisplay has changed from the profile's own curve.
    /// Only these are written when they return to neutral and restored at quit, so displays
    /// FreeDisplay never touched (and other processes' gamma) are left alone.
    private var modifiedDisplays: Set<CGDirectDisplayID> = []

    /// Calibration curve per display (`.some(nil)`: the profile has none). Loaded lazily.
    private var calibrationCurves: [CGDirectDisplayID: CalibrationCurve?] = [:]

    /// Debounced saving of adjustments (slider changes apply live, saving waits for a pause).
    private var saveTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var pendingSaves: [CGDirectDisplayID: () -> Void] = [:]

    // MARK: - Night Mode Tint

    private static let neutralTint = (r: 1.0, g: 1.0, b: 1.0)

    /// Global per-channel white-point multiplier set by NightModeService.
    private var nightTint = GammaService.neutralTint

    var isNightTintActive: Bool {
        nightTint != Self.neutralTint
    }

    /// Sets the night tint and rewrites every online display so it takes effect immediately.
    func setNightTint(r: Double, g: Double, b: Double) {
        nightTint = (r, g, b)
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

    // MARK: - Image adjustments

    /// The adjustment to show in the UI: the live one, else the saved one.
    func currentAdjustment(for displayID: CGDirectDisplayID) -> GammaAdjustment? {
        activeAdjustments[displayID] ?? loadSavedState(for: displayID)
    }

    /// Applies an image adjustment to a display right away and saves it shortly after (so a
    /// slider can call this on every change). A paused adjustment is kept but the display shows
    /// the unadjusted image (software brightness and night mode stay). A neutral adjustment
    /// removes the adjustment altogether.
    func apply(_ adj: GammaAdjustment, for displayID: CGDirectDisplayID) {
        guard !adj.isNeutral else {
            resetSingleDisplay(displayID)
            return
        }
        activeAdjustments[displayID] = adj
        scheduleSave(adj, for: displayID)
        write(adj.isPaused ? GammaAdjustment() : adj, for: displayID)
    }

    /// Removes the image adjustment for a single display (in memory and saved) and rewrites
    /// its transfer function without it. Software brightness and night mode stay applied.
    /// Use this instead of the global `CGDisplayRestoreColorSyncSettings()`. It does not touch
    /// the display's ColorSync profile.
    func resetSingleDisplay(_ displayID: CGDirectDisplayID) {
        activeAdjustments.removeValue(forKey: displayID)
        saveTasks.removeValue(forKey: displayID)?.cancel()
        pendingSaves.removeValue(forKey: displayID)
        UserDefaults.standard.removeObject(forKey: stateKey(for: displayID))
        write(GammaAdjustment(), for: displayID)
    }

    // MARK: - Reapplying

    /// Rewrites the display's transfer function from the current state: the image
    /// adjustment (neutral if none or paused), the night tint and software brightness.
    func reapply(for displayID: CGDirectDisplayID) {
        let adj = activeAdjustments[displayID]
        write(adj.map { $0.isPaused ? GammaAdjustment() : $0 } ?? GammaAdjustment(), for: displayID)
    }

    /// Re-applies the display's state after wake, reconnect, launch, a mode or profile change
    /// (the system rewrites transfer tables then). Loads the saved adjustment the first time.
    /// Cheap and idempotent: displays with nothing to apply are left alone.
    func reapplyIfNeeded(for displayID: CGDirectDisplayID) {
        if activeAdjustments[displayID] == nil, let saved = loadSavedState(for: displayID), !saved.isNeutral {
            activeAdjustments[displayID] = saved
        }
        let hasAdjustment = activeAdjustments[displayID].map { !$0.isPaused } ?? false
        let hasSoftwareBrightness = BrightnessService.shared.effectiveSoftwareBrightness(for: displayID) != nil
        guard hasAdjustment || hasSoftwareBrightness || isNightTintActive
                || modifiedDisplays.contains(displayID) else { return }
        reapply(for: displayID)
    }

    // MARK: - Lifecycle

    /// Drops in-memory state for a display ID that was removed or now belongs to another
    /// monitor. Saved (UUID-keyed) adjustments stay and come back with the right monitor.
    func forgetDisplay(_ displayID: CGDirectDisplayID) {
        flushSave(for: displayID)
        activeAdjustments.removeValue(forKey: displayID)
        modifiedDisplays.remove(displayID)
        calibrationCurves.removeValue(forKey: displayID)
    }

    /// The display profile may have changed (new profile, wake): read calibration curves again.
    func invalidateCalibration() {
        calibrationCurves.removeAll()
    }

    /// At quit: saves pending adjustments and gives every display FreeDisplay changed its
    /// profile's own curve back. A process that never wrote a transfer function (e.g. a
    /// duplicate launch that quits right away) touches nothing.
    func restoreSystemCurves() {
        for displayID in Array(pendingSaves.keys) { flushSave(for: displayID) }
        for displayID in modifiedDisplays {
            writeProfileCurve(for: displayID)
        }
        modifiedDisplays.removeAll()
    }

    // MARK: - Persistence

    private func stateKey(for displayID: CGDirectDisplayID) -> String {
        let uuid = DisplayManagerAccessor.shared.displays.first { $0.displayID == displayID }?.displayUUID
            ?? DisplayInfo.uuidString(for: displayID)
        return "fd.GammaService.savedAdjustment.\(uuid)"
    }

    private func scheduleSave(_ adj: GammaAdjustment, for displayID: CGDirectDisplayID) {
        let key = stateKey(for: displayID)
        pendingSaves[displayID] = {
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
            UserDefaults.standard.set(dict, forKey: key)
        }
        saveTasks[displayID]?.cancel()
        saveTasks[displayID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSave(for: displayID)
        }
    }

    private func flushSave(for displayID: CGDirectDisplayID) {
        saveTasks.removeValue(forKey: displayID)?.cancel()
        pendingSaves.removeValue(forKey: displayID)?()
    }

    private func loadSavedState(for displayID: CGDirectDisplayID) -> GammaAdjustment? {
        guard let dict = UserDefaults.standard.dictionary(forKey: stateKey(for: displayID)) else { return nil }
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

    /// Writes the display's transfer function: `adj` combined with the night tint, the
    /// software brightness factor and the profile's calibration curve. When all of them are
    /// neutral, the profile's own curve is restored (once) instead.
    private func write(_ adj: GammaAdjustment, for displayID: CGDirectDisplayID) {
        let brightnessFactor = BrightnessService.shared.effectiveSoftwareBrightness(for: displayID) ?? 1.0
        let tint = nightTint

        if adj.isNeutral && brightnessFactor >= 1.0 && tint == Self.neutralTint {
            if modifiedDisplays.remove(displayID) != nil {
                writeProfileCurve(for: displayID)
            }
            return
        }
        modifiedDisplays.insert(displayID)

        var p = channelParams(for: adj)
        // Scale both ends of each channel so inverted curves are dimmed and tinted too.
        let r = brightnessFactor * tint.r
        let g = brightnessFactor * tint.g
        let b = brightnessFactor * tint.b
        p.rLo *= r; p.rHi *= r
        p.gLo *= g; p.gHi *= g
        p.bLo *= b; p.bHi *= b

        let calibration = calibrationCurve(for: displayID)
        if calibration != nil || adj.quantizationLevels < 256 || p.exceedsUnitRange {
            writeTable(p, levels: adj.quantizationLevels, calibration: calibration, for: displayID)
        } else {
            CGSetDisplayTransferByFormula(displayID,
                CGGammaValue(p.rLo), CGGammaValue(p.rHi), CGGammaValue(p.rGam),
                CGGammaValue(p.gLo), CGGammaValue(p.gHi), CGGammaValue(p.gGam),
                CGGammaValue(p.bLo), CGGammaValue(p.bHi), CGGammaValue(p.bGam))
        }
    }

    /// The transfer function ColorSync itself would set: the profile's calibration curve,
    /// or identity when it has none.
    private func writeProfileCurve(for displayID: CGDirectDisplayID) {
        if let calibration = calibrationCurve(for: displayID) {
            var red = calibration.channels[0].map { CGGammaValue($0) }
            var green = calibration.channels[1].map { CGGammaValue($0) }
            var blue = calibration.channels[2].map { CGGammaValue($0) }
            CGSetDisplayTransferByTable(displayID, UInt32(red.count), &red, &green, &blue)
        } else {
            CGSetDisplayTransferByFormula(displayID, 0, 1, 1, 0, 1, 1, 0, 1, 1)
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

    // MARK: - Table mode (quantization, out-of-range curves, calibration)

    /// Samples `final(x) = calibration(quantize(clamp(lo + (hi − lo) · x^gamma)))` per channel.
    private func writeTable(_ p: ChannelParams, levels: Int, calibration: CalibrationCurve?,
                            for displayID: CGDirectDisplayID) {
        let capacity = CalibrationCurve.sampleCount
        let quantize = levels < 256
        let steps = Double(max(2, min(255, levels)))

        var redTable   = [CGGammaValue](repeating: 0, count: capacity)
        var greenTable = [CGGammaValue](repeating: 0, count: capacity)
        var blueTable  = [CGGammaValue](repeating: 0, count: capacity)

        func sample(_ input: Double, lo: Double, hi: Double, gam: Double, channel: Int) -> CGGammaValue {
            var value = max(0.0, min(1.0, lo + (hi - lo) * pow(input, gam)))
            if quantize { value = floor(value * steps) / steps }
            if let calibration { value = calibration.value(channel: channel, at: value) }
            return CGGammaValue(value)
        }

        for i in 0..<capacity {
            let input = Double(i) / Double(capacity - 1)
            redTable[i]   = sample(input, lo: p.rLo, hi: p.rHi, gam: p.rGam, channel: 0)
            greenTable[i] = sample(input, lo: p.gLo, hi: p.gHi, gam: p.gGam, channel: 1)
            blueTable[i]  = sample(input, lo: p.bLo, hi: p.bHi, gam: p.bGam, channel: 2)
        }

        CGSetDisplayTransferByTable(displayID, UInt32(capacity), &redTable, &greenTable, &blueTable)
    }

    // MARK: - Calibration curve

    private func calibrationCurve(for displayID: CGDirectDisplayID) -> CalibrationCurve? {
        if let cached = calibrationCurves[displayID] { return cached }
        let curve = Self.loadCalibrationCurve(for: displayID)
        calibrationCurves[displayID] = .some(curve)
        return curve
    }

    /// Reads the `vcgt` tag of the display's active ColorSync profile.
    private static func loadCalibrationCurve(for displayID: CGDirectDisplayID) -> CalibrationCurve? {
        var profile = ColorSyncProfileCreateWithDisplayID(displayID)?.takeRetainedValue()
        if profile == nil, let data = CGDisplayCopyColorSpace(displayID).copyICCData() {
            profile = ColorSyncProfileCreate(data, nil)?.takeRetainedValue()
        }
        guard let profile,
              let tag = ColorSyncProfileCopyTag(profile, "vcgt" as CFString)?.takeRetainedValue() else { return nil }
        return CalibrationCurve.parse(vcgt: tag as Data)
    }

    // MARK: - Helpers

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        return Array(displays.prefix(Int(displayCount)))
    }
}
