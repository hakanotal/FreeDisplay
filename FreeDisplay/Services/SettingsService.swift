import Foundation
import CoreGraphics
import Combine
import Observation

/// Centralized settings persistence service.
/// Simple settings use UserDefaults via @AppStorage-compatible keys.
/// Complex configurations are stored as JSON in ~/Library/Application Support/FreeDisplay/.
@MainActor
final class SettingsService: ObservableObject, @unchecked Sendable {
    static let shared = SettingsService()

    private let defaults = UserDefaults.standard
    private let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("FreeDisplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        loadAll()
    }

    // MARK: - Keys

    private enum Keys {
        static let launchAtLogin          = "fd.launchAtLogin"
        static let launchAtLoginPrompted  = "fd.launchAtLogin.prompted"
        static let showCombinedBrightness = "fd.showCombinedBrightness"
        static let checkUpdatesOnLaunch   = "fd.checkUpdatesOnLaunch"
        static let autoArrangeExternalAbove = "fd.arrangement.autoExternalAbove"
        static let migrationVersion       = "fd.migrationVersion"
        // Per-display keys use prefix + display UUID (see DisplayInfo.uuidString(for:))
        static let brightnessPrefix       = "fd.brightness."
    }

    // MARK: - Published Settings

    @Published var launchAtLogin: Bool = false {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    /// Whether the first-launch "enable Launch at Login?" prompt has been shown.
    @Published var launchAtLoginPrompted: Bool = false {
        didSet { defaults.set(launchAtLoginPrompted, forKey: Keys.launchAtLoginPrompted) }
    }

    @Published var showCombinedBrightness: Bool = true {
        didSet { defaults.set(showCombinedBrightness, forKey: Keys.showCombinedBrightness) }
    }

    @Published var checkUpdatesOnLaunch: Bool = true {
        didSet { defaults.set(checkUpdatesOnLaunch, forKey: Keys.checkUpdatesOnLaunch) }
    }

    /// Keep external displays in a row above the built-in display (opt-in). Re-applied on
    /// launch, hot-plug and mode changes; any manual arrangement turns it off.
    @Published var autoArrangeExternalAbove: Bool = false {
        didSet { defaults.set(autoArrangeExternalAbove, forKey: Keys.autoArrangeExternalAbove) }
    }

    // MARK: - Per-Display Settings

    /// Last brightness (0–100) FreeDisplay set for the display, used as the starting value
    /// until the hardware has been read.
    func brightness(forDisplayUUID uuid: String) -> Double? {
        let key = Keys.brightnessPrefix + uuid
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    func setBrightness(_ value: Double, forDisplayUUID uuid: String) {
        defaults.set(value, forKey: Keys.brightnessPrefix + uuid)
    }

    // MARK: - JSON Persistence Helpers

    func save<T: Encodable>(_ value: T, filename: String) {
        let url = supportDir.appendingPathComponent(filename)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("[SettingsService] Failed to save \(filename): \(error)")
            #endif
        }
    }

    func load<T: Decodable>(_ type: T.Type, filename: String) -> T? {
        let url = supportDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Load All

    private func loadAll() {
        // Sync launch-at-login from the authoritative launchd agent state, not just UserDefaults.
        // This handles the case where the user toggled it externally or after a fresh install.
        launchAtLogin = LaunchService.shared.isEnabled
        launchAtLoginPrompted = defaults.bool(forKey: Keys.launchAtLoginPrompted)
        showCombinedBrightness = defaults.object(forKey: Keys.showCombinedBrightness) != nil
            ? defaults.bool(forKey: Keys.showCombinedBrightness) : true
        checkUpdatesOnLaunch = defaults.object(forKey: Keys.checkUpdatesOnLaunch) != nil
            ? defaults.bool(forKey: Keys.checkUpdatesOnLaunch) : true
        autoArrangeExternalAbove = defaults.bool(forKey: Keys.autoArrangeExternalAbove)
    }

    // MARK: - Migration

    /// One-time cleanup of keys from older versions. Call before any service reads defaults.
    /// - Per-display state keyed by CGDirectDisplayID moves to display-UUID keys (IDs can be
    ///   reassigned to another monitor) for the displays that are online now.
    /// - Removes keys of settings that no longer exist, including the old always-on
    ///   "external above built-in" auto-arrange flag (the new opt-in toggle starts off).
    static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Keys.migrationVersion) < 1 else { return }

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let uuidByID = Dictionary(uniqueKeysWithValues: ids.prefix(Int(count)).map {
            ("\($0)", DisplayInfo.uuidString(for: $0))
        })

        // Old prefix → new prefix for per-display state worth keeping.
        let moves = [
            ("fd.GammaService.savedAdjustment.", "fd.GammaService.savedAdjustment."),
            ("fd.softBrightness_", "fd.softBrightness."),
        ]
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("fd.") {
            if let move = moves.first(where: { key.hasPrefix($0.0) }) {
                let (oldPrefix, newPrefix) = move
                let suffix = String(key.dropFirst(oldPrefix.count))
                // UUID-keyed entries are already migrated; only numeric display IDs move.
                guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { continue }
                if let uuid = uuidByID[suffix], defaults.object(forKey: newPrefix + uuid) == nil {
                    defaults.set(defaults.object(forKey: key), forKey: newPrefix + uuid)
                }
                defaults.removeObject(forKey: key)
            } else if key.hasPrefix("fd.brightness_") || key.hasPrefix("fd.contrast_") {
                defaults.removeObject(forKey: key)
            }
        }
        for key in ["fd.arrangement.externalAbove", "fd.ResolutionService.savedModes",
                    "fd.colorPickerHistory", "fd.menuWidth", "fd.ddcCacheTTL"] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(1, forKey: Keys.migrationVersion)
    }
}

// MARK: - App Language

/// UI languages the app can switch between at runtime (Settings → Dil / Language).
enum AppLanguage: String, CaseIterable, Sendable {
    case tr, en
}

/// Holds the in-app UI language, persisted under `fd.language` (default: Turkish).
/// Hand-written `Observable` conformance (no macro needed): any view body that calls
/// `L(_:_:)` reads `language` and therefore re-renders immediately when it changes.
final class LanguageStore: Observable, @unchecked Sendable {
    static let shared = LanguageStore()

    private static let key = "fd.language"
    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var storedLanguage: AppLanguage

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? ""
        storedLanguage = AppLanguage(rawValue: saved) ?? .tr
    }

    var language: AppLanguage {
        get {
            registrar.access(self, keyPath: \.language)
            return lock.withLock { storedLanguage }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.language) {
                lock.withLock { storedLanguage = newValue }
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.key)
        }
    }
}

/// Returns the UI string for the current in-app language: `L("Ayarlar", "Settings")`.
func L(_ tr: String, _ en: String) -> String {
    LanguageStore.shared.language == .en ? en : tr
}
