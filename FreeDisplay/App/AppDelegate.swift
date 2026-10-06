import AppKit
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here rather than by a view, so launch, sleep and wake handling run even if the
    /// menu panel is never opened (MenuBarExtra builds its content lazily).
    let displayManager: DisplayManager
    private var workspaceObservers: [NSObjectProtocol] = []

    override init() {
        // Must run before any service reads its defaults.
        SettingsService.migrateLegacyDefaults()
        displayManager = DisplayManager()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate launches: exit if another instance is already running
        let otherInstances = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier &&
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        var replacedInstances: [NSRunningApplication] = []
        if !otherInstances.isEmpty {
            if LaunchService.isManagedLaunch {
                // Started by the launchd agent (login / crash restart / hand-over): replace the
                // manually opened copy so the supervised instance is the one that keeps running.
                otherInstances.forEach { $0.terminate() }
                replacedInstances = otherInstances
            } else {
                print("[FreeDisplay] Another instance is already running, exiting.")
                NSApp.terminate(nil)
                return
            }
        }

        Task { @MainActor in
            // A quitting instance resets the gamma tables it wrote. Wait until it is gone
            // before applying display state, or it would wipe ours.
            await Self.waitForTermination(of: replacedInstances, timeout: 5)
            self.startServices()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        BrightnessKeyService.shared.stop()
        // GammaService restores identity transfer tables via its willTerminateNotification observer.
        VirtualDisplayService.shared.destroyAll()
    }

    // MARK: - Startup

    private func startServices() {
        // Migrate the old login item / hand a manual launch over to the launchd agent.
        LaunchService.shared.prepareAtLaunch()
        SettingsService.shared.launchAtLogin = LaunchService.shared.isEnabled

        displayManager.start()

        // Start intercepting brightness keys to route them to the display under the cursor.
        BrightnessKeyService.shared.start()

        // Apply the saved night mode state and start following its schedule.
        NightModeService.shared.start()

        // Re-cover the notch if the user hid it in an earlier session.
        NotchOverlayManager.shared.restoreSavedOverlays()

        // These start work in their initializers (auto brightness polling, virtual display
        // auto-create). Touch them now so it doesn't wait until their menu section is opened.
        _ = AutoBrightnessService.shared
        _ = VirtualDisplayService.shared

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in ResolutionService.shared.snapshotModesBeforeSleep() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.displayManager.reapplyDisplayStateAfterWake() }
        })

        // Opt-in "external displays above built-in": apply once displays have settled.
        if SettingsService.shared.autoArrangeExternalAbove {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.displayManager.arrangeExternalAboveBuiltin()
            }
        }
    }

    private static func waitForTermination(of apps: [NSRunningApplication], timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
