import Foundation
import IOKit

/// Which processes have a graphics accelerator open.
///
/// The reading gfxCardStatus is known for, and the one thing Zephyr's own
/// Graphics section could not answer: it can say the discrete card is being
/// asked for, but not by whom. Every client of an accelerator records the
/// process that opened it, so the answer was there all along.
enum AcceleratorClients {

    struct Holder: Identifiable, Hashable {
        let pid: Int
        let name: String
        var id: Int { pid }
    }

    /// The processes actually running work on the discrete card, one entry
    /// each.
    ///
    /// Not everyone with a client open: on this machine thirty-eight
    /// processes hold an `AccelDevice` on the discrete card — anything that
    /// ever asked the system what GPUs exist — while four hold a command
    /// queue. A command queue is what you create to submit work, so those four
    /// are the answer to "what is keeping the card awake" and the other
    /// thirty-four are noise that would make the reading useless.
    static func discreteHolders() -> [Holder] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMasterPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [Int: String] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let accelerator = className(of: service, useRegistryName: true)
            if accelerator.contains("AMD") || accelerator.contains("NVDA")
                || accelerator.contains("GeForce") {
                collectClients(of: service, into: &found)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return found.map { Holder(pid: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func collectClients(of service: io_service_t, into found: inout [Int: String]) {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(children) }

        var child = IOIteratorNext(children)
        while child != 0 {
            if isWorkClient(className(of: child)),
               let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString,
                                                             kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
               let holder = parse(creator) {
                found[holder.pid] = holder.name
            }
            IOObjectRelease(child)
            child = IOIteratorNext(children)
        }
    }

    /// The registry writes this as `pid 159, WindowServer`.
    private static func parse(_ creator: String) -> Holder? {
        let parts = creator.split(separator: ",", maxSplits: 1)
        guard parts.count == 2,
              let pid = Int(parts[0].replacingOccurrences(of: "pid ", with: "")
                                    .trimmingCharacters(in: .whitespaces))
        else { return nil }
        return Holder(pid: pid, name: parts[1].trimmingCharacters(in: .whitespaces))
    }

    /// Whether this kind of client means work, rather than acquaintance.
    static func isWorkClient(_ className: String) -> Bool {
        className.contains("CommandQueue") || className.contains("Context")
    }

    /// The object's class, or its name in the registry — which for an
    /// accelerator is the vendor's own string and for a client is the kind of
    /// client it is.
    private static func className(of object: io_object_t,
                                  useRegistryName: Bool = false) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        let result = useRegistryName
            ? IORegistryEntryGetName(object, &buffer)
            : IOObjectGetClass(object, &buffer)
        return result == KERN_SUCCESS ? String(cString: buffer) : ""
    }
}
