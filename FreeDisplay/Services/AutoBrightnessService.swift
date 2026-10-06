import Foundation
import CoreGraphics

/// Reads the built-in display's brightness (which macOS auto-adjusts based on ambient light)
/// and syncs it to external displays. This avoids needing Intel-only LMU hardware access.
@MainActor
final class AutoBrightnessService: ObservableObject, @unchecked Sendable {
    static let shared = AutoBrightnessService()
    private init() {
        loadPrefs()
    }

    // MARK: - State

    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                startPolling()
            } else {
                stopPolling()
            }
            savePrefs()
        }
    }

    /// Multiplier 0.5–1.5. Applied to builtin brightness when syncing to external displays.
    @Published var sensitivity: Double = 1.0 {
        didSet { savePrefs() }
    }

    /// Last builtin brightness reading (0.0–1.0). 0 = unavailable / no builtin display.
    @Published private(set) var builtinBrightness: Double = 0
    private var lastAppliedBrightness: Double = -1

    /// Set to true after the first poll attempt completes (success or failure).
    /// Used by the UI to distinguish "not polled yet" from "no builtin display found".
    @Published private(set) var hasPolled: Bool = false

    // MARK: - Private

    private var pollingTask: Task<Void, Never>?
    private let pollingInterval: TimeInterval = 2.0  // seconds

    // MARK: - Builtin Brightness

    /// Reads the current brightness of the builtin display.
    /// Returns a value in 0.0–1.0, or nil if no builtin display is found.
    /// Safe to call from a background thread.
    nonisolated func readBuiltinBrightness() -> Double? {
        BrightnessService.shared.readBuiltinBrightness()
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollingTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let brightness = self.readBuiltinBrightness()
                await self.applyBrightness(builtin: brightness)
                try? await Task.sleep(nanoseconds: UInt64(self.pollingInterval * 1_000_000_000))
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    @MainActor
    private func applyBrightness(builtin: Double?) async {
        builtinBrightness = builtin ?? 0
        hasPolled = true

        guard let builtin, builtin > 0 else { return }

        // Only apply if builtin brightness changed more than 2% since last application.
        guard abs(builtin - lastAppliedBrightness) >= 0.02 else { return }

        // Respect 30-second cooldown after a manual brightness adjustment.
        if let last = BrightnessService.shared.lastManualAdjustDate,
           Date().timeIntervalSince(last) < 30.0 {
            return
        }

        let targetPercentage = min(100.0, max(0.0, builtin * sensitivity * 100.0))

        let snapshot = DisplayManagerAccessor.shared.displays
        for display in snapshot {
            // Only sync to external (non-builtin, non-virtual) displays.
            guard !display.isBuiltin, !VirtualDisplayService.shared.isVirtualDisplay(display.displayID) else { continue }
            let current = display.brightness
            if abs(current - targetPercentage) >= 2.0 {
                await BrightnessService.shared.setBrightness(targetPercentage, for: display, isAutoAdjust: true)
            }
        }
        lastAppliedBrightness = builtin
    }

    // MARK: - Persistence

    private let enabledKey = "fd.AutoBrightnessEnabled"
    private let sensitivityKey = "fd.AutoBrightnessSensitivity"

    private func loadPrefs() {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        if UserDefaults.standard.object(forKey: sensitivityKey) != nil {
            sensitivity = UserDefaults.standard.double(forKey: sensitivityKey)
        }
    }

    private func savePrefs() {
        UserDefaults.standard.set(isEnabled, forKey: enabledKey)
        UserDefaults.standard.set(sensitivity, forKey: sensitivityKey)
    }
}

// MARK: - Display Manager Accessor

/// Thin wrapper so AutoBrightnessService can reach displays without a direct EnvironmentObject.
@MainActor
final class DisplayManagerAccessor {
    static let shared = DisplayManagerAccessor()
    var displays: [DisplayInfo] = []
    private init() {}
}
