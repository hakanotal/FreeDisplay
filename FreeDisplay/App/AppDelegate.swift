import AppKit
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here rather than by a view, so launch, sleep and wake handling run even if the
    /// menu panel is never opened (MenuBarExtra builds its content lazily).
    let displayManager: DisplayManager
    private var workspaceObservers: [NSObjectProtocol] = []
    private var notificationObservers: [NSObjectProtocol] = []
    /// False for a duplicate launch that quits right away: it must not touch display state.
    private var servicesStarted = false

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
            // A quitting instance restores the transfer tables it wrote. Wait until it is gone
            // before applying display state, or it would wipe ours.
            await Self.waitForTermination(of: replacedInstances, timeout: 5)
            // Migrate the old login item / hand a manual launch over to the launchd agent.
            // After a hand-over the agent's instance replaces this one within moments; starting
            // services meanwhile would only flash brightness and night mode. Start anyway if
            // it never arrives.
            if LaunchService.shared.prepareAtLaunch() {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            self.startServices()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard servicesStarted else { return }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        BrightnessKeyService.shared.stop()
        BrightnessService.shared.flushPendingWrites()
        // Give every display FreeDisplay changed its profile's own transfer function back.
        GammaService.shared.restoreSystemCurves()
        VirtualDisplayService.shared.destroyAll()
    }

    // MARK: - Startup

    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
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

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ResolutionService.shared.snapshotModesBeforeSleep() }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayManager.reapplyDisplayStateAfterWake() }
        })
        // Display sleep (no system sleep) can reset transfer tables too.
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayManager.handleScreensWake() }
        })
        // A profile switch (ours or System Settings') makes ColorSync rewrite the table,
        // wiping night mode, software dimming and image adjustments.
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSScreen.colorSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayManager.handleColorSpaceChange() }
        })

        // Opt-in "external displays above built-in": apply once displays have settled.
        if SettingsService.shared.autoArrangeExternalAbove {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.displayManager.arrangeExternalAboveBuiltin()
            }
        }

        if SettingsService.shared.checkUpdatesOnLaunch {
            Task { await UpdateService.shared.checkForUpdates() }
        }
    }

    private static func waitForTermination(of apps: [NSRunningApplication], timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
