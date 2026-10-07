import Foundation
import IOKit
import IOKit.graphics
import CoreGraphics

// MARK: - BrightnessAnimator

/// Smooth brightness transition for a single display. Starting a new animation cancels the
/// running one, so rapid presses stay responsive.
@MainActor
final class BrightnessAnimator {
    private var timer: Timer?
    private var step = 0
    private var steps = 0
    private var startValue = 0.0
    private var handler: ((Double, Bool) -> Void)?

    /// The value the running animation is heading to, or nil when idle.
    private(set) var target: Double?

    func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
        handler = nil
    }

    /// Animates from `from` to `to` in `steps` steps over `duration` seconds.
    /// `handler(value, isLast)` runs once per step on the main thread; the last step always
    /// passes `to` exactly.
    func animate(
        from: Double,
        to: Double,
        steps: Int,
        duration: TimeInterval,
        handler: @escaping (Double, Bool) -> Void
    ) {
        cancel()
        guard abs(to - from) > 0.001, steps > 1 else {
            handler(to, true)
            return
        }

        startValue = from
        target = to
        self.steps = steps
        step = 0
        self.handler = handler

        let timer = Timer(timeInterval: duration / Double(steps), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common: keep animating while a menu or other tracking loop runs.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let target, let handler else {
            cancel()
            return
        }
        step += 1
        let isLast = step >= steps
        let progress = Double(step) / Double(steps)
        let eased = 1.0 - pow(1.0 - progress, 2.0)  // ease-out
        if isLast { cancel() }
        handler(isLast ? target : startValue + (target - startValue) * eased, isLast)
    }
}

// MARK: - DisplayServices (private framework)

// Reads and sets a display's backlight (0.0–1.0): the built-in panel and Apple displays such as
// the Studio Display. Other monitors return an error (1000). Loaded with dlopen/dlsym.
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

/// Unified brightness control. Per display it picks one path and publishes it on
/// `DisplayInfo.brightnessControl`:
///   - native: DisplayServices (built-in panel, Apple displays); IOKit on old Intel Macs
///   - DDC: VCP 0x10 over I2C (DDCService)
///   - software: a dimming factor that GammaService multiplies into the transfer function
///
/// All state is main-actor isolated; DDC completions hop back to the main actor.
@MainActor
final class BrightnessService: @unchecked Sendable {
    static let shared = BrightnessService()
    private init() {}

    private static let brightnessVCP = DDCService.brightnessVCP
    /// Software dimming never goes below 5 % so the screen can't go black.
    private static let minimumSoftwareFactor = 0.05

    /// Runs DisplayServices / IOKit backlight calls off the main thread.
    private let nativeQueue = DispatchQueue(label: "com.freedisplay.brightness", qos: .userInitiated)

    /// Set when the user manually adjusts brightness; auto brightness skips updates for 30 s.
    private(set) var lastManualAdjustDate: Date?

    // MARK: Per-display state (keyed by display ID, dropped in forgetDisplay)

    private var animators: [CGDirectDisplayID: BrightnessAnimator] = [:]
    /// Software dimming factor (0.05–1). 1 = not dimmed; loaded from defaults on first use.
    private var softwareFactors: [CGDirectDisplayID: Double] = [:]
    /// DDC state: true = works, false = failed (software dimming until re-probed), nil = unknown.
    private var ddcWorks: [CGDirectDisplayID: Bool] = [:]
    /// The monitor's DDC maximum for VCP 0x10, used to scale 0–100 %.
    private var ddcMax: [CGDirectDisplayID: UInt16] = [:]
    /// Whether DisplayServices controls this external display's backlight.
    private var hasNativeBacklight: [CGDirectDisplayID: Bool] = [:]
    /// The newest brightness request per display. Outcomes of older requests are ignored, so a
    /// late DDC failure can't overwrite a newer value with software dimming.
    private var requestIDs: [CGDirectDisplayID: UInt64] = [:]
    private var nextRequestID: UInt64 = 0
    /// When a display in software mode last re-probed DDC.
    private var lastSoftwareReprobe: [CGDirectDisplayID: Date] = [:]
    /// Displays whose DDC maximum is being read before the first write, and the value to send
    /// once it is known.
    private var maxProbes: [CGDirectDisplayID: (value: Double, request: UInt64, isFinal: Bool)] = [:]
    /// Debounced persistence of brightness and the software factor.
    private var persistTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var pendingPersists: [CGDirectDisplayID: () -> Void] = [:]

