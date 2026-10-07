import AppKit
import CoreGraphics

// MARK: - C Event Tap Callback

/// Global C callback for the CGEventTap. `userInfo` carries an Unmanaged<BrightnessKeyService>.
/// Runs on the tap's own thread (see `BrightnessKeyService.start`).
private func brightnessKeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<BrightnessKeyService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.handleEvent(type: type, event: event)
}

// MARK: - BrightnessKeyService

/// Intercepts macOS brightness keys and routes them to the display under the mouse cursor.
/// When the cursor is on an external display FreeDisplay controls, the key event is consumed
/// and that display's brightness is adjusted via BrightnessService. Otherwise (built-in panel,
/// Sidecar, AirPlay, virtual displays) the event passes through and macOS handles it.
///
/// The tap runs on a dedicated thread: it filters every media key in the session, so it must
/// never wait for a busy main thread (macOS would stall all media keys, then disable the tap).
@MainActor
final class BrightnessKeyService: @unchecked Sendable {
    static let shared = BrightnessKeyService()
    private init() {}

    // MARK: - NX Media Key Constants

    /// CGEventType raw value for NSSystemDefined / NX_SYSDEFINED events (media keys).
    private nonisolated static let systemDefinedEventType: UInt32 = 14
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS — the subtype value for media/function keys.
    private nonisolated static let auxControlButtonsSubtype: Int16 = 8
    private nonisolated static let brightnessUpKey = 2    // NX_KEYTYPE_BRIGHTNESS_UP
    private nonisolated static let brightnessDownKey = 3  // NX_KEYTYPE_BRIGHTNESS_DOWN

    /// Each key press moves brightness by 1/16 (≈ 6.25 %), matching macOS native behaviour.
    private static let brightnessStep: Double = 100.0 / 16.0

    // MARK: - State shared with the tap thread (guarded by `tapLock`)

    private nonisolated let tapLock = NSLock()
    private nonisolated(unsafe) var managedDisplayIDs: Set<CGDirectDisplayID> = []
    private nonisolated(unsafe) var tapPort: CFMachPort?
    private nonisolated(unsafe) var tapRunLoop: CFRunLoop?

    // MARK: - Main-actor state

    private var tapThread: Thread?
    /// Retained reference passed into the C callback. Released in stop().
    private var selfRetained: Unmanaged<BrightnessKeyService>?
    private var accessibilityObserver: NSObjectProtocol?
    private var retryTimer: Timer?

    // MARK: - Start / Stop

    /// Installs the event tap. Requires Accessibility permission; without it, retries when the
    /// permission changes (and every 10 s as a fallback) instead of giving up.
    /// Safe to call multiple times — a running tap will not be re-created.
    func start() {
        guard tapThread == nil else { return }

        let retained = Unmanaged.passRetained(self)
        // Try creating the tap directly — AXIsProcessTrusted can be unreliable
        // with ad-hoc signed Debug builds (TCC entry invalidates after each rebuild).
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << Self.systemDefinedEventType),
            callback: brightnessKeyEventCallback,
            userInfo: retained.toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            retained.release()
            waitForAccessibility()
            return
        }

        selfRetained = retained
        stopWaitingForAccessibility()
        tapLock.withLock { tapPort = tap }

        let box = TapThreadContext(tap: tap, source: source)
        let thread = Thread { [weak self] in
            guard let runLoop = CFRunLoopGetCurrent() else { return }
            self?.tapLock.withLock { self?.tapRunLoop = runLoop }
            CFRunLoopAddSource(runLoop, box.source, .commonModes)
            CGEvent.tapEnable(tap: box.tap, enable: true)
            CFRunLoopRun()  // until stop() stops this run loop
        }
        thread.name = "com.freedisplay.brightness-keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
#if DEBUG
        print("[BrightnessKeyService] Event tap installed")
#endif
    }

    /// Removes the event tap and releases the retained self reference.
    func stop() {
        stopWaitingForAccessibility()
        let (tap, runLoop) = tapLock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer { tapPort = nil; tapRunLoop = nil }
            return (tapPort, tapRunLoop)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        tapThread = nil
        selfRetained?.release()
        selfRetained = nil
    }

    /// The external displays whose brightness keys FreeDisplay handles. Set by DisplayManager.
    func updateManagedDisplays(_ displayIDs: Set<CGDirectDisplayID>) {
        tapLock.withLock { managedDisplayIDs = displayIDs }
    }

    // MARK: - Accessibility

    private func waitForAccessibility() {
        if accessibilityObserver == nil {
            // Posted when any app's Accessibility permission changes. TCC updates its database
            // a moment later, so try again after a short delay.
            accessibilityObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    for delay: UInt64 in [500_000_000, 2_000_000_000] {
                        try? await Task.sleep(nanoseconds: delay)
                        BrightnessKeyService.shared.start()
                        if BrightnessKeyService.shared.tapThread != nil { return }
                    }
                }
            }
        }
        if retryTimer == nil {
            let timer = Timer(timeInterval: 10, repeats: true) { _ in
                MainActor.assumeIsolated { BrightnessKeyService.shared.start() }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
        }
    }

    private func stopWaitingForAccessibility() {
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        accessibilityObserver = nil
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: - Event Handling (tap thread)

    /// Returns the event to pass it through, or nil to consume it.
    nonisolated func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        // Re-enable the tap if the system disabled it (e.g. after a timeout).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tapLock.withLock({ tapPort }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return passThrough
        }

        guard type.rawValue == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlButtonsSubtype else { return passThrough }

        let data1 = nsEvent.data1
        let keyCode = (data1 >> 16) & 0xFF
        let isKeyDown = (data1 & 0x0100) == 0   // bit 8 clear → key down
        guard keyCode == Self.brightnessUpKey || keyCode == Self.brightnessDownKey,
              isKeyDown else { return passThrough }

        // The display under the pointer (global CG coordinates). A fresh event carries the
        // current pointer location.
        let location = CGEvent(source: nil)?.location ?? event.location
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &displayID, &count) == .success, count > 0,
              tapLock.withLock({ managedDisplayIDs.contains(displayID) }) else { return passThrough }

        let up = keyCode == Self.brightnessUpKey
        let target = displayID
        Task { @MainActor in
            BrightnessKeyService.shared.adjustBrightness(of: target, up: up)
        }
        // Consume the event so macOS doesn't also adjust the built-in display.
        return nil
    }

    private func adjustBrightness(of displayID: CGDirectDisplayID, up: Bool) {
        guard let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == displayID }) else { return }
        // Step from where an animation is heading, so fast presses and key repeat add up.
        let base = BrightnessService.shared.targetBrightness(for: display)
        let newBrightness = max(0.0, min(100.0, base + (up ? Self.brightnessStep : -Self.brightnessStep)))
        BrightnessService.shared.setBrightnessSmooth(newBrightness, for: display)
        if let screen = NSScreen.screen(for: displayID) {
            BrightnessHUDService.shared.show(brightness: newBrightness, on: screen)
        }
    }
}

/// Hands the tap and its run-loop source to the tap thread.
private final class TapThreadContext: @unchecked Sendable {
    let tap: CFMachPort
    let source: CFRunLoopSource

    init(tap: CFMachPort, source: CFRunLoopSource) {
        self.tap = tap
        self.source = source
    }
}
