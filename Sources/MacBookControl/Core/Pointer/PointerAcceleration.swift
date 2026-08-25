import Foundation

/// Turns off the pointer acceleration curve, per device.
///
/// macOS scales pointer movement non-linearly: move the mouse twice as fast
/// and the cursor travels more than twice as far. It suits a trackpad and
/// fights anyone who wants the cursor to track the hand — which is why every
/// mouse utility on this platform ends up implementing this.
///
/// There is no public API. The private `IOHIDEventSystemClient` calls are
/// resolved at runtime rather than linked: they have no headers, a direct
/// reference would not build, and a missing symbol has to degrade into "this
/// does nothing" instead of failing to launch.
///
/// Each device names its own acceleration key in `HIDPointerAccelerationType`
/// — a trackpad answers `HIDTrackpadAcceleration`, a mouse
/// `HIDMouseAcceleration`. Guessing the key writes to the wrong one and
/// silently does nothing, so it is always read first.
final class PointerAcceleration {
    private typealias CreateC   = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias ServicesC = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias GetC      = @convention(c) (AnyObject?, CFString) -> Unmanaged<CFTypeRef>?
    private typealias SetC      = @convention(c) (AnyObject?, CFString, CFTypeRef) -> Bool
    private typealias ConformsC = @convention(c) (AnyObject?, UInt32, UInt32) -> Bool

    private let create: CreateC
    private let services: ServicesC
    private let get: GetC
    private let set: SetC
    private let conforms: ConformsC

    /// The client owns the service objects it hands out. Creating one per call
    /// and letting it go at the end of the function leaves those services
    /// pointing at a released client, and the next property read dies inside
    /// IOKit's own CFRelease. It has to outlive everything derived from it.
    private let client: AnyObject

    /// The value each device had before we touched it, keyed by its registry
    /// id. Without this "off" would mean "whatever we last wrote", and the
    /// original curve would be gone for the rest of the session.
    ///
    /// Persisted, not merely held in memory: a crash or a `kill` runs no
    /// cleanup, and the device keeps whatever was last written to it. Storing
    /// the originals means the next launch can put them back, so the worst
    /// case is an odd-feeling pointer until Zephyr starts again — not one that
    /// stays that way with nothing left that knows the old value.
    private var originals: [String: Int] {
        get { Preferences.pointerOriginals }
        set { Preferences.pointerOriginals = newValue }
    }

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let c = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let s = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let g = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let w = dlsym(handle, "IOHIDServiceClientSetProperty"),
              let f = dlsym(handle, "IOHIDServiceClientConformsTo")
        else { return nil }
        create = unsafeBitCast(c, to: CreateC.self)
        services = unsafeBitCast(s, to: ServicesC.self)
        get = unsafeBitCast(g, to: GetC.self)
        set = unsafeBitCast(w, to: SetC.self)
        conforms = unsafeBitCast(f, to: ConformsC.self)
        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        self.client = client
    }

    struct Device {
        let name: String
        let key: String
        let value: Int
        /// 1.0 is the shipped curve for that device; 0 is no acceleration.
        var multiplier: Double { Double(value) / 65536.0 }
    }

    /// Every attached pointing device that exposes an acceleration curve.
    func devices() -> [Device] {
        pointerServices().compactMap { service in
            guard let key = get(service, "HIDPointerAccelerationType" as CFString)?
                    .takeRetainedValue() as? String,
                  let value = get(service, key as CFString)?.takeRetainedValue() as? Int
            else { return nil }
            let name = get(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "Pointing device"
            return Device(name: name, key: key, value: value)
        }
    }

    /// Applies `multiplier` to every pointing device, remembering what each
    /// one had first. Re-applying is cheap and expected: a mouse plugged in
    /// later arrives with the system curve and has to be caught.
    func apply(multiplier: Double) {
        for service in pointerServices() {
            guard let key = get(service, "HIDPointerAccelerationType" as CFString)?
                    .takeRetainedValue() as? String else { continue }
            let id = identity(service)
            if originals[id] == nil,
               let current = get(service, key as CFString)?.takeRetainedValue() as? Int {
                originals[id] = current
            }
            let raw = Int((multiplier * 65536.0).rounded())
            _ = set(service, key as CFString, raw as CFNumber)
        }
    }

    /// True when a previous run left devices altered and never put them back.
    var hasUnrestored: Bool { !originals.isEmpty }

    /// Puts every device back the way it was found.
    func restore() {
        for service in pointerServices() {
            guard let key = get(service, "HIDPointerAccelerationType" as CFString)?
                    .takeRetainedValue() as? String,
                  let original = originals[identity(service)] else { continue }
            _ = set(service, key as CFString, original as CFNumber)
        }
        originals.removeAll()
    }

    /// Diagnostics only — see the `--test-pointer` flag.
    func probe(_ key: String) -> String? {
        guard let service = pointerServices().first,
              let value = get(service, key as CFString)?.takeRetainedValue() else { return nil }
        return String(describing: value)
    }

    // MARK: Plumbing

    private func pointerServices() -> [AnyObject] {
        guard let list = services(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        // GenericDesktop/Mouse and GenericDesktop/Pointer. Keyboards and the
        // rest of the HID zoo appear in the same list.
        return list.filter { conforms($0, 0x01, 0x02) || conforms($0, 0x01, 0x01) }
    }

    /// A name for a device that survives unplugging and a reboot.
    ///
    /// Vendor, product and serial rather than `LocationID`: the location is
    /// the USB port, so moving a mouse to the other side of the machine would
    /// orphan its stored original and leave it on a curve nothing can undo.
    /// The product name alone collides between two identical mice.
    /// `RegistryID` reads as absent here, so it is not relied on.
    private func identity(_ service: AnyObject) -> String {
        func string(_ key: String) -> String? {
            guard let value = get(service, key as CFString)?.takeRetainedValue() else { return nil }
            return String(describing: value)
        }
        let vendor = string("VendorID") ?? "?"
        let product = string("ProductID") ?? "?"
        let unique = string("SerialNumber") ?? string("LocationID") ?? string("Product") ?? "?"
        return "\(vendor):\(product):\(unique)"
    }
}
