import Foundation
import CoreGraphics
import IOKit
import IOKit.i2c
import IOKit.graphics

/// An external display DDC may talk to, as CoreGraphics and AppKit see it. Built on the main
/// thread by DisplayManager (NSScreen is main-only) and handed to DDCService for matching.
struct DDCCandidate: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    /// NSScreen.localizedName, if AppKit knows the display yet.
    let name: String?
}

/// What happened to a DDC write.
enum DDCWriteOutcome: Sendable {
    case success
    case failure
    /// A newer value for the same display and VCP code replaced it before it was sent (or
    /// while it was being retried). The newer write reports its own outcome.
    case superseded
}

/// DDC/CI I2C communication service for external displays.
/// Supports two hardware paths:
///   - ARM64 (Apple Silicon): IOAVService via DCPAVServiceProxy
///   - x86_64 (Intel):        IOFramebuffer I2C via IOFBCopyI2CInterfaceForBus
/// All I2C operations run on a private serial queue to avoid blocking UI.
///
/// Writes are coalesced per (display, VCP code): only the latest value is sent, so slider
/// drags, animations and key repeat never build up a backlog of stale commands.
final class DDCService: @unchecked Sendable {
    static let shared = DDCService()

    // VCP feature codes (DDC/CI standard)
    static let brightnessVCP: UInt8 = 0x10

    private let ddcQueue = DispatchQueue(label: "com.freedisplay.ddc", qos: .userInitiated)

    /// Attempts per read or write before giving up.
    private static let maxAttempts = 3
    /// Minimum spacing between two commands to the same display. DDC/CI monitors silently
    /// drop commands that arrive faster than this.
    private static let commandGapNanos: UInt64 = 50_000_000
    /// How long a VCP read stays cached.
    private static let cacheTTLNanos: UInt64 = 5_000_000_000

    /// Guards `vcpCache`, `candidates` and the write-coalescing state below.
    private let lock = NSLock()

    // MARK: - State (guarded by `lock`)

    private struct VCPCacheEntry {
        let current: UInt16
        let max: UInt16
        let timestamp: UInt64
    }

    private struct WriteKey: Hashable {
        let displayID: CGDirectDisplayID
        let vcp: UInt8
    }

    private struct PendingWrite {
        var value: UInt16
        var generation: UInt64
        var completion: (@Sendable (DDCWriteOutcome) -> Void)?
    }

    private var vcpCache: [CGDirectDisplayID: [UInt8: VCPCacheEntry]] = [:]
    private var candidates: [DDCCandidate] = []
    /// The latest value waiting to be written, per display and VCP code.
    private var pendingWrites: [WriteKey: PendingWrite] = [:]
    /// Keys with a drain scheduled or running on `ddcQueue`.
    private var drainingKeys: Set<WriteKey> = []
    /// Bumped on every write request; a read only caches its result if no write for the
    /// same key started in the meantime.
    private var writeGenerations: [WriteKey: UInt64] = [:]

    // MARK: - State (ddcQueue only)

    private var lastCommandAt: [CGDirectDisplayID: UInt64] = [:]

#if arch(arm64)
    /// IOAVService per display, built for all candidates at once (see `rebuildAVMap`).
    private var avMap: [CGDirectDisplayID: IOAVServiceRef] = [:]
    /// Uptime when `avMap` was built; 0 = not built. A display missing from a map younger than
    /// `avMapNegativeTTLNanos` has no service: lookups for it don't re-enumerate IOKit.
    private var avMapBuiltAt: UInt64 = 0
    private static let avMapNegativeTTLNanos: UInt64 = 10_000_000_000
#endif

    private init() {}

    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    // MARK: - Candidates

    /// Sets the external displays DDC may address. Called by DisplayManager after every
    /// display refresh; a change drops the service map so it is rebuilt for the new set.
    func updateCandidates(_ newCandidates: [DDCCandidate]) {
        let changed = lock.withLock { () -> Bool in
            guard candidates != newCandidates else { return false }
            candidates = newCandidates
            return true
        }
#if arch(arm64)
        if changed {
            ddcQueue.async { self.invalidateAVMap() }
        }
#endif
    }

