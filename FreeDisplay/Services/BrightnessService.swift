import Foundation
import IOKit
import IOKit.graphics
import CoreGraphics

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

// MARK: - BrightnessAnimator

/// Manages smooth brightness transitions for a single display.
/// Cancels any in-progress animation when a new one starts, so rapid presses stay responsive.
/// All methods must be called on the main thread.
final class BrightnessAnimator: @unchecked Sendable {
    private var timer: Timer?
    private var currentStep: Int = 0
    private var totalSteps: Int = 0
    private var startValue: Double = 0
    private var targetValue: Double = 0
    private var stepHandler: ((Double, Bool) -> Void)?

    /// Cancel any running animation immediately.
    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// Animate from `from` to `to` over `duration` seconds using `steps` discrete steps.
    /// `handler(value, isLast)` is called once per step on the main thread.
    /// Calling this cancels any previously running animation.
    func animate(
        from: Double,
        to: Double,
        steps: Int,
        duration: TimeInterval,
        handler: @escaping (Double, Bool) -> Void
    ) {
        cancel()

        // If from ≈ to, no animation needed — just apply final value.
        guard abs(to - from) > 0.001, steps > 1 else {
            handler(to, true)
            return
        }

        let clampedSteps = max(2, steps)
        currentStep = 0
        totalSteps = clampedSteps
        startValue = from
        targetValue = to
        stepHandler = handler
        let interval = duration / Double(clampedSteps)

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.currentStep += 1
            let progress = Double(self.currentStep) / Double(self.totalSteps)
            // Ease-out curve: smoother deceleration at the end
            let eased = 1.0 - pow(1.0 - progress, 2.0)
            let value = self.startValue + (self.targetValue - self.startValue) * eased
            let isLast = self.currentStep >= self.totalSteps
            if isLast {
                t.invalidate()
                self.timer = nil
            }
            // Always pass the exact target on the last step to avoid floating-point drift.
            self.stepHandler?(isLast ? self.targetValue : value, isLast)
            if isLast { self.stepHandler = nil }
        }
    }
}

// MARK: - DisplayServices (private framework)

// Reads and sets the built-in panel's brightness (0.0–1.0). Loaded with dlopen/dlsym.
// On Apple Silicon there are no IODisplayConnect services and CoreDisplay's
// GetUserBrightness returns 1.0, so this is the only working path there.
private let displayServicesPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

private let _DisplayServicesGetBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
    guard let handle = dlopen(displayServicesPath, RTLD_LAZY),
          let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
}()

private let _DisplayServicesSetBrightness: (@convention(c) (CGDirectDisplayID, Float) -> Int32)? = {
    guard let handle = dlopen(displayServicesPath, RTLD_LAZY),
          let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
}()

// MARK: - BrightnessService

final class BrightnessService: @unchecked Sendable {
    static let shared = BrightnessService()
    private init() {}

    private let queue = DispatchQueue(label: "com.freedisplay.brightness", qos: .userInitiated)

    // MARK: - Per-display Animators (main thread only)

    /// One animator per display. Accessed only on the main thread.
    private var animators: [CGDirectDisplayID: BrightnessAnimator] = [:]

    private func animator(for displayID: CGDirectDisplayID) -> BrightnessAnimator {
        if let existing = animators[displayID] { return existing }
        let a = BrightnessAnimator()
        animators[displayID] = a
        return a
    }

    /// Cancel any running brightness animation for a display.
    /// Call this before starting an instant (non-animated) change.
    @MainActor
    func cancelAnimation(for displayID: CGDirectDisplayID) {
        animators[displayID]?.cancel()
    }

    // MARK: - Manual Adjust Cooldown

    /// Set when the user manually adjusts brightness; auto-brightness skips updates for 30 s.
    private(set) var lastManualAdjustDate: Date? = nil
    private let manualAdjustLock = NSLock()

    // MARK: - Software Brightness Factors

