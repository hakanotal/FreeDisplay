import Foundation
import CoreGraphics
import IOKit

/// Shared utilities for wrapping blocking CoreGraphics calls.
enum CGHelpers {

    /// Runs a blocking operation on a background thread with a timeout.
    ///
    /// The operation is dispatched to a `.userInitiated` global queue. If it
    /// completes within `seconds`, its return value is forwarded. If the
    /// deadline fires first, `fallback` is returned instead.
    ///
    /// This is useful for any CoreGraphics / WindowServer IPC call that can
    /// hang indefinitely (e.g. `CGCompleteDisplayConfiguration`,
    /// `CGVirtualDisplay.apply(_:)`).
    ///
    /// - Parameters:
    ///   - seconds:   Maximum time to wait before returning `fallback`.
    ///   - fallback:  Value returned on timeout.
    ///   - operation: The blocking work to execute off-thread.
    /// - Returns: The operation's result, or `fallback` on timeout.
    static func runWithTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)

            DispatchQueue.global(qos: .userInitiated).async {
                once.resume(returning: operation())
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.resume(returning: fallback) {
#if DEBUG
                    print("[CGHelpers] runWithTimeout: timed out after \(seconds)s — returning fallback")
#endif
                }
            }
        }
    }

    /// The IOFramebuffer service of a display (not retained), or nil when unavailable.
    ///
    /// `CGDisplayIOServicePort` is deprecated since macOS 10.9 and imported into Swift as
    /// unavailable. It is resolved at runtime rather than bound at link time, so the app keeps
    /// launching if Apple ever removes the symbol. Only Intel Macs return a port; on Apple
    /// Silicon it yields 0.
    static func framebufferPort(for displayID: CGDirectDisplayID) -> io_service_t? {
        guard let function = cgDisplayIOServicePort else { return nil }
        let port = function(displayID)
        return port == MACH_PORT_NULL ? nil : port
    }
}

private let cgDisplayIOServicePort: (@convention(c) (CGDirectDisplayID) -> io_service_t)? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
          let symbol = dlsym(handle, "CGDisplayIOServicePort") else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (CGDirectDisplayID) -> io_service_t).self)
}()

/// Resumes a continuation at most once (the operation and the timeout race for it).
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// Returns true if this call resumed the continuation.
    @discardableResult
    func resume(returning value: T) -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
        return pending != nil
    }
}