    /// Last display add/remove/wake. DDC failures right after one don't count: the monitor
    /// may still be waking up or its service may not be registered yet.
    private var topologyChangedAt: Date = .distantPast

    // MARK: - Public API

    /// Reads the current brightness from the hardware (backlight or DDC) and publishes it, along
    /// with how the display is controlled. Waits for the read to finish.
    func refreshBrightness(for display: DisplayInfo) async {
        guard !display.isVirtual else { return }
        let displayID = display.displayID
        let request = requestIDs[displayID]

        if await usesNativeBacklight(display) {
            let allowIOKit = display.isBuiltin
            let value = await withCheckedContinuation { continuation in
                nativeQueue.async {
                    continuation.resume(returning: Self.readNativeBrightness(displayID, allowIOKit: allowIOKit))
                }
            }
            publishControl(for: display)
            // Software dimming saved before this display was known to have a backlight (older
            // versions dimmed Apple displays in software) would stay on with no control left.
            if !display.isBuiltin, effectiveSoftwareBrightness(for: displayID) != nil {
                clearSoftwareBrightness(for: displayID)
            }
            if let value, requestIDs[displayID] == request {
                display.brightness = value
            }
            return
        }

        if ddcWorks[displayID] == false {
            // Software mode: re-probe DDC at most once a minute, so one failed burst (a monitor
            // still waking up) doesn't disable hardware control until the next sleep.
            if let last = lastSoftwareReprobe[displayID], Date().timeIntervalSince(last) < 60 {
                publishControl(for: display)
                return
            }
            lastSoftwareReprobe[displayID] = Date()
        }

        let reply = await DDCService.shared.read(displayID: displayID, command: Self.brightnessVCP)
        // A read only says something when it succeeds: some monitors only accept writes, so a
        // failed read leaves the state undetermined (a failed write decides).
        if let reply, reply.max > 0 {
            ddcMax[displayID] = reply.max
            markDDCWorking(displayID)
            // Ignore the value if the user changed brightness while it was being read.
            if requestIDs[displayID] == request {
                display.brightness = min(100, Double(reply.current) / Double(reply.max) * 100)
            }
        }
        publishControl(for: display)
    }

    /// Sets brightness immediately (slider drags, presets). Cancels a running animation.
    func setBrightness(_ brightness: Double, for display: DisplayInfo, isAutoAdjust: Bool = false) {
        guard !display.isVirtual else { return }
        let clamped = max(0.0, min(100.0, brightness))
        if !isAutoAdjust { lastManualAdjustDate = Date() }
        animators[display.displayID]?.cancel()
        let request = beginRequest(for: display.displayID)
        display.brightness = clamped
        apply(clamped, to: display, request: request, isFinal: true)
    }

    /// Animates brightness from the display's current value to `targetBrightness` (keys,
    /// auto brightness). DDC gets 5 steps over 200 ms (writes are coalesced and spaced 50 ms
    /// apart); backlight and software dimming get 8.
    func setBrightnessSmooth(_ targetBrightness: Double, for display: DisplayInfo, isAutoAdjust: Bool = false) {
        guard !display.isVirtual else { return }
        let clamped = max(0.0, min(100.0, targetBrightness))
        let displayID = display.displayID
        if !isAutoAdjust { lastManualAdjustDate = Date() }
        let request = beginRequest(for: displayID)

        let isDDC = !display.isBuiltin && hasNativeBacklight[displayID] != true && ddcWorks[displayID] != false
        animator(for: displayID).animate(
            from: display.brightness, to: clamped, steps: isDDC ? 5 : 8, duration: 0.20
        ) { [weak self, weak display] value, isLast in
            guard let self, let display else { return }
            display.brightness = value
            self.apply(value, to: display, request: request, isFinal: isLast)
        }
    }