    /// Stores the current software brightness factor per display (0.05–1.0).
    private var softwareBrightnessFactors: [CGDirectDisplayID: Double] = [:]
    private let softwareBrightnessLock = NSLock()

    private func softBrightnessKey(for displayID: CGDirectDisplayID) -> String {
        "fd.softBrightness.\(DisplayInfo.uuidString(for: displayID))"
    }

    private func loadSoftwareBrightness(for displayID: CGDirectDisplayID) -> Double? {
        let key = softBrightnessKey(for: displayID)
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.double(forKey: key)
    }

    /// Returns the current software brightness factor for a display, or nil if not set.
    func currentSoftwareBrightness(for displayID: CGDirectDisplayID) -> Double? {
        softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] }
    }

    // MARK: - DDC Availability Cache

    /// Tracks whether hardware DDC is available for each external display.
    /// nil  = not yet determined
    /// true = DDC read or write succeeded
    /// false = DDC write has failed; use software (gamma) fallback until re-probed (wake/reconnect)
    private var ddcAvailable: [CGDirectDisplayID: Bool] = [:]
    private let ddcAvailableLock = NSLock()

    /// Per-display DDC max brightness value reported by the monitor.
    /// Used to denormalize 0–100% into the display's native DDC range.
    private var ddcMaxBrightness: [CGDirectDisplayID: UInt16] = [:]

    /// Records that DDC works for a display. Software dimming left over from an earlier DDC
    /// failure would stack on top of the hardware brightness, so it is cleared.
    private func markDDCWorking(_ displayID: CGDirectDisplayID) {
        ddcAvailableLock.withLock { ddcAvailable[displayID] = true }
        let hasSoftwareDimming = currentSoftwareBrightness(for: displayID) != nil
            || UserDefaults.standard.object(forKey: softBrightnessKey(for: displayID)) != nil
        guard hasSoftwareDimming else { return }
        DispatchQueue.main.async { [weak self] in
            self?.clearSoftwareBrightness(for: displayID)
        }
    }

    // MARK: - Public API

    @MainActor
    func refreshBrightness(for display: DisplayInfo) async {
        let displayID = display.displayID

        if display.isBuiltin {
            let brightness = await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    continuation.resume(returning: self?.getInternalBrightness(displayID))
                }
            }
            if let b = brightness {
                display.brightness = b
            }
            return
        }

        // Displays known to have no DDC keep their software brightness value.
        let knownUnavailable = ddcAvailableLock.withLock { ddcAvailable[displayID] == false }
        guard !knownUnavailable else { return }

        DDCService.shared.readAsync(
            displayID: displayID,
            command: DDCService.brightnessVCP
        ) { [weak self] result in
            guard let self, let result, result.max > 0 else {
                // A failed read alone doesn't rule DDC out (some monitors only accept writes);
                // a failed write decides. Leave the state undetermined.
                return
            }
            let brightness = Double(result.current) / Double(result.max) * 100.0
            self.ddcAvailableLock.withLock { self.ddcMaxBrightness[displayID] = result.max }
            self.markDDCWorking(displayID)
            Task { @MainActor in display.brightness = brightness }
        }
    }

    @MainActor
    func setBrightness(_ brightness: Double, for display: DisplayInfo, isAutoAdjust: Bool = false) async {
        let clamped = max(0.0, min(100.0, brightness))
        let displayID = display.displayID

        // Record manual adjust time so auto-brightness can honour the cooldown period.
        if !isAutoAdjust {
            manualAdjustLock.withLock { lastManualAdjustDate = Date() }
        }

        display.brightness = clamped

        if display.isBuiltin {
            let value = Float(clamped / 100.0)
            queue.async { [weak self] in
                self?.setInternalBrightness(value, displayID: displayID)
            }
            return
        }

        SettingsService.shared.setBrightness(clamped, forDisplayUUID: display.displayUUID)

        let currentStatus: Bool? = ddcAvailableLock.withLock { ddcAvailable[displayID] }
        if currentStatus == false {
            // DDC known unavailable — go straight to software fallback
            setSoftwareBrightness(clamped, for: displayID)
            return
        }

        // Denormalize percentage to display's native DDC range.
        // If max is unknown, default to 100 (safe for most monitors).
        let knownMax: UInt16 = ddcAvailableLock.withLock {
            ddcMaxBrightness[displayID] ?? 100
        }
        let ddcValue = UInt16((clamped / 100.0) * Double(knownMax))

        // Attempt DDC write; if it fails, fall back to gamma table dimming
        DDCService.shared.writeAsync(
            displayID: displayID,
            command: DDCService.brightnessVCP,
            value: ddcValue
        ) { [weak self] success in
            guard let self else { return }
            if success {
                self.markDDCWorking(displayID)
            } else {
                self.ddcAvailableLock.withLock { self.ddcAvailable[displayID] = false }
                // Apply gamma-based software brightness as fallback (on the main thread)
                DispatchQueue.main.async { [weak self] in
                    self?.setSoftwareBrightness(clamped, for: displayID)
                }
                #if DEBUG
                print("[BrightnessService] DDC unavailable for display \(displayID), using software fallback")
                #endif
            }
        }
    }

    // MARK: - Smooth Brightness Transitions

    /// Animate brightness from the display's current value to `targetBrightness` smoothly.
    ///
    /// - For DDC displays: sends 5 DDC commands spaced ~40ms apart (200ms total).
    ///   DDC I2C commands are inherently slow (~40–50ms each), so 5 steps at 40ms intervals
    ///   fills the 200ms window without flooding the bus.
    /// - For software (gamma) brightness: 8 gamma table updates over 200ms give a visibly
    ///   smooth fade without perceptible frame drops.
    /// - For built-in displays: 8 writes over 200ms mirror the software path.
    ///
    /// Cancels any previously running animation for the same display, so rapid key presses
    /// always feel responsive — the animation re-targets from wherever it currently is.
    @MainActor
    func setBrightnessSmooth(
        _ targetBrightness: Double,
        for display: DisplayInfo,
        isAutoAdjust: Bool = false
    ) {
        let clamped = max(0.0, min(100.0, targetBrightness))
        let displayID = display.displayID
        let fromBrightness = display.brightness

        if !isAutoAdjust {
            manualAdjustLock.withLock { lastManualAdjustDate = Date() }
        }

        let anim = animator(for: displayID)

        if display.isBuiltin {
            anim.animate(from: fromBrightness, to: clamped, steps: 8, duration: 0.20) { [weak self, weak display] value, _ in
                guard let self, let display else { return }
                display.brightness = value
                let floatVal = Float(value / 100.0)
                self.queue.async { self.setInternalBrightness(floatVal, displayID: displayID) }
            }
            return
        }

        SettingsService.shared.setBrightness(clamped, forDisplayUUID: display.displayUUID)
        let currentStatus: Bool? = ddcAvailableLock.withLock { ddcAvailable[displayID] }

        if currentStatus == false {
            // Software (gamma) path: 8 steps over 200ms
            anim.animate(from: fromBrightness, to: clamped, steps: 8, duration: 0.20) { [weak self, weak display] value, _ in
                display?.brightness = value
                self?.setSoftwareBrightness(value, for: displayID)
            }
        } else {
            // DDC path: 5 steps over 200ms.
            // DDC I2C is slow (~40-50ms per command), so 5 steps at 40ms intervals
            // keeps the bus from overloading while giving smooth visible steps.
            let knownMax: UInt16 = ddcAvailableLock.withLock {
                ddcMaxBrightness[displayID] ?? 100
            }
            anim.animate(from: fromBrightness, to: clamped, steps: 5, duration: 0.20) { [weak self, weak display] value, isLast in
                display?.brightness = value
                let ddcValue = UInt16((value / 100.0) * Double(knownMax))
                DDCService.shared.writeAsync(
                    displayID: displayID,
                    command: DDCService.brightnessVCP,
                    value: ddcValue
                ) { [weak self] success in
                    guard let self else { return }
                    if success {
                        self.markDDCWorking(displayID)
                    } else if isLast {
                        // DDC failed — mark unavailable and apply software fallback
                        self.ddcAvailableLock.withLock { self.ddcAvailable[displayID] = false }
                        DispatchQueue.main.async { [weak self] in
                            self?.setSoftwareBrightness(clamped, for: displayID)
                        }
                        #if DEBUG
                        print("[BrightnessService] smooth DDC failed for \(displayID), using software fallback")
                        #endif
                    }
                }
            }
        }
    }

    // MARK: - Software Brightness (Gamma Fallback)

    /// Dims a display through its transfer function for displays where DDC is unavailable.
    /// brightness: 0–100 (percentage); never goes below 5% to avoid a black screen.
    /// GammaService is the only writer of transfer functions: this stores the factor and lets
    /// GammaService rewrite the curve with it (combined with image adjustments and night mode).
    func setSoftwareBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) {
        let factor = max(0.05, min(1.0, brightness / 100.0))
        let key = softBrightnessKey(for: displayID)
        if factor >= 1.0 {
            softwareBrightnessLock.withLock { _ = softwareBrightnessFactors.removeValue(forKey: displayID) }
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] = factor }
            UserDefaults.standard.set(factor, forKey: key)
        }
        GammaService.shared.reapply(for: displayID)
    }

    /// Removes software dimming for a display (e.g. once DDC turns out to work).
    func clearSoftwareBrightness(for displayID: CGDirectDisplayID) {
        softwareBrightnessLock.withLock { _ = softwareBrightnessFactors.removeValue(forKey: displayID) }
        UserDefaults.standard.removeObject(forKey: softBrightnessKey(for: displayID))
        GammaService.shared.reapply(for: displayID)
    }

    /// Returns whether DDC is available for the given display.
    /// nil means not yet determined (first use).
    func isDDCAvailable(for displayID: CGDirectDisplayID) -> Bool? {
        ddcAvailableLock.withLock { ddcAvailable[displayID] }
    }

    /// Clears DDC availability and max brightness cache, so the next change probes DDC again.
    /// Called when a display is removed and after wake.
    func invalidateDDCState(for displayID: CGDirectDisplayID) {
        ddcAvailableLock.withLock {
            ddcAvailable.removeValue(forKey: displayID)
            ddcMaxBrightness.removeValue(forKey: displayID)
        }
    }

    /// Re-applies the software brightness for a display after wake from sleep or hot-plug.
    /// Checks in-memory factor first; falls back to UserDefaults so restart is handled too.
    /// No-op if no saved factor < 1.0 exists.
    func reapplySoftwareBrightnessIfNeeded(for display: DisplayInfo) {
        let displayID = display.displayID
        let factor = currentSoftwareBrightness(for: displayID) ?? loadSoftwareBrightness(for: displayID)
        guard let f = factor, f < 1.0 else { return }
        setSoftwareBrightness(f * 100.0, for: displayID)
    }

    // MARK: - Built-in Display

    /// Brightness of the built-in display (0.0–1.0), or nil when there is none or it can't
    /// be read. Safe to call from any thread.
    func readBuiltinBrightness() -> Double? {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        guard let builtinID = displays.prefix(Int(displayCount)).first(where: { CGDisplayIsBuiltin($0) != 0 }),
              let percent = getInternalBrightness(builtinID) else { return nil }
        return percent / 100.0
    }

    /// 0–100. DisplayServices first; IOKit for older Intel Macs.
    private func getInternalBrightness(_ displayID: CGDirectDisplayID) -> Double? {
        if let get = _DisplayServicesGetBrightness {
            var value: Float = 0
            if get(displayID, &value) == 0 {
                return Double(min(1, max(0, value))) * 100.0
            }
        }
        return ioKitInternalBrightness()
    }

    private func setInternalBrightness(_ value: Float, displayID: CGDirectDisplayID) {
        if let set = _DisplayServicesSetBrightness, set(displayID, value) == 0 {
            return
        }
        ioKitSetInternalBrightness(value)
    }

    // MARK: - Built-in Display via IOKit (Intel fallback)

    private static nonisolated(unsafe) let ioDisplayBrightnessKey = "brightness" as CFString

    /// Returns the io_service_t for the built-in display using CGDisplayIOServicePort.
    /// Falls back to iterating IODisplayConnect services if CGDisplayIOServicePort returns null.
    /// Caller does NOT need to release — CGDisplayIOServicePort returns a non-retained port.
    private func builtinIOService() -> io_service_t? {
        // Find the built-in CGDirectDisplayID
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        guard let builtinID = (0..<Int(displayCount))
            .map({ displayIDs[$0] })
            .first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            return nil
        }

        // CGDisplayIOServicePort returns a non-retained service port (do not release)
        let servicePort = CGDisplayIOServicePort(builtinID)
        if servicePort != MACH_PORT_NULL && servicePort != 0 {
            return servicePort
        }

        return nil
    }

    private func ioKitInternalBrightness() -> Double? {
        // Primary: use CGDisplayIOServicePort to get the specific builtin display service
        if let servicePort = builtinIOService() {
            var value: Float = 0
            if IODisplayGetFloatParameter(
                servicePort, 0, Self.ioDisplayBrightnessKey, &value
            ) == KERN_SUCCESS {
                return Double(value) * 100.0
            }
        }

        // Fallback: iterate IODisplayConnect but only accept services that
        // correspond to a built-in display (matched via CGDisplayIOServicePort cross-check).
        // Build set of known external service ports to exclude them.
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        var externalPorts = Set<io_service_t>()
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if CGDisplayIsBuiltin(id) == 0 {
                let port = CGDisplayIOServicePort(id)
                if port != MACH_PORT_NULL && port != 0 {
                    externalPorts.insert(port)
                }
            }
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            // Skip services that are known external display ports
            guard !externalPorts.contains(service) else { continue }
            var value: Float = 0
            if IODisplayGetFloatParameter(
                service, 0, Self.ioDisplayBrightnessKey, &value
            ) == KERN_SUCCESS {
                return Double(value) * 100.0
            }
        }
        return nil
    }

    private func ioKitSetInternalBrightness(_ value: Float) {
        // Primary: use CGDisplayIOServicePort to target only the builtin display service
        if let servicePort = builtinIOService() {
            if IODisplaySetFloatParameter(
                servicePort, 0, Self.ioDisplayBrightnessKey, value
            ) == KERN_SUCCESS {
                #if DEBUG
                print("[BrightnessService] internal brightness set to \(value)")
                #endif
                return
            }
        }

        // Fallback: iterate IODisplayConnect, skipping known external ports
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        var externalPorts = Set<io_service_t>()
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if CGDisplayIsBuiltin(id) == 0 {
                let port = CGDisplayIOServicePort(id)
                if port != MACH_PORT_NULL && port != 0 {
                    externalPorts.insert(port)
                }
            }
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else {
            #if DEBUG
            print("[BrightnessService] setInternalBrightness: no builtin service responded")
            #endif
            return
        }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            guard !externalPorts.contains(service) else { continue }
            if IODisplaySetFloatParameter(
                service, 0, Self.ioDisplayBrightnessKey, value
            ) == KERN_SUCCESS {
                #if DEBUG
                print("[BrightnessService] internal brightness set to \(value)")
                #endif
                return
            }
        }
        #if DEBUG
        print("[BrightnessService] setInternalBrightness: no builtin service responded")
        #endif
    }
}
