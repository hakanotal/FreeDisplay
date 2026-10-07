import CoreGraphics
import Foundation

// CGVirtualDisplay and CGVirtualDisplaySettings are ObjC objects without Sendable
// conformance, but we only use them sequentially (create on main → pass to background
// for apply → use result on main), so @unchecked Sendable is safe here.
extension CGVirtualDisplayDescriptor: @unchecked @retroactive Sendable {}
extension CGVirtualDisplay: @unchecked @retroactive Sendable {}
extension CGVirtualDisplaySettings: @unchecked @retroactive Sendable {}

/// Manages virtual display configurations and creates CGVirtualDisplay instances
/// using the private CGVirtualDisplay API declared in the bridging header.
@MainActor
final class VirtualDisplayService: ObservableObject, @unchecked Sendable {
    static let shared = VirtualDisplayService()
    private init() {
        loadConfigs()
    }

    /// Vendor ID of every virtual display FreeDisplay creates. Non-zero is required (0 makes
    /// `CGVirtualDisplay(descriptor:)` return nil); it also tells them apart from real monitors.
    nonisolated static let vendorID: UInt32 = 0xEEEE

    // MARK: - Config Model

    struct VirtualDisplayConfig: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var width: Int
        var height: Int
        var refreshRate: Double
        var hiDPI: Bool
        var autoCreate: Bool