    // MARK: - Cache Cleanup

    /// Forgets everything about a display: cached reads, queued writes (reported as
    /// superseded) and its IOAVService (all services are re-matched on next use). Called when
    /// a display is removed and after wake, when services may have been recreated.
    func clearCache(for displayID: CGDirectDisplayID) {
        let dropped = lock.withLock { () -> [(@Sendable (DDCWriteOutcome) -> Void)] in
            vcpCache.removeValue(forKey: displayID)
            var completions: [(@Sendable (DDCWriteOutcome) -> Void)] = []
            for key in pendingWrites.keys where key.displayID == displayID {
                if let completion = pendingWrites.removeValue(forKey: key)?.completion {
                    completions.append(completion)
                }
            }
            return completions
        }
        dropped.forEach { $0(.superseded) }
        ddcQueue.async {
            self.lastCommandAt.removeValue(forKey: displayID)
#if arch(arm64)
            self.invalidateAVMap()
#endif
        }
    }

    // MARK: - Public Async API

    /// Writes a VCP value. If a write for the same display and code is still waiting, its
    /// value is replaced (its completion gets `.superseded`); only the latest value is sent.
    /// Retries up to 3 times. `completion` runs exactly once, on the DDC queue or the
    /// calling thread. It is `@Sendable` so callers on the main actor don't get an implicitly
    /// main-isolated closure (Swift 6 traps when that runs off-main).
    func writeAsync(
        displayID: CGDirectDisplayID,
        command: UInt8,
        value: UInt16,
        completion: (@Sendable (DDCWriteOutcome) -> Void)? = nil
    ) {
        let key = WriteKey(displayID: displayID, vcp: command)
        let (superseded, schedule) = lock.withLock { () -> ((@Sendable (DDCWriteOutcome) -> Void)?, Bool) in
            let generation = (writeGenerations[key] ?? 0) &+ 1
            writeGenerations[key] = generation
            let previous = pendingWrites[key]?.completion
            pendingWrites[key] = PendingWrite(value: value, generation: generation, completion: completion)
            // The cached value is about to be wrong.
            vcpCache[displayID]?[command] = nil
            return (previous, drainingKeys.insert(key).inserted)
        }
        superseded?(.superseded)
        if schedule {
            ddcQueue.async { self.drainWrite(key) }
        }
    }

    /// Reads a VCP value. Returns a cached result if it is younger than 5 s. A read that
    /// overlaps a write to the same code returns nil instead of a value that may predate it.
    /// `completion` runs on the DDC queue (or synchronously on a cache hit); see `writeAsync`.
    func readAsync(
        displayID: CGDirectDisplayID,
        command: UInt8,
        completion: @escaping @Sendable ((current: UInt16, max: UInt16)?) -> Void
    ) {
        let key = WriteKey(displayID: displayID, vcp: command)
        let (cached, generation) = lock.withLock { () -> ((current: UInt16, max: UInt16)?, UInt64) in
            let generation = writeGenerations[key] ?? 0
            guard pendingWrites[key] == nil,
                  let entry = vcpCache[displayID]?[command],
                  Self.now - entry.timestamp < Self.cacheTTLNanos else { return (nil, generation) }
            return ((entry.current, entry.max), generation)
        }
        if let cached {
            completion(cached)
            return
        }

        ddcQueue.async {
            var reply: (current: UInt16, max: UInt16)?
            for _ in 0..<Self.maxAttempts {
                if self.isWritePending(key) { break }
                self.waitForCommandGap(displayID)
                let result = self.readSynchronous(displayID: displayID, command: command)
                self.lastCommandAt[displayID] = Self.now
                if case .value(let value) = result {
                    reply = value
                    break
                }
                if case .noService = result { break }
            }
            let accepted = self.lock.withLock { () -> (current: UInt16, max: UInt16)? in
                guard let reply, (self.writeGenerations[key] ?? 0) == generation,
                      self.pendingWrites[key] == nil else { return nil }
                self.vcpCache[displayID, default: [:]][command] = VCPCacheEntry(
                    current: reply.current, max: reply.max, timestamp: Self.now
                )
                return reply
            }
            completion(accepted)
        }
    }