    /// Where brightness is heading: the running animation's target, else the current value.
    /// Key presses step from this so fast presses don't lose steps.
    func targetBrightness(for display: DisplayInfo) -> Double {
        animators[display.displayID]?.target ?? display.brightness
    }

    // MARK: - Lifecycle

    /// Drops everything kept for a display ID: the display was removed, or the ID now belongs
    /// to another monitor (which must not inherit this one's dimming or DDC state).
    func forgetDisplay(_ displayID: CGDirectDisplayID) {
        animators.removeValue(forKey: displayID)?.cancel()
        flushPersist(for: displayID)
        softwareFactors.removeValue(forKey: displayID)
        ddcWorks.removeValue(forKey: displayID)
        ddcMax.removeValue(forKey: displayID)
        hasNativeBacklight.removeValue(forKey: displayID)
        requestIDs.removeValue(forKey: displayID)
        lastSoftwareReprobe.removeValue(forKey: displayID)
        maxProbes.removeValue(forKey: displayID)
    }

    /// Forgets the DDC state so the next refresh probes again (after wake: one failure while a
    /// monitor was waking up must not be permanent). The published control stays until then.
    func invalidateDDCState(for displayID: CGDirectDisplayID) {
        ddcWorks.removeValue(forKey: displayID)
        ddcMax.removeValue(forKey: displayID)
        lastSoftwareReprobe.removeValue(forKey: displayID)
    }

    /// Called on display add/remove and wake.
    func noteTopologyChange() {
        topologyChangedAt = Date()
    }

    /// Writes pending debounced settings now (at quit).
    func flushPendingWrites() {
        for displayID in Array(pendingPersists.keys) { flushPersist(for: displayID) }
    }

    // MARK: - Software Brightness (Gamma Fallback)

    /// The software dimming factor (0.05–1) for a display, or nil when it isn't dimmed.
    /// Loads the saved factor on first use; never writes. GammaService reads this on every
    /// transfer-function write, so dimming is never lost or applied twice.
    func effectiveSoftwareBrightness(for displayID: CGDirectDisplayID) -> Double? {
        let factor: Double
        if let known = softwareFactors[displayID] {
            factor = known
        } else {
            let saved = UserDefaults.standard.object(forKey: softwareFactorKey(for: displayID)) as? Double
            factor = saved.map { max(Self.minimumSoftwareFactor, min(1.0, $0)) } ?? 1.0
            softwareFactors[displayID] = factor
        }
        return factor < 1.0 ? factor : nil
    }

