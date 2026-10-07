import Foundation
import CoreGraphics

/// Turns HiDPI (scaled Retina) modes on and off for external displays by editing the
/// `scale-resolutions` key of the display's override plist in
/// `/Library/Displays/Contents/Resources/Overrides/`. Other keys in that file (EDID patches,
/// names from other tools) are kept.
@MainActor
final class HiDPIService: ObservableObject, @unchecked Sendable {
    static let shared = HiDPIService()
    private init() {}

    /// The last failed enable/disable per monitor (vendor:product), shown next to its toggle.
    /// Kept here because the admin prompt usually closes the menu panel.
    @Published private(set) var lastErrors: [String: String] = [:]

    private var refreshTask: Task<Void, Never>?

    private let overridesBase = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides")
    /// Apple's overrides. A file in /Library replaces the one here for the same monitor, so a
    /// new file starts as a copy of it.
    private let systemOverridesBase = URL(fileURLWithPath: "/System/Library/Displays/Contents/Resources/Overrides")
    private static let scaleResolutionsKey = "scale-resolutions"

    // MARK: - Public API

    /// Whether the display's override plist lists HiDPI scale resolutions.
    func isHiDPIEnabled(vendor: UInt32, product: UInt32) -> Bool {
        readPlist(at: overridePlistURL(vendor: vendor, product: product))?[Self.scaleResolutionsKey] != nil
    }

    /// Enables HiDPI for an external display via plist override and clears any opt-out.
    /// macOS picks up the new modes when the display is reconnected.
    /// Returns nil on success, or an error string on failure.
    func enableHiDPI(vendor: UInt32, product: UInt32, nativeWidth: Int, nativeHeight: Int) -> String? {
        let url = overridePlistURL(vendor: vendor, product: product)
        var plist = readPlist(at: url) ?? readPlist(at: systemOverridePlistURL(vendor: vendor, product: product)) ?? [:]
        plist[Self.scaleResolutionsKey] = generateScaledModes(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        let err = writePlist(plist, to: url, vendor: vendor)
        if err == nil { setOptedOut(false, vendor: vendor, product: product) }
        record(err, vendor: vendor, product: product)
        return err
    }

    /// Disables HiDPI for an external display by removing the scale resolutions from its
    /// override (the file goes only if nothing else is left), and remembers the choice so
    /// auto-enable doesn't turn it back on.
    func disableHiDPI(vendor: UInt32, product: UInt32) -> String? {
        let url = overridePlistURL(vendor: vendor, product: product)
        var err: String?
        if var plist = readPlist(at: url), plist[Self.scaleResolutionsKey] != nil {
            plist.removeValue(forKey: Self.scaleResolutionsKey)
            let systemPlist = readPlist(at: systemOverridePlistURL(vendor: vendor, product: product)) ?? [:]
            // Nothing of our own left (empty, or just the copy of Apple's file): remove it.
            if plist.isEmpty || NSDictionary(dictionary: plist).isEqual(to: systemPlist) {
                err = ensureWritableOverrideDir(vendor: vendor) ?? removeFile(at: url)
            } else {
                err = writePlist(plist, to: url, vendor: vendor)
            }
        }
        if err == nil { setOptedOut(true, vendor: vendor, product: product) }
        record(err, vendor: vendor, product: product)
        return err
    }

    func lastError(vendor: UInt32, product: UInt32) -> String? {
        lastErrors[monitorKey(vendor: vendor, product: product)]
    }

    /// Whether DisplayManager may enable HiDPI on its own: never after the user turned it
    /// off for this monitor, and never when it would need an admin password prompt.
    func allowsAutoEnable(vendor: UInt32, product: UInt32) -> Bool {
        !optedOutKeys.contains(monitorKey(vendor: vendor, product: product)) && !requiresAdmin(vendor: vendor)
    }

    /// Refreshes availableModes on the given DisplayInfo after enabling HiDPI.
    func refreshModes(for display: DisplayInfo) {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await display.loadDetails()
            display.refreshCurrentMode()
        }
    }

    /// True until the one-time permission step has made this vendor's override folder
    /// writable by the current user (after that, enable/disable needs no password).
    func requiresAdmin(vendor: UInt32) -> Bool {
        !FileManager.default.isWritableFile(atPath: overrideDir(vendor: vendor).path)
    }

    // MARK: - Opt-out

    private static let optOutDefaultsKey = "fd.hidpi.optOut"

    private var optedOutKeys: [String] {
        UserDefaults.standard.stringArray(forKey: Self.optOutDefaultsKey) ?? []
    }

    private func monitorKey(vendor: UInt32, product: UInt32) -> String {
        String(format: "%x:%x", vendor, product)
    }