    /// Async wrapper around `readAsync`.
    func read(displayID: CGDirectDisplayID, command: UInt8) async -> (current: UInt16, max: UInt16)? {
        await withCheckedContinuation { continuation in
            readAsync(displayID: displayID, command: command) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Write coalescing (ddcQueue)

    private func isWritePending(_ key: WriteKey) -> Bool {
        lock.withLock { pendingWrites[key] != nil }
    }

    private func isStale(_ key: WriteKey, generation: UInt64) -> Bool {
        lock.withLock { pendingWrites[key].map { $0.generation != generation } ?? true }
    }

    private func drainWrite(_ key: WriteKey) {
        // Taking the job and clearing `drainingKeys` in one critical section means a write
        // that arrives right after always schedules a new drain.
        guard let job = lock.withLock({ () -> (value: UInt16, generation: UInt64)? in
            guard let pending = pendingWrites[key] else {
                drainingKeys.remove(key)
                return nil
            }
            return (pending.value, pending.generation)
        }) else { return }

        var succeeded = false
        for attempt in 0..<Self.maxAttempts {
            waitForCommandGap(key.displayID)
            let result = writeSynchronous(displayID: key.displayID, command: key.vcp, value: job.value)
            lastCommandAt[key.displayID] = Self.now
            if case .value = result {
                succeeded = true
                break
            }
            if case .noService = result, attempt > 0 { break }
            // Don't keep retrying a value the user has already moved past.
            if isStale(key, generation: job.generation) { break }
#if arch(arm64)
            // The display's proxy may have been recreated (reconnect, wake): re-match once.
            if attempt == 0 { invalidateAVMap() }
#endif
        }

        let completion = lock.withLock { () -> (@Sendable (DDCWriteOutcome) -> Void)?? in
            guard let pending = pendingWrites[key], pending.generation == job.generation else {
                return nil   // a newer value is waiting
            }
            pendingWrites[key] = nil
            drainingKeys.remove(key)
            return .some(pending.completion)
        }
        if let completion {
            completion?(succeeded ? .success : .failure)
        } else {
            // Re-dispatch instead of looping so queued reads get a turn in between.
            ddcQueue.async { self.drainWrite(key) }
        }
    }

    private func waitForCommandGap(_ displayID: CGDirectDisplayID) {
        guard let last = lastCommandAt[displayID] else { return }
        let elapsed = Self.now - last
        if elapsed < Self.commandGapNanos {
            Thread.sleep(forTimeInterval: Double(Self.commandGapNanos - elapsed) / 1e9)
        }
    }

    // MARK: - Reply parsing

    /// Validates a DDC/CI Get VCP Feature reply and extracts (current, max).
    ///
    ///   [0] source address (0x6E)    [1] length (0x88)        [2] 0x02 (Get VCP reply opcode)
    ///   [3] result (0 = no error)    [4] VCP code echo        [5] VCP type
    ///   [6..7] max (big-endian)      [8..9] current           [10] checksum = 0x50 ^ bytes 0…9
    ///
    /// Anything else is a NAK, a stale reply or line noise; reading values out of it would
    /// report a bogus brightness, so it is rejected (callers retry).
    static func parseVCPReply(_ reply: [UInt8], command: UInt8) -> (current: UInt16, max: UInt16)? {
        guard reply.count >= 11 else { return nil }
        var checksum: UInt8 = 0x50
        for byte in reply[0..<10] { checksum ^= byte }
        guard reply[0] == 0x6E, reply[2] == 0x02, reply[3] == 0x00, reply[4] == command,
              checksum == reply[10] else { return nil }
        let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return (current, maxValue)
    }

    // MARK: - Synchronous DDC I/O (ddcQueue)

    private enum ReadResult {
        case value((current: UInt16, max: UInt16))
        case failed
        case noService
    }

    private enum WriteResult {
        case value
        case failed
        case noService
    }

    private func writeSynchronous(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> WriteResult {
#if arch(arm64)
        return arm64Write(displayID: displayID, command: command, value: value)
#else
        return intelWrite(displayID: displayID, command: command, value: value)
#endif
    }

    private func readSynchronous(displayID: CGDirectDisplayID, command: UInt8) -> ReadResult {
#if arch(arm64)
        return arm64Read(displayID: displayID, command: command)
#else
        return intelRead(displayID: displayID, command: command)
#endif
    }

    // MARK: - ARM64 IOAVService Path

#if arch(arm64)

    /// Identity of an external display as its framebuffer reports it in the IORegistry.
    private struct FramebufferIdentity {
        let vendor: UInt32?
        let product: UInt32?
        let serial: UInt32?
        let name: String?
    }

    private struct AVProxy {
        /// Name of the `dispextN` node whose framebuffer drives this proxy, if found.
        let link: String?
        let service: IOAVServiceRef
    }

    /// The service for a display, re-matching all services when the map is missing or stale.
    private func findAVService(for displayID: CGDirectDisplayID) -> IOAVServiceRef? {
        if let service = avMap[displayID] { return service }
        if avMapBuiltAt != 0, Self.now - avMapBuiltAt < Self.avMapNegativeTTLNanos { return nil }
        rebuildAVMap()
        return avMap[displayID]
    }

    private func invalidateAVMap() {
        for service in avMap.values { releaseAVService(service) }
        avMap.removeAll()
        avMapBuiltAt = 0
    }

    /// Matches every external DCPAVServiceProxy to a candidate display.
    ///
    /// The identity of a display lives on its `IOMobileFramebufferShim` (`DisplayAttributes` →
    /// `ProductAttributes`), a child of the `dispextN` node. The proxy hangs below the sibling
    /// `dcpextN` coprocessor node; its parent is named `dispextN:dcpav-service-epic:…`, which
    /// links the two. Pairs are scored on vendor, product, serial and name. Index matching is
    /// only used when exactly one proxy and one display remain, so a display falls back to
    /// software dimming rather than controlling another monitor.
    private func rebuildAVMap() {
        invalidateAVMap()
        avMapBuiltAt = Self.now

        let candidates = lock.withLock { self.candidates }
        var proxies = externalAVProxies()
        guard !candidates.isEmpty, !proxies.isEmpty else {
            proxies.forEach { releaseAVService($0.service) }
            return
        }
        let identities = framebufferIdentities()

        var proxyFor: [Int: Int] = [:]          // candidate index → proxy index
        var usedProxies = Set<Int>()

        // 1. Strong identity matches, best first. Equal scores (identical monitors) pair up in
        //    dispextN order against display ID order, so the result is at least stable.
        var pairs: [(score: Int, proxy: Int, candidate: Int)] = []
        for (p, proxy) in proxies.enumerated() {
            guard let link = proxy.link, let identity = identities[link] else { continue }
            for (c, candidate) in candidates.enumerated() {
                let score = Self.matchScore(identity, candidate)
                if score >= 5 { pairs.append((score, p, c)) }
            }
        }
        pairs.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let orderA = Self.linkOrder(proxies[a.proxy].link), orderB = Self.linkOrder(proxies[b.proxy].link)
            if orderA != orderB { return orderA < orderB }
            return candidates[a.candidate].displayID < candidates[b.candidate].displayID
        }
        for pair in pairs where proxyFor[pair.candidate] == nil && !usedProxies.contains(pair.proxy) {
            proxyFor[pair.candidate] = pair.proxy
            usedProxies.insert(pair.proxy)
        }

        // 2. Product name alone, when it is unique among what's left.
        for (p, proxy) in proxies.enumerated() where !usedProxies.contains(p) {
            guard let link = proxy.link, let name = identities[link]?.name.map(Self.normalizedName) else { continue }
            let matches = candidates.indices.filter {
                proxyFor[$0] == nil && candidates[$0].name.map(Self.normalizedName) == name
            }
            if matches.count == 1 {
                proxyFor[matches[0]] = p
                usedProxies.insert(p)
            }
        }

        // 3. One proxy and one display left: they belong together (the common single-monitor
        //    case, also when the registry reports IDs CoreGraphics doesn't).
        let freeProxies = proxies.indices.filter { !usedProxies.contains($0) }
        let freeCandidates = candidates.indices.filter { proxyFor[$0] == nil }
        if freeProxies.count == 1, freeCandidates.count == 1 {
            proxyFor[freeCandidates[0]] = freeProxies[0]
            usedProxies.insert(freeProxies[0])
        }

        for (c, p) in proxyFor {
            avMap[candidates[c].displayID] = proxies[p].service
#if DEBUG
            print("[DDCService] AVService \(proxies[p].link ?? "?") → display \(candidates[c].displayID)")
#endif
        }
        for (p, proxy) in proxies.enumerated() where !usedProxies.contains(p) {
            releaseAVService(proxy.service)
        }
        proxies.removeAll()
    }

    /// vendor ±4, product ±4, serial ±2 (only when both report a real one), name +1.
    private static func matchScore(_ identity: FramebufferIdentity, _ candidate: DDCCandidate) -> Int {
        var score = 0
        if let vendor = identity.vendor { score += vendor == candidate.vendor ? 4 : -4 }
        if let product = identity.product { score += product == candidate.model ? 4 : -4 }
        if let serial = identity.serial, isMeaningfulSerial(serial), isMeaningfulSerial(candidate.serial) {
            score += serial == candidate.serial ? 2 : -2
        }
        if let name = identity.name, let candidateName = candidate.name,
           normalizedName(name) == normalizedName(candidateName) {
            score += 1
        }
        return score
    }

    /// Many monitors report a placeholder serial (0 or 0x01010101).
    private static func isMeaningfulSerial(_ serial: UInt32) -> Bool {
        serial != 0 && serial != 0x0101_0101
    }

    /// NSScreen appends " (2)" to duplicate names; compare without it, case-insensitively.
    private static func normalizedName(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: #"\s\(\d+\)$"#, options: .regularExpression) {
            trimmed.removeSubrange(range)
        }
        return trimmed.lowercased()
    }

    /// The N of `dispextN`, for a stable order among equal matches.
    private static func linkOrder(_ link: String?) -> Int {
        guard let link, let number = Int(link.drop(while: { !$0.isNumber })) else { return Int.max }
        return number
    }

    /// External framebuffers keyed by their parent node's name (`dispextN`).
    private func framebufferIdentities() -> [String: FramebufferIdentity] {
        var identities: [String: FramebufferIdentity] = [:]
        for className in ["IOMobileFramebufferShim", "AppleCLCD2"] {
            forEachService(matching: className) { service in
                if let external = registryProperty(service, "external") as? Bool, !external { return }
                guard let parentName = parentName(of: service), identities[parentName] == nil,
                      let attributes = registryProperty(service, "DisplayAttributes") as? [String: Any],
                      let product = attributes["ProductAttributes"] as? [String: Any] else { return }
                identities[parentName] = FramebufferIdentity(
                    vendor: (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                    product: (product["ProductID"] as? NSNumber)?.uint32Value,
                    serial: (product["SerialNumber"] as? NSNumber)?.uint32Value,
                    name: product["ProductName"] as? String
                )
            }
        }
        return identities
    }

    /// Creates an IOAVService for every external DCPAVServiceProxy. The caller owns them.
    private func externalAVProxies() -> [AVProxy] {
        var proxies: [AVProxy] = []
        forEachService(matching: "DCPAVServiceProxy") { service in
            // Some drivers omit "Location"; still consider those.
            if let location = registryProperty(service, "Location") as? String, location != "External" { return }
            guard let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service) else { return }
            proxies.append(AVProxy(link: proxyLink(service), service: avService))
        }
        return proxies
    }

    /// The `dispextN` name of the framebuffer a proxy belongs to: the prefix of the proxy's
    /// parent (`dispext1:dcpav-service-epic:0`), else derived from its `dcpextN` ancestor.
    private func proxyLink(_ service: io_service_t) -> String? {
        if let name = parentName(of: service), let colon = name.firstIndex(of: ":") {
            return String(name[..<colon])
        }
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<12 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
            let name = entryName(current)
            if name.hasPrefix("dcpext") { return "disp" + name.dropFirst("dcp".count) }
            if name == "dcp" { return "disp0" }
        }
        return nil
    }