    /// Dims a display through its transfer function (no hardware control available).
    /// brightness: 0–100 (%), floored at 5 %. GammaService is the only writer of transfer
    /// functions: this stores the factor and lets GammaService rewrite the curve with it.
    private func setSoftwareBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) {
        let factor = max(Self.minimumSoftwareFactor, min(1.0, brightness / 100.0))
        guard softwareFactors[displayID] != factor else { return }
        softwareFactors[displayID] = factor
        GammaService.shared.reapply(for: displayID)
    }

    /// Removes software dimming (once DDC turns out to work).
    private func clearSoftwareBrightness(for displayID: CGDirectDisplayID) {
        softwareFactors[displayID] = 1.0
        GammaService.shared.reapply(for: displayID)
        schedulePersist(for: displayID)
    }

    private func softwareFactorKey(for displayID: CGDirectDisplayID) -> String {
        "fd.softBrightness.\(uuid(for: displayID))"
    }

    // MARK: - Applying

    private func apply(_ value: Double, to display: DisplayInfo, request: UInt64, isFinal: Bool) {
        let displayID = display.displayID
        if display.isBuiltin || hasNativeBacklight[displayID] == true {
            let level = Float(value / 100.0)
            let allowIOKit = display.isBuiltin
            nativeQueue.async { Self.writeNativeBrightness(level, displayID, allowIOKit: allowIOKit) }
            return
        }

        schedulePersist(for: displayID)
        if ddcWorks[displayID] == false && !claimSoftwareReprobe(for: displayID) {
            setSoftwareBrightness(value, for: displayID)
        } else {
            writeDDC(value, for: display, request: request, isFinal: isFinal)
        }
    }

    /// In software mode, lets one write a minute try DDC again (a monitor that failed while
    /// waking up recovers without the panel being opened). Returns true if this write probes.
    private func claimSoftwareReprobe(for displayID: CGDirectDisplayID) -> Bool {
        if let last = lastSoftwareReprobe[displayID], Date().timeIntervalSince(last) < 60 { return false }
        lastSoftwareReprobe[displayID] = Date()
        return true
    }

    private func writeDDC(_ value: Double, for display: DisplayInfo, request: UInt64, isFinal: Bool) {
        let displayID = display.displayID
        guard let maximum = ddcMax[displayID] else {
            // Unknown range: read it before the first write (assuming 100 would cap a monitor
            // with a 0–255 range at 39 %). Later values replace the one waiting.
            let isProbing = maxProbes[displayID] != nil
            maxProbes[displayID] = (value, request, isFinal)
            guard !isProbing else { return }
            Task { @MainActor [weak self, weak display] in
                let reply = await DDCService.shared.read(displayID: displayID, command: Self.brightnessVCP)
                guard let self, let display,
                      let pending = self.maxProbes.removeValue(forKey: displayID) else { return }
                if let reply, reply.max > 0 {
                    self.ddcMax[displayID] = reply.max
                    self.markDDCWorking(displayID)
                } else {
                    self.ddcMax[displayID] = 100
                }
                self.writeDDC(pending.value, for: display, request: pending.request, isFinal: pending.isFinal)
            }
            return
        }

        let raw = UInt16((value / 100.0 * Double(maximum)).rounded())
        DDCService.shared.writeAsync(displayID: displayID, command: Self.brightnessVCP, value: raw) { outcome in
            Task { @MainActor in
                BrightnessService.shared.handleDDCWrite(outcome, value: value, displayID: displayID,
                                                        request: request, isFinal: isFinal)
            }
        }
    }

    private func handleDDCWrite(_ outcome: DDCWriteOutcome, value: Double, displayID: CGDirectDisplayID,
                                request: UInt64, isFinal: Bool) {
        switch outcome {
        case .superseded:
            return  // the newer write reports its own outcome
        case .success:
            markDDCWorking(displayID)
        case .failure:
            // Only the newest request decides, and only at its final value (an animation's
            // earlier steps are followed by its last one).
            guard isFinal, requestIDs[displayID] == request else { return }
            // Right after a display change or wake the monitor may still be waking up: dim in
            // software so the change shows, but leave DDC undetermined (the next successful
            // write clears the dimming).
            if Date().timeIntervalSince(topologyChangedAt) > 5 {
                ddcWorks[displayID] = false
                lastSoftwareReprobe[displayID] = Date()
                publishControl(for: displayID)
            }
            setSoftwareBrightness(value, for: displayID)
            schedulePersist(for: displayID)
#if DEBUG
            print("[BrightnessService] DDC unavailable for display \(displayID), using software dimming")
#endif
        }
    }

    /// Records that DDC works. Software dimming left over from an earlier DDC failure would
    /// stack on top of the hardware brightness, so it is cleared.
    private func markDDCWorking(_ displayID: CGDirectDisplayID) {
        guard ddcWorks[displayID] != true else { return }
        ddcWorks[displayID] = true
        lastSoftwareReprobe.removeValue(forKey: displayID)
        publishControl(for: displayID)
        if effectiveSoftwareBrightness(for: displayID) != nil {
            clearSoftwareBrightness(for: displayID)
        }
    }

    // MARK: - Helpers

    private func beginRequest(for displayID: CGDirectDisplayID) -> UInt64 {
        nextRequestID &+= 1
        requestIDs[displayID] = nextRequestID
        return nextRequestID
    }

    private func animator(for displayID: CGDirectDisplayID) -> BrightnessAnimator {
        if let existing = animators[displayID] { return existing }
        let animator = BrightnessAnimator()
        animators[displayID] = animator
        return animator
    }

    private func display(for displayID: CGDirectDisplayID) -> DisplayInfo? {
        DisplayManagerAccessor.shared.displays.first { $0.displayID == displayID }
    }

    private func uuid(for displayID: CGDirectDisplayID) -> String {
        display(for: displayID)?.displayUUID ?? DisplayInfo.uuidString(for: displayID)
    }

    private func publishControl(for displayID: CGDirectDisplayID) {
        if let display = display(for: displayID) { publishControl(for: display) }
    }

    private func publishControl(for display: DisplayInfo) {
        let displayID = display.displayID
        let control: BrightnessControl?
        if display.isBuiltin || hasNativeBacklight[displayID] == true {
            control = .native
        } else {
            control = ddcWorks[displayID].map { $0 ? .ddc : .software }
        }
        if let control, display.brightnessControl != control {
            display.brightnessControl = control
        }
    }

    /// Whether the display's backlight is controlled through DisplayServices. Probed once per
    /// external display: DisplayServices only succeeds for displays with a native backlight.
    private func usesNativeBacklight(_ display: DisplayInfo) async -> Bool {
        if display.isBuiltin { return true }
        let displayID = display.displayID
        if let known = hasNativeBacklight[displayID] { return known }
        let supported = await withCheckedContinuation { continuation in
            nativeQueue.async {
                continuation.resume(returning: Self.readNativeBrightness(displayID, allowIOKit: false) != nil)
            }
        }
        hasNativeBacklight[displayID] = supported
        return supported
    }

    /// Saves the display's brightness and software factor half a second after the last change
    /// instead of on every slider tick or animation step.
    private func schedulePersist(for displayID: CGDirectDisplayID) {
        guard let display = display(for: displayID) else { return }
        let uuid = display.displayUUID
        pendingPersists[displayID] = { [weak self, weak display] in
            guard let self else { return }
            if let display {
                SettingsService.shared.setBrightness(display.brightness, forDisplayUUID: uuid)
            }
            let key = "fd.softBrightness.\(uuid)"
            if let factor = self.softwareFactors[displayID], factor < 1.0 {
                UserDefaults.standard.set(factor, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        persistTasks[displayID]?.cancel()
        persistTasks[displayID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPersist(for: displayID)
        }
    }

    private func flushPersist(for displayID: CGDirectDisplayID) {
        persistTasks.removeValue(forKey: displayID)?.cancel()
        pendingPersists.removeValue(forKey: displayID)?()
    }

    // MARK: - Native backlight (thread-safe, called on nativeQueue)

    /// Brightness of the built-in display (0.0–1.0), or nil when there is none (or the lid is
    /// closed) or it can't be read. Safe to call from any thread.
    nonisolated static func readBuiltinBrightness() -> Double? {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        guard let builtinID = displays.prefix(Int(displayCount)).first(where: { CGDisplayIsBuiltin($0) != 0 }),
              let percent = readNativeBrightness(builtinID, allowIOKit: true) else { return nil }
        return percent / 100.0
    }

    /// 0–100 from DisplayServices; IOKit on old Intel Macs (built-in panel only).
    private nonisolated static func readNativeBrightness(_ displayID: CGDirectDisplayID, allowIOKit: Bool) -> Double? {
        if let get = _DisplayServicesGetBrightness {
            var value: Float = 0
            if get(displayID, &value) == 0 {
                return Double(min(1, max(0, value))) * 100.0
            }
        }
        guard allowIOKit, let service = CGHelpers.framebufferPort(for: displayID) else { return nil }
        var value: Float = 0
        guard IODisplayGetFloatParameter(service, 0, "brightness" as CFString, &value) == KERN_SUCCESS else {
            return nil
        }
        return Double(min(1, max(0, value))) * 100.0
    }

    private nonisolated static func writeNativeBrightness(_ value: Float, _ displayID: CGDirectDisplayID, allowIOKit: Bool) {
        if let set = _DisplayServicesSetBrightness, set(displayID, value) == 0 {
            return
        }
        // The framebuffer port of this very display; never another display's service.
        guard allowIOKit, let service = CGHelpers.framebufferPort(for: displayID) else { return }
        _ = IODisplaySetFloatParameter(service, 0, "brightness" as CFString, value)
    }
}
