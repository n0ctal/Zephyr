import Foundation
import IOKit

/// The handful of I/O registry moves this app makes, written once.
///
/// Four files had grown their own spelling of "read a property off a registry
/// entry and cast it", each repeating the allocator, the retain rule and the
/// option bits, and two of them had grown their own copy of the accelerator
/// sweep. None of that is difficult; all of it is easy to get subtly wrong in
/// one place and not the others.
enum Registry {

    /// kIOMainPortDefault is macOS 12; the deprecated spelling is what works
    /// on the oldest system this still supports, and they are the same port.
    static let port: mach_port_t = kIOMasterPortDefault

    // MARK: Properties

    static func property<T>(_ service: io_service_t, _ key: CFString) -> T? {
        IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? T
    }

    /// The same, but looking upwards through the parents as well — for the
    /// facts that live on a controller rather than on the device.
    static func inherited<T>(_ service: io_service_t, _ key: CFString) -> T? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively
                                                     | kIORegistryIterateParents)) as? T
    }

    // MARK: Names

    /// The entry's name in the registry, which for a hardware service is the
    /// vendor's own string.
    static func name(of object: io_object_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        return IORegistryEntryGetName(object, &buffer) == KERN_SUCCESS
            ? String(cString: buffer) : ""
    }

    /// The entry's class, which for a user client is the kind of client it is.
    static func className(of object: io_object_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        return IOObjectGetClass(object, &buffer) == KERN_SUCCESS
            ? String(cString: buffer) : ""
    }

    // MARK: Walking

    /// Every service of a class, released as it goes.
    static func forEachService(matching className: String,
                               _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(port, IOServiceMatching(className),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            body(service)
        }
    }

    /// Every child of a service, one level down.
    static func forEachChild(of service: io_service_t, _ body: (io_registry_entry_t) -> Void) {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane,
                                              &children) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(children) }

        var child = IOIteratorNext(children)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(children)
            }
            body(child)
        }
    }

    /// Every descendant of a service, however deep.
    static func forEachDescendant(of service: io_service_t,
                                  _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            body(entry)
        }
    }
}
