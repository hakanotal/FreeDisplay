# Lessons Learned

Hard-won constraints. Each one cost real debugging time; don't relearn them.

## HiDPI

- **Use plist overrides, never mirroring.** `CGConfigureDisplayMirrorOfDisplay` with a virtual display triggers hardware mirror mode and mouse stutter on Apple Silicon. Write `scale-resolutions` to `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-XXXX/DisplayProductID-XXXX` instead (the BetterDisplay approach).
- Writing there needs admin rights → `NSAppleScript("do shell script … with administrator privileges")`.
- Don't set `DisplayProductName` in the override plist; it replaces the system display name.
- macOS only loads new override modes when the display is (re)connected. `IOServiceRequestProbe` is not reliable.
- Native resolution = largest entry in `availableModes`. `CGDisplayPixelsWide/High` returns the *current* mode.

## Private APIs

- Load private framework symbols with `dlopen` + `dlsym`. `@_silgen_name` compiles but fails to link.
- `CGVirtualDisplay`: `vendorID` must be non-zero (e.g. `0xEEEE`) or init returns nil. `CGVirtualDisplay(descriptor:)` must run on the main thread; `apply(settings)` can run in the background.
- Bridging-header property names must match the runtime exactly (`maxPixelsWide`/`maxPixelsHigh`, not `maxPixelSize`). Use Chromium's `virtual_display_mac_util.mm` as the reference, never guess.
- Virtual displays are owned by the process and vanish when it quits. Give each one a unique, stable `serialNum`: macOS derives its identity (UUID, saved layout and mode) from vendor/product/serial, so a shared serial makes them all one "monitor".
- `CGSConfigureDisplayMode(CGDisplayConfigRef config, CGDirectDisplayID, int modeNum)` takes the transaction from `CGBeginDisplayConfiguration` as its first argument (see CGSInternal). Passing a connection ID makes CoreGraphics dereference a bogus pointer.
- Applying a non-display ICC profile (CMYK, gray, Lab/XYZ, abstract, named color) with `ColorSyncDeviceSetCustomProfiles` aborts the app inside SkyLight. Only offer `mntr` class + `RGB ` profiles. Read ICC signatures from `ColorSyncProfileCopyData`; `ColorSyncProfileCopyHeader` returns byte-swapped fields (`BGR `).

## DDC / IOKit

- Built-in brightness on Apple Silicon: there are no `IODisplayConnect` services and `CoreDisplay_Display_GetUserBrightness` returns 1.0. Use `DisplayServicesGet/SetBrightness` (dlsym).
- Validate DDC replies (opcode 0x02, result 0, VCP echo, checksum 0x50 ^ bytes 0…9). Unvalidated replies report bogus values.
- One failed DDC transfer isn't proof DDC is unsupported (monitor waking up). Re-probe after wake, and drop leftover software dimming once DDC works.
- IOFramebuffer I2C (`IOFBCopyI2CInterfaceForBus`) silently does nothing on Apple Silicon. Use IOAVService via `DCPAVServiceProxy`.
- Apple Silicon has no `DisplayVendorID` anywhere in the IORegistry. A `DCPAVServiceProxy`'s parent is named `dispextN:dcpav-service-epic:…`; the display's identity is on the sibling `dispextN` → `IOMobileFramebufferShim` → `DisplayAttributes.ProductAttributes` (`LegacyManufacturerID`, `ProductID`, `SerialNumber`, `ProductName`). Never pair services with displays by sorted index when more than one of each is left: a Sidecar or virtual display with a lower ID got the monitor's service.
- Vendor/model alone don't identify a monitor, and many report a placeholder serial (0x01010101). Match on a score (vendor, product, a real serial, `NSScreen.localizedName`), not on vendor/model equality.
- Don't probe DDC with an unsolicited I2C read: monitors that reject it, or are briefly busy, silently drop out.
- Coalesce DDC writes (latest value wins) and keep commands to a display ≥ 50 ms apart; monitors drop faster ones, and a queue of stale writes makes sliders and keys lag.
- `DisplayServicesGetBrightness` succeeds only for displays with a native backlight (built-in, Studio Display, XDR); other monitors return 1000. Use it to pick the native path for Apple externals.
- `CGDisplayIOServicePort` is imported as unavailable and deprecated: resolve it with `dlsym` (`CGHelpers.framebufferPort`), never bind it. It returns the IOFramebuffer itself (Intel), not a child.
- Integer values in IOKit CF dictionaries may bridge as `Int`, not `UInt32`. Try both.
- DDC reads take 50 ms or more. Cache them (5 s TTL), invalidate after writes, and degrade gracefully when DDC is unsupported.
- Keep microsecond IOKit calls synchronous. Making name lookup async caused races and "Display N" flicker.

## Shared resources & lifecycle

