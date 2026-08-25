import Foundation

/// Talks to the HID services macOS keeps for every attached input device.
///
/// There is no public API for any of this. The `IOHIDEventSystemClient` calls
/// are resolved at runtime rather than linked: they have no headers, a direct
/// reference would not build, and a symbol that disappears in a future macOS
/// has to degrade into "this feature is unavailable" instead of a binary that
/// refuses to launch.
///
/// One shared instance, because the client owns every service object it hands
/// out. A client created per call is released at the end of that call, leaving
/// its services pointing at freed memory — the next property read then dies
/// inside IOKit's own CFRelease.
final class HIDServiceBridge {
    static let shared = HIDServiceBridge()

    /// Usage page and usage pairs from the HID spec, for `services(matching:)`.
    enum Kind {
        case pointer, mouse, keyboard

        var pair: (UInt32, UInt32) {
            switch self {
            case .pointer:  return (0x01, 0x01)
            case .mouse:    return (0x01, 0x02)
            case .keyboard: return (0x01, 0x06)
            }
        }
    }

    private typealias CreateC   = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias ServicesC = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias GetC      = @convention(c) (AnyObject?, CFString) -> Unmanaged<CFTypeRef>?
    private typealias SetC      = @convention(c) (AnyObject?, CFString, CFTypeRef) -> Bool
    private typealias ConformsC = @convention(c) (AnyObject?, UInt32, UInt32) -> Bool

    private let listServices: ServicesC
    private let getProperty: GetC
    private let setProperty: SetC
    private let conformsTo: ConformsC
    private let client: AnyObject

    /// False when the symbols are gone or the client refused to start. Every
    /// feature built on this reports itself unsupported rather than pretending.
    let isAvailable: Bool

    private init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let c = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let s = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let g = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let w = dlsym(handle, "IOHIDServiceClientSetProperty"),
              let f = dlsym(handle, "IOHIDServiceClientConformsTo"),
              let created = unsafeBitCast(c, to: CreateC.self)(kCFAllocatorDefault)?.takeRetainedValue()
        else {
            // Stubs that answer "nothing here", so callers need no optionals.
            listServices = { _ in nil }
            getProperty = { _, _ in nil }
            setProperty = { _, _, _ in false }
            conformsTo = { _, _, _ in false }
            client = NSNull()
            isAvailable = false
            return
        }
        listServices = unsafeBitCast(s, to: ServicesC.self)
        getProperty = unsafeBitCast(g, to: GetC.self)
        setProperty = unsafeBitCast(w, to: SetC.self)
        conformsTo = unsafeBitCast(f, to: ConformsC.self)
        client = created
        isAvailable = true
    }

    // MARK: Services

    func services(matching kinds: [Kind]) -> [AnyObject] {
        guard let all = listServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        return all.filter { service in
            kinds.contains { kind in
                let (page, usage) = kind.pair
                return conformsTo(service, page, usage)
            }
        }
    }

    // MARK: Properties

    func get(_ service: AnyObject, _ key: String) -> CFTypeRef? {
        getProperty(service, key as CFString)?.takeRetainedValue()
    }

    func int(_ service: AnyObject, _ key: String) -> Int? { get(service, key) as? Int }
    func string(_ service: AnyObject, _ key: String) -> String? {
        guard let value = get(service, key) else { return nil }
        return value as? String ?? String(describing: value)
    }

    @discardableResult
    func set(_ service: AnyObject, _ key: String, _ value: CFTypeRef) -> Bool {
        setProperty(service, key as CFString, value)
    }

    func name(_ service: AnyObject) -> String {
        (get(service, "Product") as? String) ?? "Input device"
    }

    /// A name for a device that survives unplugging and a reboot.
    ///
    /// Vendor, product and serial rather than `LocationID`: the location is
    /// the USB port, so moving a device to another socket would orphan
    /// anything stored under its old identity. `RegistryID` reads as absent
    /// on this hardware, so it is not relied on.
    func identity(_ service: AnyObject) -> String {
        let vendor = string(service, "VendorID") ?? "?"
        let product = string(service, "ProductID") ?? "?"
        let unique = string(service, "SerialNumber")
            ?? string(service, "LocationID")
            ?? string(service, "Product")
            ?? "?"
        return "\(vendor):\(product):\(unique)"
    }
}
