import Foundation
import IOKit

/// The SSD's own health page — wear, endurance, temperature, error counts.
///
/// This is what DriveDx and smartmontools read, and it needs no privileges at
/// all: the drive advertises `NVMe SMART Capable` and a `NVMeSMARTLib` plug-in
/// in the I/O registry, and an ordinary process may open it. Verified on this
/// machine before a line of it was written — the alternative would have been
/// routing it through the root helper for no reason.
///
/// Read on demand and never on a timer of its own. A health page changes over
/// weeks; polling it beside the temperatures would be a few dozen IOKit round
/// trips a minute to watch a number that moves once a month.
enum DriveHealth {

    struct Reading: Equatable {
        let model: String
        let serial: String
        let capacityBytes: UInt64
        /// 0 means nothing is wrong; each bit is a separate warning.
        let criticalWarning: UInt8
        /// Nil when the drive does not implement it. Zero kelvin is a
        /// permitted answer for "no sensor", and reporting it as −273 °C is
        /// the same mistake the battery reading had.
        let celsius: Double?
        /// Share of the drive's rated write endurance already spent. Passes
        /// 100 % on a drive that has outlived its rating and keeps counting.
        let percentageUsed: Int
        let availableSpare: Int
        let spareThreshold: Int
        let bytesWritten: UInt64
        let bytesRead: UInt64
        let powerOnHours: UInt64
        let powerCycles: UInt64
        /// Power lost without the drive being told — crashes, held power
        /// buttons, a battery that ran out mid-write.
        let unsafeShutdowns: UInt64
        /// Unrecoverable data errors. Anything but zero is a drive to replace.
        let mediaErrors: UInt64

        var isHealthy: Bool {
            // At the threshold is not past it — the specification warns when
            // spare capacity falls *below*. A drive answering 0 and 0, which
            // is what one that does not track spare blocks answers, is not
            // failing either.
            criticalWarning == 0 && mediaErrors == 0 && availableSpare >= spareThreshold
        }

        /// What the warning bits mean, in the order the specification lists
        /// them. Empty when there is nothing to say.
        var warnings: [String] {
            let meanings = [
                "spare capacity is below its threshold",
                "temperature is past a critical limit",
                "the drive's reliability is degraded",
                "the drive has gone read-only",
                "the volatile memory backup has failed",
            ]
            return meanings.enumerated().compactMap { index, text in
                criticalWarning & (1 << UInt8(index)) != 0 ? text : nil
            }
        }
    }

    // MARK: Reading

    static func read() -> Reading? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMasterPortDefault,
                                           IOServiceMatching("IONVMeBlockStorageDevice"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var device = IOIteratorNext(iterator)
        while device != 0 {
            defer {
                IOObjectRelease(device)
                device = IOIteratorNext(iterator)
            }
            if let page = smartPage(of: device) {
                return compose(page: page, device: device)
            }
        }
        return nil
    }

    /// The 512-byte SMART / Health Information log, straight from the drive.
    private static func smartPage(of device: io_service_t) -> [UInt8]? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(device, smartTypeID, plugInInterfaceID,
                                                &plugin, &score) == KERN_SUCCESS,
              let plugin = plugin else { return nil }
        defer { IODestroyPlugInInterface(plugin) }

        var interface: LPVOID?
        let queried = withUnsafeMutablePointer(to: &interface) { pointer in
            plugin.pointee!.pointee.QueryInterface(plugin,
                                                   CFUUIDGetUUIDBytes(smartInterfaceID),
                                                   pointer)
        }
        guard queried == 0, let interface = interface else { return nil }
        // QueryInterface hands back a reference of its own, and destroying the
        // plug-in only drops the plug-in's. Without this the app leaks one
        // interface per read — every five minutes, for as long as the section
        // is open.
        defer {
            let table = interface.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
            let release = table.advanced(by: 24)
                .assumingMemoryBound(to: ReleaseInterface.self).pointee
            _ = release(interface)
        }

        // A plug-in interface is a pointer to a pointer to a table of function
        // pointers, laid out as: _reserved, QueryInterface, AddRef, Release,
        // version and revision packed into one word, then SMARTReadData. Which
        // puts it at byte 40 on a 64-bit machine. There is no header for this
        // in Swift, so the offset is the contract.
        let table = interface.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
        let readData = table.advanced(by: 40)
            .assumingMemoryBound(to: SMARTReadData.self).pointee