- One writer per CoreGraphics resource. `GammaService` owns the transfer table; `BrightnessService` supplies a factor it multiplies in. Every code path (formula *and* quantized table) must apply the factor.
- A transfer-table write replaces the profile's `vcgt` calibration curve. Compose on top of it (`CalibrationCurve`), restore it instead of identity, and never write displays FreeDisplay hasn't changed.
- A profile switch, display sleep and *every* completed display configuration rewrite the transfer table too, not only system sleep: arranging displays, changing the main display, opening or closing the lid. Reapply on `colorSpaceDidChange`, `screensDidWake` and after every reconfiguration, more than once (profiles load a moment later); passes are merged and idempotent.
- Never call `CGDisplayRestoreColorSyncSettings()` (global). Use `GammaService.resetSingleDisplay(_:)`.
- Resetting image adjustments must not touch the ColorSync profile, and pausing or resetting must keep software brightness and the night tint.
- Sleep resets all transfer tables. Reapply on `didWakeNotification` right away (in-memory state survives sleep) and again once WindowServer has settled, or the screen flashes at full brightness. GammaService reads the software factor itself (`effectiveSoftwareBrightness`), so there is no ordering to get wrong.
- Pass `self` to long-lived C callbacks with `Unmanaged.passRetained`, and `release()` on unregister.
- Keep service state on the main actor (`BrightnessService`, `GammaService`) and lock only what other threads really touch (`DDCService` caches, the event tap's display set).
- CGDirectDisplayIDs get reused by other monitors. Compare identity on refresh (`DisplayInfo.isSameMonitor`) and drop per-ID memory (`forgetDisplay`), or one monitor's dimming and adjustments land on another and get saved under its UUID.
- Mode IDs are per display. Never look up one display's mode ID on another (the old mirror redirect applied random modes to the source).
- Auto brightness must back off after a manual change (30 s cooldown).
- Set `NSWindow.isReleasedWhenClosed = false` for windows you keep in a dictionary.
- Don't mutate a dictionary while iterating it; collect the keys first.
- Wrap blocking WindowServer calls in `CGHelpers.runWithTimeout`.
- `CGCompleteDisplayConfiguration` invalidates the config on return, even when it fails. Never call `CGCancelDisplayConfiguration` after it (use-after-free); cancel only before completing.
- `CGConfigureDisplayOrigin`: the display at (0, 0) becomes main, and each completed transaction renormalizes. Move all displays in one transaction, translated so the intended main display sits at the origin.
- Complete display configurations `.permanently` (as System Settings does). `.forSession` arrangement and mode changes get reverted by WindowServer on reconnect/wake.
- Never auto-apply a layout from a reconfiguration callback for move events, and never on panel open: it fights the user's own arrangement.
- Key per-display settings by display UUID. CGDirectDisplayIDs can be reassigned, and a mode ID saved for one monitor is meaningless (or wrong) on another.
- Event tap callbacks don't own the passed-in event: return `Unmanaged.passUnretained(event)` to pass it through. `passRetained` leaks one event per call.
- An active (`.defaultTap`) event tap filters every media key in the session. Run it on its own thread: on the main run loop, any main-thread stall (an admin prompt) freezes volume and brightness keys system-wide.
- Swift 6 inserts a runtime main-thread check into closures created in a `@MainActor` context and passed as non-`@Sendable` parameters. If such a closure runs on another queue (DDC completions, XPC handlers), the app traps. Mark completion handlers that run off-main `@Sendable`.

## SwiftUI / MenuBarExtra

- Custom content needs `.menuBarExtraStyle(.window)`. Hide the Dock icon with `INFOPLIST_KEY_LSUIElement: true`.
- MenuBarExtra content is built lazily and its `.task`/`.onAppear` run on every panel open. Launch, wake and one-time work belongs in `AppDelegate`, and singletons whose init starts work must be touched at launch.
- `NSWindow(contentRect:…, screen:)` treats the rect as relative to that screen. Pass global rects without `screen:`.
- AppKit pushes windows out from under the menu bar (`constrainFrameRect`). A window meant to sit in the menu bar row (notch overlay) must override it to return the frame unchanged.
- On macOS 27 the panel is sized to the content's *minimum* size, so a bare `ScrollView` collapses to 0 height. Test layout on macOS 27, not only on the macOS 14 target.
- Row components with local state (`isHovered`, `isLoading`) must be separate `struct`s. `@ViewBuilder` functions can't hold `@State`.
- Observe shared singletons with `@ObservedObject`, not `@StateObject`.
- Every `@Published` change re-renders every view observing that object. A view that only needs a `DisplayInfo`'s constant fields takes `let display`, or each brightness tick rebuilds it.
- `State(initialValue:)` in a custom `init` is evaluated on every parent render (only the first value is kept). Keep it cheap; cache derived data in a reference instead.
- Don't animate the panel's height (springs, `.move` transitions, `withAnimation` around a toggle that adds rows): the MenuBarExtra window follows the measured content height, so it resizes in steps while rows slide inside it, which feels slow and laggy. Toggle without `withAnimation`, fade new content in briefly (`Disclosure.content`), animate only the chevron (`Disclosure.chevron`), and keep `.animation(nil, value: contentHeight)` on the ScrollView frame. Same as FreeAudio.
- A slider's custom `Binding` setter runs only for the user's own changes (drag, keyboard, VoiceOver); use it instead of `onChange`, which also fires when the value follows the model.
- Don't make IOKit/CG calls in `body`; load them in `.task`/`onAppear`.
- `flag = true; syncWork(); flag = false` never renders the intermediate state. Use async.

## Build

- After changing `project.yml` or adding files, run `xcodegen generate`.
- `GENERATE_INFOPLIST_FILE: YES` is required (XcodeGen doesn't create an Info.plist).
- Swift 6 singletons: `@MainActor` + `@unchecked Sendable`, with `SWIFT_STRICT_CONCURRENCY: minimal`.
- `deinit` is nonisolated. Properties it touches need `nonisolated(unsafe)`.
- `import IOKit` doesn't include I2C/graphics. Add `import IOKit.i2c` / `import IOKit.graphics`.
- ColorSync globals: `@preconcurrency import ColorSync` and `.takeUnretainedValue()`.