    private func setOptedOut(_ optedOut: Bool, vendor: UInt32, product: UInt32) {
        let key = monitorKey(vendor: vendor, product: product)
        var keys = optedOutKeys.filter { $0 != key }
        if optedOut { keys.append(key) }
        UserDefaults.standard.set(keys, forKey: Self.optOutDefaultsKey)
    }

    private func record(_ error: String?, vendor: UInt32, product: UInt32) {
        let key = monitorKey(vendor: vendor, product: product)
        if lastErrors[key] != error { lastErrors[key] = error }
    }

    // MARK: - Plist Override

    private func readPlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private func writePlist(_ plist: [String: Any], to url: URL, vendor: UInt32) -> String? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return L("Plist verisi oluşturulamadı", "Failed to generate plist data")
        }
        if let err = ensureWritableOverrideDir(vendor: vendor) {
            return err
        }
        do {
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return L("Ayar dosyası yazılamadı: \(error.localizedDescription)", "Failed to write override file: \(error.localizedDescription)")
        }
    }

    private func removeFile(at url: URL) -> String? {
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            return L("Ayar dosyası silinemedi: \(error.localizedDescription)", "Failed to remove override file: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// One-time permission step: /Library/Displays is root-owned, so the first enable/disable
    /// asks for an admin password to create this vendor's override folder and hand it to the
    /// current user. Later writes go straight to the folder without a prompt.
    /// Trade-off: other processes running as this user can also edit this vendor's overrides.
    private func ensureWritableOverrideDir(vendor: UInt32) -> String? {
        guard requiresAdmin(vendor: vendor) else { return nil }
        let dirPath = overrideDir(vendor: vendor).path
        return executePrivilegedCommand("mkdir -p '\(dirPath)' && chown -R \(getuid()) '\(dirPath)'")
    }

    /// Executes a shell command with administrator privileges via AppleScript (on the main
    /// thread, so the password prompt names FreeDisplay). Returns nil on success, or an error
    /// message on failure.
    private func executePrivilegedCommand(_ command: String) -> String? {
        let script = """
            do shell script "\(command)" with administrator privileges
            """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return L("AppleScript oluşturulamadı", "Failed to create AppleScript")
        }
        appleScript.executeAndReturnError(&error)
        if let error = error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? L("Bilinmeyen hata", "Unknown error")
            if msg.contains("canceled") || msg.contains("Cancel") {
                return L("Yetkilendirme kullanıcı tarafından iptal edildi", "Authorization was canceled by the user")
            }
            return L("Yönetici yetkilendirmesi başarısız: \(msg)", "Administrator authorization failed: \(msg)")
        }
        return nil
    }

    private func overrideDir(vendor: UInt32) -> URL {
        overridesBase.appendingPathComponent(String(format: "DisplayVendorID-%x", vendor))
    }

    private func overridePlistURL(vendor: UInt32, product: UInt32) -> URL {
        overrideDir(vendor: vendor).appendingPathComponent(String(format: "DisplayProductID-%x", product))
    }

    private func systemOverridePlistURL(vendor: UInt32, product: UInt32) -> URL {
        systemOverridesBase
            .appendingPathComponent(String(format: "DisplayVendorID-%x", vendor))
            .appendingPathComponent(String(format: "DisplayProductID-%x", product))
    }

    private func generateScaledModes(nativeWidth: Int, nativeHeight: Int) -> [Data] {
        // Generate HiDPI modes: each entry is 8 bytes big-endian (backingW, backingH)
        // For a 2560×1440 display, we want:
        //   1920×1080 HiDPI (backing 3840×2160)
        //   1600×900  HiDPI (backing 3200×1800)
        //   1280×720  HiDPI (backing 2560×1440)
        //   native as HiDPI (backing 5120×2880)
        var resolutions: [(Int, Int)] = []

        // Native resolution as HiDPI (2x backing)
        resolutions.append((nativeWidth * 2, nativeHeight * 2))

        // Scaled HiDPI modes
        let scales: [Double] = [0.75, 0.625, 0.5]
        for scale in scales {
            let logicalW = Int((Double(nativeWidth) * scale).rounded()) & ~1
            let logicalH = Int((Double(nativeHeight) * scale).rounded()) & ~1
            guard logicalW >= 800, logicalH >= 600 else { continue }
            resolutions.append((logicalW * 2, logicalH * 2))
        }

        return resolutions.map { (backingW, backingH) in
            var bigEndian = (UInt32(backingW).bigEndian, UInt32(backingH).bigEndian)
            return withUnsafeBytes(of: &bigEndian) { Data($0) }
        }
    }
}
