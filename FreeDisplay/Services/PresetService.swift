import Foundation
import CoreGraphics

/// Manages display configuration presets: save, load, and one-click apply.
@MainActor
final class PresetService: ObservableObject, @unchecked Sendable {
    static let shared = PresetService()

    @Published var presets: [DisplayPreset] = []
    @Published var isApplying: Bool = false
    @Published var applyingPresetID: UUID? = nil
    /// The preset whose modes match the current displays (the "Current" badge). Updated by
    /// DisplayManager after display and mode changes, and here after preset changes.
    @Published private(set) var currentMatchID: UUID?

    private let filename = "presets.json"

    private init() {
        loadPresets()
    }

    // MARK: - Persistence

    func loadPresets() {
        presets = SettingsService.shared.load([DisplayPreset].self, filename: filename) ?? []
        updateCurrentMatch()
    }

    func savePresets() {
        SettingsService.shared.save(presets, filename: filename)
    }

    // MARK: - CRUD

    func addPreset(_ preset: DisplayPreset) {
        presets.append(preset)
        savePresets()
        updateCurrentMatch()
    }

    func deletePreset(id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets.remove(at: index)
        savePresets()
        updateCurrentMatch()
    }

    // MARK: - Apply

    /// Applies a preset: resolution and brightness per external display, then the saved
    /// arrangement for all displays in a single transaction.
    func applyPreset(_ preset: DisplayPreset) async {
        guard !isApplying else { return }
        isApplying = true
        applyingPresetID = preset.id
        defer {
            isApplying = false
            applyingPresetID = nil
            updateCurrentMatch()
        }

        let displays = DisplayManagerAccessor.shared.displays
        let matched: [(entry: DisplayPresetEntry, display: DisplayInfo)] = preset.displays.compactMap { entry in
            guard let display = displays.first(where: { $0.displayUUID == entry.displayUUID }) else { return nil }
            return (entry, display)
        }

        var positions: [CGDirectDisplayID: CGPoint] = [:]
        for (entry, display) in matched {
            if let x = entry.arrangementX, let y = entry.arrangementY {
                positions[display.displayID] = CGPoint(x: x, y: y)
            }
        }
        // The preset carries its own layout: stop the automatic arrangement from overriding
        // it when the mode changes below trigger a reconfiguration.
        if !positions.isEmpty {
            SettingsService.shared.autoArrangeExternalAbove = false
        }

        for (entry, display) in matched {
            // Never change the built-in display's resolution or brightness via presets.
            // A mirror target's mode follows its source.
            guard !display.isBuiltin, !display.isMirrorTarget else { continue }

            let targetMode = display.availableModes.first(where: {
                $0.width == entry.width && $0.height == entry.height && $0.isHiDPI == entry.isHiDPI
            }) ?? display.availableModes.first(where: {
                $0.width == entry.width && $0.height == entry.height
            })

            if let mode = targetMode {
                let current = display.currentDisplayMode
                let alreadyActive = current?.width == mode.width
                    && current?.height == mode.height
                    && current?.isHiDPI == mode.isHiDPI
                if !alreadyActive {
                    let ok = await ResolutionService.shared.setDisplayMode(mode, for: display.displayID)
                    if ok { display.currentDisplayMode = mode }
                }
            } else {
                print("[PresetService] No mode \(entry.width)×\(entry.height) hiDPI=\(entry.isHiDPI) for \(display.name)")
            }

            // Brightness is stored 0.0–1.0; BrightnessService uses 0–100.
            if let brightness = entry.brightness {
                BrightnessService.shared.setBrightness(brightness * 100.0, for: display)
            }
        }

        if !positions.isEmpty {
            await applyPositions(positions, displays: displays)
        }
    }

    /// Moves displays to the saved origins in one transaction. Mode changes above may have
    /// resized displays, so live sizes are combined with the saved origins.
    private func applyPositions(_ positions: [CGDirectDisplayID: CGPoint], displays: [DisplayInfo]) async {
        var frames: [CGDirectDisplayID: CGRect] = [:]
        for display in displays where !display.isMirrorTarget {
            let bounds = CGDisplayBounds(display.displayID)
            frames[display.displayID] = CGRect(origin: positions[display.displayID] ?? bounds.origin,
                                               size: bounds.size)
        }
        // The display at (0, 0) was the main display when the preset was saved.
        let savedMain = positions.first(where: { $0.value == .zero })?.key
        guard let mainID = savedMain ?? displays.first(where: { $0.isMain })?.displayID else { return }
        let ok = await ArrangementService.shared.apply(frames: frames, mainID: mainID)
        if !ok { print("[PresetService] Applying arrangement failed") }
    }

    // MARK: - Capture

    /// Snapshots all current displays into a new preset. The built-in display is included
    /// for its position only (its mode and brightness are never changed). FreeDisplay's own
    /// virtual displays are left out: they come and go with their toggle.
    func captureCurrentState(name: String, icon: String) -> DisplayPreset {
        let displays = DisplayManagerAccessor.shared.displays
        let entries: [DisplayPresetEntry] = displays.compactMap { display in
            guard !display.isMirrorTarget, !display.isVirtual else { return nil }
            let mode = display.currentDisplayMode
            return DisplayPresetEntry(
                displayUUID: display.displayUUID,
                width: mode?.width ?? display.initialPixelWidth,
                height: mode?.height ?? display.initialPixelHeight,
                isHiDPI: mode?.isHiDPI ?? false,
                brightness: display.isBuiltin ? nil : display.brightness / 100.0,
                arrangementX: display.bounds.origin.x,
                arrangementY: display.bounds.origin.y
            )
        }
        return DisplayPreset(name: name, icon: icon, displays: entries)
    }

    /// Recomputes `currentMatchID`: the first preset whose every display is connected and in
    /// the saved mode.
    func updateCurrentMatch() {
        let displaysByUUID = Dictionary(
            DisplayManagerAccessor.shared.displays.map { ($0.displayUUID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let match = presets.first { preset in
            !preset.displays.isEmpty && preset.displays.allSatisfy { entry in
                guard let mode = displaysByUUID[entry.displayUUID]?.currentDisplayMode else { return false }
                return mode.width == entry.width && mode.height == entry.height && mode.isHiDPI == entry.isHiDPI
            }
        }?.id
        if currentMatchID != match { currentMatchID = match }
    }
}
