import Foundation
import CoreGraphics
@preconcurrency import ColorSync

/// ICC color profile model (RGB display-class profiles only; see `scanProfiles`).
struct ICCProfile: Identifiable, Equatable, Sendable {
    let name: String
    let path: URL
    var id: URL { path }
}

/// Service for ICC color profile enumeration and switching.
/// Uses ColorSync framework + file system scanning.
final class ColorProfileService: @unchecked Sendable {
    static let shared = ColorProfileService()
    private init() {}

    private static let searchDirectories: [URL] = [
        URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
        URL(fileURLWithPath: "/System/Library/ColorSync/Profiles"),
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/ColorSync/Profiles"),
    ]

    /// The last scan and the folder modification dates it was made from (guarded by `lock`).
    private let lock = NSLock()
    private var cache: (signature: [String: Date], profiles: [ICCProfile])?

    // MARK: - Profile Enumeration

    /// The list from the last scan, or nil before the first one.
    var cachedProfiles: [ICCProfile]? {
        lock.withLock { cache?.profiles }
    }

    /// Returns all installed display profiles sorted alphabetically. Rescans only when a
    /// profile folder changed since the last scan.
    func enumerateProfiles() async -> [ICCProfile] {
        await Task.detached(priority: .userInitiated) { [self] in
            let signature = Self.folderSignature()
            if let cached = lock.withLock({ cache }), cached.signature == signature {
                return cached.profiles
            }
            let profiles = Self.scanProfiles()
            lock.withLock { cache = (signature, profiles) }
            return profiles
        }.value
    }

