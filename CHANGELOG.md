# Changelog

All notable changes to FreeDisplay are documented here.

---

## Unreleased

Display arrangement fix and fixes from a full code review.

- **Arrangement no longer resets**: a hidden "external above built-in" auto-arrange was forced on and re-ran 2 s after every menu open and after mode changes, moving displays back. It is now an opt-in switch in Arrange Displays (off by default, also for existing installs) that turns itself off when you arrange displays by hand, and it lines up several external displays side by side instead of stacking them on one spot
- **Arrangement editor**: dragging snaps the display flush against the nearest edge like System Settings (with a preview outline), keeps it where you dropped it, and applies the whole layout in one step that macOS remembers (also across reconnects and restarts). "Set as main display" keeps the layout instead of swapping positions. Positions are refreshed when you rearrange in System Settings
- **Built-in brightness on Apple Silicon**: the built-in slider, the combined slider and Auto Brightness now work (they read and set the panel through DisplayServices; Auto Brightness used to read 100% all the time)
- **After sleep and at login**: brightness, image adjustments, night mode and resolution are restored even if the menu was never opened, Auto Brightness and auto-created virtual displays start at launch, and DDC is re-detected after wake. Resolution is only restored when it changed during sleep, so a mode picked in System Settings is no longer overwritten on the next wake
- **Image adjustments**: closing the section or Reset All no longer removes the selected color profile or software dimming; adjustments are saved immediately and survive wake/reconnect; Pause keeps night mode and dimming; positive contrast and gain now have an effect; inverted colors respect dimming and night mode
- **External brightness**: no more double dimming when a monitor that once fell back to software brightness works over DDC again; DDC replies are validated; the slider shows the right value after presets, Auto Brightness, the keyboard or the monitor's own buttons
- **HiDPI**: turning HiDPI off for a monitor sticks (it was re-enabled on the next launch or reconnect), and plugging in a monitor never pops an administrator prompt on its own
- **Presets**: the arrangement is restored correctly (all displays, including the built-in, in one step) and the "current" marker tells HiDPI and non-HiDPI modes apart
- **Virtual displays**: each one has its own identity and name, inactive ones can be switched on again from the list, and auto-create no longer skips a display that has the same size as a real monitor
- **Notch**: "Hide notch area" now fills the built-in screen's menu bar row (it landed off-screen, or just below the menu bar, covering the top of the desktop), keeps the menu bar items visible, follows the screen when the arrangement changes, and is remembered across relaunches, sleep and reconnects
- **Other**: brightness keys over displays FreeDisplay can't control (Sidecar, AirPlay) behave normally again; external display names no longer get stuck as "Display N"; update checks point at the real repository; removed unused code (mirroring service, resolution slider, color picker)

---

## v2.1 (2026-10-03)

Crash fixes from a full code review.

- **Resolution fallback crash**: the private `CGSConfigureDisplayMode` was declared and called with a connection ID instead of a `CGDisplayConfigRef`, so CoreGraphics dereferenced a bogus pointer whenever the normal mode switch failed (e.g. around reconnect or wake). Now uses the real signature inside a display configuration transaction
- **Display arrangement crash**: `CGCancelDisplayConfiguration` was called after a failed `CGCompleteDisplayConfiguration`, which already invalidates the configuration (use-after-free), e.g. when auto-arrange runs while an app is full screen
- **Brightness keys**: the event tap no longer leaks one event per media key press (`passUnretained` for pass-through events)
- **DDC**: IOAVService objects that fail the I2C probe are released instead of leaked
- **Hardening**: XPC OSD handlers are explicitly `@Sendable`; HiDPI auto-enable skips FreeDisplay's own virtual displays (no admin prompt on the main thread)

---

## v2.0 (2026-10-02) — Turkish edition

