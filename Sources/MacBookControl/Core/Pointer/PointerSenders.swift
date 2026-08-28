import CoreGraphics
import Foundation
import IOKit

/// Turns the sender written on a scroll event into the device it came from.
///
/// A `CGEvent` was long assumed to say nothing about which pointing device
/// produced it, which is why scroll direction and button bindings were shared
/// by every mouse while acceleration — written to each device — was not. The
/// assumption was wrong. Field 87 carries the registry entry ID of the HID
/// event service that sent the event: constant for a device across every
/// event it sends, different between devices, and the entry it names holds
/// the vendor, product and serial the settings are already filed under.
///
/// Measured before any of this was written: 192 wheel events carried one
/// value, 308 trackpad events another, and the entries they named composed
/// exactly the identities `HIDServiceBridge` produces for the same hardware.
enum PointerSenders {
    /// The CGEvent field carrying it. Undocumented, hence the number rather
    /// than a name — and hence the fallback everywhere it is used.
    static let field = CGEventField(rawValue: 87)!

    private static var cache: [UInt64: String] = [:]
    private static var pending: Set<UInt64> = []
    private static let lock = NSLock()

    /// The identity for a sender, if it has already been looked up.
    ///
    /// Never blocks and never searches: this is called from an event tap, and
    /// a tap that takes too long is switched off by the system. A miss starts
    /// the search on another thread and answers nil, so the device follows the
    /// shared settings for the first few events of its life and its own
    /// thereafter.
    static func identity(forSender sender: UInt64) -> String? {
        lock.lock()
        let known = cache[sender]
        let alreadyLooking = pending.contains(sender)
        if known == nil && !alreadyLooking { pending.insert(sender) }
        lock.unlock()

        if known == nil && !alreadyLooking {
            DispatchQueue.global(qos: .utility).async { resolve(sender) }
        }
        return known
    }

    /// Walks the registry for the entry with this ID. Expensive, which is why
    /// it happens once per device rather than once per scroll.
    private static func resolve(_ sender: UInt64) {
        var found: String?
        var iterator: io_iterator_t = 0
        if IORegistryCreateIterator(kIOMasterPortDefault, kIOServicePlane,
                                    IOOptionBits(kIORegistryIterateRecursively),
                                    &iterator) == KERN_SUCCESS {
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                var id: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS, id == sender {
                    found = compose(entry)
                    IOObjectRelease(entry)
                    break
                }
                IOObjectRelease(entry)
            }
            IOObjectRelease(iterator)
        }
        lock.lock()
        // A device with no vendor or product is remembered as unidentifiable
        // rather than retried on every event for the rest of the session.
        cache[sender] = found ?? ""
        pending.remove(sender)
        lock.unlock()
    }

    /// The same three parts, in the same order, as `HIDServiceBridge.identity`
    /// — the settings are filed under that string, so anything else here would
    /// silently give a known device a second set of preferences.
    private static func compose(_ entry: io_registry_entry_t) -> String? {
        func value(_ key: String) -> String? {
            guard let raw = IORegistryEntryCreateCFProperty(
                entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            else { return nil }
            if let text = raw as? String { return text }
            if let number = raw as? NSNumber { return number.stringValue }
            return nil
        }
        guard let vendor = value("VendorID"), let product = value("ProductID") else { return nil }
        let unique = value("SerialNumber") ?? value("LocationID") ?? value("Product") ?? "?"
        return "\(vendor):\(product):\(unique)"
    }

    /// Devices come and go, and a registry entry ID is reused. Called when the
    /// attached devices change rather than on a timer.
    static func forget() {
        lock.lock()
        cache.removeAll()
        pending.removeAll()
        lock.unlock()
    }
}