    /// Modification dates of the profile folders and their subfolders (adding or removing a
    /// profile changes its folder's date).
    private static func folderSignature() -> [String: Date] {
        let fm = FileManager.default
        var signature: [String: Date] = [:]
        for dir in searchDirectories {
            var folders = [dir]
            if let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) {
                folders += children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
            for folder in folders {
                if let date = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    signature[folder.path] = date
                }
            }
        }
        return signature
    }

    private static func scanProfiles() -> [ICCProfile] {
        var profiles: [ICCProfile] = []
        var seenPaths = Set<URL>()
        for dir in searchDirectories {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                let ext = url.pathExtension.lowercased()
                guard ext == "icc" || ext == "icm", seenPaths.insert(url).inserted,
                      let profile = makeProfile(from: url) else { continue }
                profiles.append(profile)
            }
        }
        return profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func makeProfile(from url: URL) -> ICCProfile? {
        // Only RGB display-class profiles can be assigned to a display. Applying a CMYK, gray,
        // Lab/XYZ, abstract or named-color profile makes WindowServer's color space registry
        // abort the app (assertion in SkyLight), so those are not offered. The header is read
        // straight from the file, so the many other profiles are never parsed.
        guard isRGBDisplayProfile(at: url),
              let rawProfile = ColorSyncProfileCreateWithURL(url as CFURL, nil) else { return nil }
        let profile = rawProfile.takeRetainedValue()

        let name: String
        if let rawDesc = ColorSyncProfileCopyDescriptionString(profile) {
            name = rawDesc.takeRetainedValue() as String
        } else {
            name = url.deletingPathExtension().lastPathComponent
        }
        return ICCProfile(name: name, path: url)
    }

    /// ICC header: bytes 12–15 are the device class ("mntr" = display), 16–19 the data color
    /// space ("RGB "). Read raw (big-endian): ColorSyncProfileCopyHeader returns fields
    /// byte-swapped to host order ("BGR " for RGB).
    private static func isRGBDisplayProfile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20 else { return false }
        let bytes = [UInt8](header)
        return bytes[12..<16].elementsEqual("mntr".utf8) && bytes[16..<20].elementsEqual("RGB ".utf8)
    }

    // MARK: - Current Color Info

    /// Returns the human-readable color space name for the given display.
    func currentColorSpaceName(for displayID: CGDirectDisplayID) -> String {
        let colorSpace = CGDisplayCopyColorSpace(displayID)
        // Prefer the active ICC profile's description: display-specific profiles
        // (e.g. EDID-generated "GF270M") have no CGColorSpace name, and this matches
        // the names shown in the profile list.
        if let data = colorSpace.copyICCData(),
           let profile = ColorSyncProfileCreate(data, nil)?.takeRetainedValue(),
           let desc = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() {
            return desc as String
        }
        guard let cfName = colorSpace.name else { return L("Bilinmiyor", "Unknown") }
        return humanReadable(cfName as String)
    }

    // Bridge CGColorSpace CFString constants to Swift String for comparison
    private func humanReadable(_ name: String) -> String {
        if name == (CGColorSpace.displayP3 as String)           { return "Display P3" }
        if name == (CGColorSpace.sRGB as String)                { return "sRGB IEC61966-2.1" }
        if name == (CGColorSpace.adobeRGB1998 as String)        { return "Adobe RGB (1998)" }
        if name == (CGColorSpace.genericRGBLinear as String)    { return "Generic RGB Linear" }
        if name == (CGColorSpace.extendedSRGB as String)        { return "Extended sRGB" }
        if name == (CGColorSpace.linearSRGB as String)          { return "Linear sRGB" }
        if name == (CGColorSpace.extendedLinearSRGB as String)  { return "Extended Linear sRGB" }
        if name == (CGColorSpace.genericGrayGamma2_2 as String) { return "Generic Gray Gamma 2.2" }
        if name.hasPrefix("kCGColorSpace") {
            return String(name.dropFirst("kCGColorSpace".count))
        }
        return name
    }

    // MARK: - Current Profile URL

    /// Returns the file URL of the currently active ICC profile for the given display, if available.
    func currentProfileURL(for displayID: CGDirectDisplayID) -> URL? {
        guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = rawUUID.takeRetainedValue()

        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let profileIDKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue()
        else { return nil }

        guard let rawInfo = ColorSyncDeviceCopyDeviceInfo(deviceClass, uuid) else { return nil }
        let info = rawInfo.takeRetainedValue() as NSDictionary

        // Determine the active mode name from FactoryProfiles[DeviceDefaultProfileID].
        // Both CustomProfiles and FactoryProfiles use this mode name as their key.
        let factoryProfiles = info["FactoryProfiles"] as? NSDictionary
        let activeModeName = factoryProfiles?[profileIDKey] as? String

        // CustomProfiles: keys are mode names, values are NSURL directly.
        if let modeName = activeModeName,
           let customProfiles = info["CustomProfiles"] as? NSDictionary,
           let url = customProfiles[modeName] as? NSURL {
            return url as URL
        }

        // Fall back to FactoryProfiles: the mode entry is a dict with a DeviceProfileURL string.
        if let modeName = activeModeName,
           let modeDict = factoryProfiles?[modeName] as? NSDictionary,
           let urlString = modeDict["DeviceProfileURL"] as? String {
            return URL(string: urlString)
        }

        return nil
    }

    // MARK: - Profile Switching

    /// Sets the ICC profile for the given display using ColorSync.
    /// Returns true on success.
    @discardableResult
    func setProfile(_ profile: ICCProfile, for displayID: CGDirectDisplayID) -> Bool {
        guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return false }
        let uuid = rawUUID.takeRetainedValue()

        // kColorSyncDisplayDeviceClass and kColorSyncDeviceDefaultProfileID are
        // Unmanaged<CFString>? in the current SDK; use takeUnretainedValue() to borrow them.
        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let profileIDKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue()
        else { return false }

        let profileInfo: NSDictionary = [profileIDKey: profile.path as NSURL]

        return ColorSyncDeviceSetCustomProfiles(
            deviceClass,
            uuid,
            profileInfo as CFDictionary
        )
    }
}