        init(id: UUID = UUID(), name: String, width: Int, height: Int,
             refreshRate: Double = 60.0, hiDPI: Bool = true, autoCreate: Bool = true) {
            self.id = id
            self.name = name
            self.width = width
            self.height = height
            self.refreshRate = refreshRate
            self.hiDPI = hiDPI
            self.autoCreate = autoCreate
        }
    }

    // MARK: - State

    @Published var configs: [VirtualDisplayConfig] = []

    /// Active config IDs — populated when a CGVirtualDisplay is alive.
    @Published private(set) var activeConfigIDs: Set<UUID> = []

    /// Strong references to live CGVirtualDisplay objects.
    /// Releasing an entry causes the virtual display to disappear immediately.
    private var activeDisplayObjects: [UUID: CGVirtualDisplay] = [:]
    private var creatingConfigIDs: Set<UUID> = []
    /// Creations that were destroyed or deleted while still waiting for WindowServer.
    private var cancelledConfigIDs: Set<UUID> = []

    private let configsKey = "fd.VirtualDisplayConfigs"

    // MARK: - Queries

    func isActive(_ configID: UUID) -> Bool {
        activeConfigIDs.contains(configID)
    }

    /// True while the display for `configID` is being created.
    func isCreating(_ configID: UUID) -> Bool {
        creatingConfigIDs.contains(configID)
    }

    // MARK: - Create / Destroy

    /// Creates a virtual display from the given config using CGVirtualDisplay private API.
    /// Returns true on success. The CGVirtualDisplay object is retained in `activeDisplayObjects`.
    /// The ENTIRE creation (descriptor build + CGVirtualDisplay init + apply) runs off the
    /// main actor via `runWithTimeout` because any of these calls can block on WindowServer IPC.
    @discardableResult
    func create(config: VirtualDisplayConfig) async -> Bool {
        guard !isActive(config.id) else { return true }
        // Creation awaits WindowServer; don't start a second display for the same config.
        guard !creatingConfigIDs.contains(config.id) else { return false }
        creatingConfigIDs.insert(config.id)
        cancelledConfigIDs.remove(config.id)
        defer {
            creatingConfigIDs.remove(config.id)
            cancelledConfigIDs.remove(config.id)
        }

        let w = config.width
        let h = config.height
        let hiDPI = config.hiDPI

        // Step 1-2: Build descriptor + create CGVirtualDisplay ON MAIN ACTOR.
        // CGVirtualDisplay(descriptor:) requires the main thread (returns nil from background).
        let descriptor = CGVirtualDisplayDescriptor()
        let ppi: Double = 110.0
        descriptor.sizeInMillimeters = CGSize(
            width: Double(w) / ppi * 25.4,
            height: Double(h) / ppi * 25.4
        )
        descriptor.maxPixelsWide = UInt32(w)
        descriptor.maxPixelsHigh = UInt32(h)
        descriptor.name = config.name
        descriptor.vendorID = Self.vendorID
        descriptor.productID = 0x0001
        // Unique and stable per config: macOS derives the display's identity (UUID, saved
        // arrangement and mode) from vendor/product/serial, so a shared serial would make
        // every virtual display look like the same monitor.
        descriptor.serialNum = Self.serialNumber(for: config.id)
        // DO NOT set queue or color primaries — they are not needed and may interfere with creation

        guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            return false
        }

        // Step 3: Build settings with modes
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI

        var modes: [CGVirtualDisplayMode] = []
        let refreshRates: [Double] = [75.0, 60.0, 50.0]
        for rate in refreshRates {
            modes.append(CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: rate))
        }
        if hiDPI {
            let hw = w / 2, hh = h / 2
            if hw >= 1, hh >= 1 {
                for rate in refreshRates {
                    modes.append(CGVirtualDisplayMode(width: UInt(hw), height: UInt(hh), refreshRate: rate))
                }
            }
            let qw = w / 4, qh = h / 4
            if qw >= 1, qh >= 1 {
                for rate in refreshRates {
                    modes.append(CGVirtualDisplayMode(width: UInt(qw), height: UInt(qh), refreshRate: rate))
                }
            }
        }
        settings.modes = modes

        // Step 4: Apply settings on BACKGROUND thread (blocks on WindowServer IPC).
        let vd = virtualDisplay
        let s = settings
        let applyResult: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            vd.apply(s)
        }
        guard applyResult else { return false }
        guard virtualDisplay.displayID != kCGNullDirectDisplay else { return false }
        // Turned off or deleted while WindowServer was busy: dropping the object here removes
        // the display instead of leaving one running that no row controls.
        guard !cancelledConfigIDs.contains(config.id) else { return false }

        // Back on main actor — store the strong reference
        activeDisplayObjects[config.id] = virtualDisplay
        activeConfigIDs.insert(config.id)
        return true
    }

    /// Destroys all active virtual displays. Called on app termination to avoid
    /// leaving stale displays registered with WindowServer.
    func destroyAll() {
        cancelledConfigIDs.formUnion(creatingConfigIDs)
        activeDisplayObjects.removeAll()
        activeConfigIDs.removeAll()
    }

    /// Destroys the virtual display associated with `configID`.
    @discardableResult
    func destroy(configID: UUID) -> Bool {
        if creatingConfigIDs.contains(configID) {
            cancelledConfigIDs.insert(configID)
        }
        guard activeDisplayObjects[configID] != nil else {
            return false
        }

        // ARC releases the CGVirtualDisplay → virtual display disappears
        activeDisplayObjects.removeValue(forKey: configID)
        activeConfigIDs.remove(configID)

        return true
    }

    /// Non-zero serial number derived from the config's UUID.
    private static func serialNumber(for id: UUID) -> UInt32 {
        let bytes = id.uuid
        let serial = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
        return serial == 0 ? 1 : serial
    }

    // MARK: - Config Management

    @discardableResult
    func addAndCreate(_ config: VirtualDisplayConfig) async -> Bool {
        guard !configs.contains(where: { $0.id == config.id }) else {
            return await create(config: config)
        }
        // Create first; only persist on success to avoid stale config if process crashes.
        if await create(config: config) {
            configs.append(config)
            saveConfigs()
            return true
        }
        return false
    }

    func removeConfig(id: UUID) {
        destroy(configID: id)
        configs.removeAll { $0.id == id }
        saveConfigs()
    }

    // MARK: - Persistence

    private func loadConfigs() {
        guard let data = UserDefaults.standard.data(forKey: configsKey),
              let decoded = try? JSONDecoder().decode([VirtualDisplayConfig].self, from: data)
        else { return }
        configs = decoded

        // Re-create virtual displays marked autoCreate after WindowServer stabilises.
        // Virtual displays are owned by the process, so none survive from a previous run.
        let autoCreateConfigs = configs.filter { $0.autoCreate }
        if !autoCreateConfigs.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                for config in autoCreateConfigs {
                    _ = await create(config: config)
                }
            }
        }
    }

    private func saveConfigs() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: configsKey)
    }
}
