import Foundation
import IOKit

/// Says when the battery has something new to report, so the tick does not
/// have to keep asking.
///
/// The charge moves every few minutes and the menu bar was asking 3600 times
/// an hour to find that out. IOKit will call instead: the battery node raises
/// general interest whenever its properties change, which covers the charge,
/// the charger being plugged in and out, and the low-power switch.
///
/// This does not replace the poll, it paces it. A notification that never
/// arrives — and which properties raise one is not written down anywhere —
/// would otherwise leave a wrong number on screen for the rest of the session,
/// because an event-driven reading has no way to notice it missed an edge. A
/// poll does: it is wrong until the next tick and then right again. So the
/// tick still reads on its own every `Telemetry.batteryFallbackSeconds`, and
/// what the notification buys is the fourteen readings in between.
final class BatteryWatcher {
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0

    /// Starts true so the first tick reads rather than waiting for a change
    /// that may be minutes away.
    fileprivate var changed = true

    /// False when the node could not be found or the notification could not be
    /// registered. The caller then falls back to reading every tick, which is
    /// what it did before this existed.
    private(set) var isWatching = false

    init() {
        guard let port = IONotificationPortCreate(0) else { return }
        self.port = port
        // Delivered on the main queue, which is where the tick reads the flag.
        // One thread touches it, so there is nothing to synchronise.
        IONotificationPortSetDispatchQueue(port, .main)

        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        let me = Unmanaged.passUnretained(self).toOpaque()
        let added = IOServiceAddInterestNotification(port, service, kIOGeneralInterest,
                                                     { refcon, _, _, _ in
            guard let refcon = refcon else { return }
            Unmanaged<BatteryWatcher>.fromOpaque(refcon).takeUnretainedValue().changed = true
        }, me, &notification)
        isWatching = added == KERN_SUCCESS && notification != 0
    }

    deinit {
        if notification != 0 { IOObjectRelease(notification) }
        if let port = port { IONotificationPortDestroy(port) }
    }

    /// Whether something has changed since this was last asked. Asking clears
    /// it, so two readers would each see the change once and neither reliably
    /// — there is one, and it is the tick.
    func takeChange() -> Bool {
        defer { changed = false }
        return changed
    }
}