        var page = [UInt8](repeating: 0, count: 512)
        let result = page.withUnsafeMutableBytes { readData(interface, $0.baseAddress) }
        return result == KERN_SUCCESS ? page : nil
    }

    /// Model, serial and capacity, read once.
    ///
    /// None of them can change while the process is running, and finding the
    /// capacity means a recursive walk of everything below the drive — on APFS
    /// that is the container, every volume and every mounted snapshot. Doing
    /// that again every five minutes to re-learn a number that was printed on
    /// the box is work for nothing.
    private struct Identity {
        let model: String
        let serial: String
        let capacityBytes: UInt64
    }
    private static var identity: Identity?

    private static func identity(of device: io_service_t) -> Identity {
        if let identity = identity { return identity }
        let characteristics: [String: Any]? = Registry.inherited(device, characteristicsKey)
        let fresh = Identity(model: characteristics?["Product Name"] as? String ?? "SSD",
                             serial: characteristics?["Serial Number"] as? String ?? "",
                             capacityBytes: wholeDiskCapacity(under: device))
        identity = fresh
        return fresh
    }

    private static let characteristicsKey = "Device Characteristics" as CFString
    private static let wholeKey = "Whole" as CFString
    private static let sizeKey = "Size" as CFString

    private static func compose(page: [UInt8], device: io_service_t) -> Reading {
        func value(at offset: Int, bytes: Int) -> UInt64 {
            // Little-endian, and never more than the low eight bytes: the
            // counters are 128 bits wide and the top half cannot be reached in
            // the lifetime of any drive that will ever run this.
            var result: UInt64 = 0
            for index in stride(from: min(bytes, 8) - 1, through: 0, by: -1) {
                result = result << 8 | UInt64(page[offset + index])
            }
            return result
        }
        // A "data unit" is a thousand 512-byte blocks, by the specification.
        func bytes(at offset: Int) -> UInt64 { value(at: offset, bytes: 16) &* 512_000 }
        let kelvin = value(at: 1, bytes: 2)

        let identity = identity(of: device)
        return Reading(
            model: identity.model,
            serial: identity.serial,
            capacityBytes: identity.capacityBytes,
            criticalWarning: page[0],
            celsius: kelvin > 0 ? Double(kelvin) - 273.15 : nil,
            percentageUsed: Int(page[5]),
            availableSpare: Int(page[3]),
            spareThreshold: Int(page[4]),
            bytesWritten: bytes(at: 48),
            bytesRead: bytes(at: 32),
            powerOnHours: value(at: 128, bytes: 16),
            powerCycles: value(at: 112, bytes: 16),
            unsafeShutdowns: value(at: 144, bytes: 16),
            mediaErrors: value(at: 160, bytes: 16))
    }

    /// The size of the whole-disk media belonging to *this* device.
    ///
    /// It lives below the NVMe device rather than on it, so a search upwards
    /// never finds it — and searching the whole registry for the largest whole
    /// disk, which is what this did first, printed an attached drive's size
    /// beside the internal drive's health page.
    private static func wholeDiskCapacity(under device: io_service_t) -> UInt64 {
        var capacity: UInt64 = 0
        Registry.forEachDescendant(of: device) { entry in
            guard capacity == 0,
                  IOObjectConformsTo(entry, "IOMedia") != 0,
                  let whole: Bool = Registry.property(entry, wholeKey), whole,
                  let size: NSNumber = Registry.property(entry, sizeKey) else { return }
            capacity = size.uint64Value
        }
        return capacity
    }

    // MARK: The plug-in's identifiers

    private typealias SMARTReadData =
        @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    /// The third entry of the table every plug-in interface starts with:
    /// _reserved, QueryInterface, AddRef, Release — so byte 24.
    private typealias ReleaseInterface =
        @convention(c) (UnsafeMutableRawPointer?) -> UInt32

    private static let smartTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
        0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    private static let smartInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
        0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    /// `kIOCFPlugInInterfaceID`, which is not exported to Swift.
    private static let plugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
        0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
}
