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

    /// Last builtin brightness reading (0.0–1.0).
    @Published private(set) var builtinBrightness: Double = 0
    /// False while no built-in panel can be read (desktop Mac, lid closed). Starts true so the
    /// toggle is usable before the first poll.
    @Published private(set) var builtinAvailable = true
    private var lastAppliedBrightness: Double = -1

    // MARK: - Private

    private var pollingTask: Task<Void, Never>?
    /// Poll every 2 s while the built-in panel is readable, every 10 s while it isn't.
    private static let pollingInterval: TimeInterval = 2.0
    private static let unavailablePollingInterval: TimeInterval = 10.0

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollingTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let brightness = BrightnessService.readBuiltinBrightness()
                guard let self else { return }
                let interval = await self.applyBrightness(builtin: brightness)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Syncs external displays to the built-in reading and returns the next polling interval.
    private func applyBrightness(builtin: Double?) -> TimeInterval {
        let available = builtin != nil
        if builtinAvailable != available { builtinAvailable = available }
        guard let builtin else { return Self.unavailablePollingInterval }
        if builtinBrightness != builtin { builtinBrightness = builtin }

        // Only apply if builtin brightness changed more than 2% since last application.
        guard abs(builtin - lastAppliedBrightness) >= 0.02 else { return Self.pollingInterval }

        // Respect 30-second cooldown after a manual brightness adjustment.
        if let last = BrightnessService.shared.lastManualAdjustDate,
           Date().timeIntervalSince(last) < 30.0 {
            return Self.pollingInterval
        }

        let targetPercentage = min(100.0, max(0.0, builtin * sensitivity * 100.0))
        for display in DisplayManagerAccessor.shared.displays where !display.isBuiltin && !display.isVirtual {
            if abs(display.brightness - targetPercentage) >= 2.0 {
                BrightnessService.shared.setBrightnessSmooth(targetPercentage, for: display, isAutoAdjust: true)
            }
        }
        lastAppliedBrightness = builtin
        return Self.pollingInterval
    }

    // MARK: - Persistence

    private let enabledKey = "fd.AutoBrightnessEnabled"
    private let sensitivityKey = "fd.AutoBrightnessSensitivity"

    private var isLoadingPrefs = false

    /// Both values are read before either is assigned, and the observers' saves are skipped
    /// while loading: each one would write the other, not-yet-loaded value. Setting
    /// `isEnabled` starts polling when on.
    private func loadPrefs() {
        let defaults = UserDefaults.standard
        let savedSensitivity = defaults.object(forKey: sensitivityKey) as? Double
        let savedEnabled = defaults.bool(forKey: enabledKey)
        isLoadingPrefs = true
        defer { isLoadingPrefs = false }
        if let savedSensitivity { sensitivity = savedSensitivity }
        isEnabled = savedEnabled
    }

    private func savePrefs() {
        guard !isLoadingPrefs else { return }
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