    private func releaseAVService(_ service: IOAVServiceRef) {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(service)).release()
    }

    /// ARM64 DDC write: send a Set VCP command via IOAVService.
    /// Buffer layout (bytes sent after the device address / offset arguments):
    ///   [0x84, 0x03, vcpCode, valueHigh, valueLow, checksum]
    private func arm64Write(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> WriteResult {
        guard let avService = findAVService(for: displayID) else { return .noService }

        // Checksum: 0x6E (display address) XOR 0x51 (host source address, sent by
        // IOAVServiceWriteI2C as the data address) XOR every payload byte.
        let payload: [UInt8] = [0x84, 0x03, command, UInt8(value >> 8), UInt8(value & 0xFF)]
        var buffer = payload + [payload.reduce(UInt8(0x6E ^ 0x51), ^)]
        let ret = IOAVServiceWriteI2C(avService, 0x37, 0x51, &buffer, UInt32(buffer.count))
#if DEBUG
        print("[DDCService] ARM64 write VCP 0x\(String(command, radix: 16)) = \(value) → \(ret == kIOReturnSuccess ? "OK" : "failed (\(ret))")")
#endif
        return ret == kIOReturnSuccess ? .value : .failed
    }

    /// ARM64 DDC read: send a Get VCP request then read the response via IOAVService.
    /// Request layout: [0x82, 0x01, vcpCode, checksum]
    private func arm64Read(displayID: CGDirectDisplayID, command: UInt8) -> ReadResult {
        guard let avService = findAVService(for: displayID) else { return .noService }

        let payload: [UInt8] = [0x82, 0x01, command]
        var request = payload + [payload.reduce(UInt8(0x6E ^ 0x51), ^)]
        guard IOAVServiceWriteI2C(avService, 0x37, 0x51, &request, UInt32(request.count)) == kIOReturnSuccess else {
            return .failed
        }

        // The display needs ~40 ms to prepare its DDC/CI reply.
        Thread.sleep(forTimeInterval: 0.04)

        var reply = [UInt8](repeating: 0, count: 12)
        guard IOAVServiceReadI2C(avService, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
              let value = Self.parseVCPReply(reply, command: command) else {
#if DEBUG
            print("[DDCService] ARM64 read VCP 0x\(String(command, radix: 16)) failed: \(reply.map { String(format: "%02X", $0) }.joined(separator: " "))")
#endif
            return .failed
        }
        return .value(value)
    }
#endif

    // MARK: - Intel (x86_64) IOFramebuffer Path

    /// IOFramebuffer services that may carry the display's DDC bus, each retained (caller
    /// releases). `CGDisplayIOServicePort` returns the framebuffer itself; IODisplayConnect
    /// matching (its parent is the framebuffer) is the fallback.
    private func framebufferServices(for displayID: CGDirectDisplayID) -> [io_service_t] {
        var services: [io_service_t] = []
        if let port = CGHelpers.framebufferPort(for: displayID) {
            IOObjectRetain(port)
            services.append(port)
        }

        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        forEachService(matching: "IODisplayConnect") { service in
            guard let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?
                .takeRetainedValue() as? [String: Any],
                  (info["DisplayVendorID"] as? NSNumber)?.uint32Value == vendor,
                  (info["DisplayProductID"] as? NSNumber)?.uint32Value == model else { return }
            // Tell identical monitors apart when they report real serial numbers.
            if serial != 0, let infoSerial = (info["DisplaySerialNumber"] as? NSNumber)?.uint32Value,
               infoSerial != 0, infoSerial != serial { return }
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { return }
            if services.contains(parent) {
                IOObjectRelease(parent)
            } else {
                services.append(parent)
            }
        }
        return services
    }

    /// Runs `body` with an open I2C connection for each bus of each framebuffer of the
    /// display until it returns true.
    private func withI2CConnections(
        for displayID: CGDirectDisplayID,
        _ body: (IOI2CConnectRef) -> Bool
    ) -> (found: Bool, succeeded: Bool) {
        let framebuffers = framebufferServices(for: displayID)
        defer { framebuffers.forEach { IOObjectRelease($0) } }
        guard !framebuffers.isEmpty else { return (false, false) }

        for framebuffer in framebuffers {
            // The DDC bus is not always bus 0.
            for bus: UInt32 in 0..<8 {
                var interface: io_service_t = 0
                guard IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface) == KERN_SUCCESS else { continue }
                defer { IOObjectRelease(interface) }
                var connection: IOI2CConnectRef?
                guard IOI2CInterfaceOpen(interface, IOOptionBits(0), &connection) == KERN_SUCCESS,
                      let connection else { continue }
                defer { IOI2CInterfaceClose(connection, IOOptionBits(0)) }
                if body(connection) { return (true, true) }
            }
        }
        return (true, false)
    }

    private func intelWrite(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> WriteResult {
        // [0x51, 0x84, 0x03, VCP, value high, value low, checksum]
        var packet: [UInt8] = [0x51, 0x84, 0x03, command, UInt8(value >> 8), UInt8(value & 0xFF)]
        packet.append(packet.reduce(UInt8(0x6E), ^))

        let result = withI2CConnections(for: displayID) { connection in
            packet.withUnsafeMutableBytes { raw -> Bool in
                guard let pointer = raw.baseAddress else { return false }
                var request = IOI2CRequest()
                request.sendAddress = 0x6E
                request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.sendBuffer = UInt(bitPattern: pointer)
                request.sendBytes = UInt32(raw.count)
                request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                request.minReplyDelay = 10_000_000  // 10 ms
                return IOI2CSendRequest(connection, IOOptionBits(0), &request) == KERN_SUCCESS
                    && request.result == KERN_SUCCESS
            }
        }
        guard result.found else { return .noService }
        return result.succeeded ? .value : .failed
    }

    private func intelRead(displayID: CGDirectDisplayID, command: UInt8) -> ReadResult {
        // [0x51, 0x82, 0x01, VCP, checksum]
        var packet: [UInt8] = [0x51, 0x82, 0x01, command]
        packet.append(packet.reduce(UInt8(0x6E), ^))
        var value: (current: UInt16, max: UInt16)?

        let result = withI2CConnections(for: displayID) { connection in
            var reply = [UInt8](repeating: 0, count: 12)
            let sent = packet.withUnsafeMutableBytes { sendRaw in
                reply.withUnsafeMutableBytes { replyRaw -> Bool in
                    guard let sendPointer = sendRaw.baseAddress,
                          let replyPointer = replyRaw.baseAddress else { return false }
                    var request = IOI2CRequest()
                    request.sendAddress = 0x6E
                    request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    request.sendBuffer = UInt(bitPattern: sendPointer)
                    request.sendBytes = UInt32(sendRaw.count)
                    request.replyAddress = 0x6F
                    request.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
                    request.replyBuffer = UInt(bitPattern: replyPointer)
                    request.replyBytes = UInt32(replyRaw.count)
                    request.minReplyDelay = 50_000_000  // 50 ms
                    return IOI2CSendRequest(connection, IOOptionBits(0), &request) == KERN_SUCCESS
                        && request.result == KERN_SUCCESS
                }
            }
            guard sent, let parsed = Self.parseVCPReply(reply, command: command) else { return false }
            value = parsed
            return true
        }
        guard result.found else { return .noService }
        return value.map { .value($0) } ?? .failed
    }

    // MARK: - IORegistry helpers

    private func forEachService(matching className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            body(service)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func entryName(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)  // io_name_t
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func parentName(of entry: io_registry_entry_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        let name = entryName(parent)
        return name.isEmpty ? nil : name
    }
}