By [@hakanotal](https://github.com/hakanotal).

- **Turkish + English UI**: full Turkish translation (labels, tooltips, alerts, VoiceOver labels); live language switch in Settings → Dil / Language
- **Night mode**: blue light filter (Off / On / Scheduled, overnight ranges, warmth slider, 1.5 s fades), applied through GammaService alongside image adjustments and software brightness
- **macOS 27**: menu panel no longer collapses to the footer, and shrinks back when sections collapse
- **Crash fix**: DDC brightness callbacks and the brightness OSD error handler no longer trap under Swift 6 runtime isolation checks
- **Color profile**: subtitle shows the active ICC profile name (e.g. the monitor's EDID profile) and refreshes on change; the list only offers RGB display-class profiles — applying CMYK/gray/Lab/abstract profiles aborted the app inside SkyLight
- **Auto-restart**: "Launch at login" is now a per-user launchd agent (`~/Library/LaunchAgents/com.freedisplay.app.agent.plist`) with `KeepAlive.SuccessfulExit = false` — relaunches after a crash, not after Quit; the old SMAppService login item is migrated automatically
- **HiDPI**: the first enable/disable makes the monitor's override folder user-writable (one admin prompt); later toggles need no password
- **Menu**: removed built-in "Native Mode" / "HiDPI Mode" preset buttons; Settings switches right-aligned
- **Build & release**: universal (arm64 + x86_64) builds without Xcode (`scripts/build-app-clt.sh`), versioned DMG + SHA-256 (`scripts/build-dmg.sh`), ad-hoc signing instead of the upstream team ID, MIT `LICENSE`

---

## v1.0.0 (2026-03-05)

Initial public release — full-featured BetterDisplay alternative.

### Core Features

- **Display Detection & Menu Bar UI** (Phase 1)
  - Multi-monitor detection (built-in + external)
  - MenuBarExtra-based UI with per-display panels
  - Display identification (visual flash)

- **DDC Brightness & Contrast Control** (Phase 2)
  - IOKit I2C DDC/CI communication
  - Hardware brightness and contrast sliders for external monitors
  - Software gamma brightness for built-in displays

- **Resolution Management & HiDPI** (Phase 3)
  - Resolution list with HiDPI/native/scaled modes
  - HiDPI virtual display creation (CGVirtualDisplay)
  - Resolution slider for quick switching

- **Rotation & Arrangement** (Phase 4)
  - Display rotation: 0°/90°/180°/270°
  - Visual display arrangement editor

- **Color Management** (Phase 5)
  - ICC color profile switching per display
  - Color mode display (8-bit/10-bit, SDR/HDR)

- **Image Adjustment** (Phase 6)
  - Software contrast, gamma, color temperature
  - Per-channel RGB gain control
  - Color inversion

- **Advanced Display Management** (Phase 7)
  - Set primary display
  - Display info panel (resolution, refresh rate, vendor)

- **Screen Mirroring** (Phase 8)
  - Mirror any display to any other display
  - Mirror enable/disable toggle

- **Screen Streaming & Picture-in-Picture** (Phase 9)
  - ScreenCaptureKit-based screen capture
  - Floating PiP window with configurable size and position
  - Stream controls: flip, rotate, scale, crop, opacity, video filters

- **Virtual Display** (Phase 10)
  - Create HiDPI virtual/dummy displays
  - Useful for headless Macs or extending workspace

- **Config Protection & Auto Brightness** (Phase 11)
  - Prevent macOS from resetting display configuration
  - Time-based auto brightness scheduling

- **Notch Management** (Phase 12)
  - Notch overlay show/hide for MacBooks with notch

### Stability & Polish

- **Critical Bug Fixes** (Phase 13)
  - DDC communication reliability improvements
  - CoreGraphics API usage corrections

- **Performance Optimization** (Phase 14)
  - Async display enumeration
  - Reduced UI blocking on IOKit calls

- **UX Improvements** (Phase 15)
  - Improved slider responsiveness
  - Better error states and user feedback

- **Comprehensive Bug Fixes — 134 bugs** (Phase 16)
  - 5 rounds of systematic bug fixing across all features
  - 3 rounds of UI/UX polish
  - Unified hover effects across all views
  - Extracted reusable components: DetailRow, ExpandableRow, ProtectionRowView
  - DisplayDetailView three-group layout
  - Rotation 2×2 grid layout
  - ArrangementView interior/exterior display thumbnail distinction
  - DisplayModeList favorites pinned to top
  - ConfigProtection active protection badge

- **DDC / HiDPI / Notch Targeted Fixes** (Phase 17)
  - CGVirtualDisplay: vendorID must be non-zero
  - CGVirtualDisplay must be created on main thread
  - Bridging header property name corrections
  - One-click display presets completed

- **CG Timeout Protection + Wake Recovery** (Phase 18)
  - CoreGraphics call timeout protection
  - Sleep/wake display state recovery
  - GammaService wake notification handler
  - BrightnessService wake reapplication

### Preset System

- **Display Preset One-Click Switching** (Phase 19)
  - Save full display configuration as named preset
  - Instant restore: resolution, brightness, rotation, color profile
  - Preset management UI (create, rename, delete)

### Release

- **App Icon, DMG Packaging, Launch at Login** (Phase 20)
  - App icon: gradient blue-purple monitor with "F" lettermark
  - DMG installer with Applications shortcut
  - SMAppService-based launch at login (macOS 13+)
  - README, CHANGELOG, release automation script
  - UpdateService pointing to GitHub Releases API
