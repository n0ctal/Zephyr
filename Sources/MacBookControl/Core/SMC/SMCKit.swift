import Foundation
import IOKit

// MARK: - FourCharCode helpers

/// Converts a 4-character ASCII key (e.g. "TC0P") into the UInt32
/// the SMC expects (MSB = first character). Keys are always 4 characters.
@inline(__always)
func smcKeyCode(_ string: String) -> UInt32 {
    precondition(string.utf8.count == 4, "SMC key must be 4 characters: \(string)")
    var code: UInt32 = 0
    for byte in string.utf8 {
        code = (code << 8) | UInt32(byte)
    }
    return code
}

/// Converts a UInt32 FourCharCode back into its 4-character string form.
@inline(__always)
func smcKeyString(_ code: UInt32) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "?"
}

// MARK: - SMC data type codes (FourCharCode)

enum SMCDataType {
    static let flt = smcKeyCode("flt ")   // 32-bit float
    static let fpe2 = smcKeyCode("fpe2")  // unsigned fixed: 14 int + 2 frac
    static let fp2e = smcKeyCode("fp2e")  // unsigned fixed: 2 int + 14 frac
    static let fp1f = smcKeyCode("fp1f")  // unsigned fixed: 1 int + 15 frac
    static let sp78 = smcKeyCode("sp78")  // signed fixed: 1 sign + 7 int + 8 frac
    static let sp87 = smcKeyCode("sp87")
    static let sp5a = smcKeyCode("sp5a")
    static let sp69 = smcKeyCode("sp69")
    static let ui8 = smcKeyCode("ui8 ")
    static let ui16 = smcKeyCode("ui16")
    static let ui32 = smcKeyCode("ui32")
}

// MARK: - Wire format
//
// AppleSMC's user client (kernel method index 2) takes and returns an
// 80-byte SMCKeyData_t. Rather than rely on Swift's struct layout (which
// does not match C's tail-padding rules), we pack/unpack the buffer by
// explicit byte offsets. All multi-byte integer fields are native-endian.

private enum Wire {
    static let size = 80
    static let keyOffset = 0          // UInt32  FourCharCode
    static let dataSizeOffset = 28    // UInt32
    static let dataTypeOffset = 32    // UInt32  FourCharCode
    static let resultOffset = 40      // UInt8
    static let data8Offset = 42       // UInt8   selector
    static let data32Offset = 44      // UInt32  (index for getKeyFromIndex)
    static let bytesOffset = 48       // UInt8[32] payload
    static let bytesCount = 32
}

/// SMC function selectors carried in `data8`.
private enum SMCSelector: UInt8 {
    case readKey = 5
    case writeKey = 6
    case getKeyFromIndex = 8
    case getKeyInfo = 9
}

/// The IOConnectCallStructMethod index for AppleSMC.
private let kSMCKernelIndex: UInt32 = 2

// MARK: - Buffer accessors (native little-endian)

@inline(__always)
private func putU32(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
    buffer[offset] = UInt8(value & 0xff)
    buffer[offset + 1] = UInt8((value >> 8) & 0xff)
    buffer[offset + 2] = UInt8((value >> 16) & 0xff)
    buffer[offset + 3] = UInt8((value >> 24) & 0xff)
}

@inline(__always)
private func getU32(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(buffer[offset])
        | (UInt32(buffer[offset + 1]) << 8)
        | (UInt32(buffer[offset + 2]) << 16)
        | (UInt32(buffer[offset + 3]) << 24)
}

// MARK: - Decoded value

struct SMCValue {
    let key: String
    let type: String
    let size: UInt32
    let bytes: [UInt8]

    /// Interprets the raw bytes according to the SMC data type.
    /// Returns nil if the type is not numeric / not understood.
    /// Fixed-point SMC types are big-endian; `flt` is a native float.
    var double: Double? {
        let typeCode = smcKeyCode(type.padding(toLength: 4, withPad: " ", startingAt: 0))
        switch typeCode {
        case SMCDataType.flt where bytes.count >= 4:
            return Double(bytes.withUnsafeBytes { $0.load(as: Float32.self) })
        case SMCDataType.fpe2 where bytes.count >= 2:
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4.0
        case SMCDataType.fp2e where bytes.count >= 2:
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 16384.0
        case SMCDataType.fp1f where bytes.count >= 2:
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 32768.0
        case SMCDataType.sp78 where bytes.count >= 2:
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case SMCDataType.sp87 where bytes.count >= 2:
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 128.0
        case SMCDataType.sp5a where bytes.count >= 2:
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 1024.0
        case SMCDataType.sp69 where bytes.count >= 2:
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 512.0
        case SMCDataType.ui8:
            return Double(bytes.first ?? 0)
        case SMCDataType.ui16 where bytes.count >= 2:
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case SMCDataType.ui32 where bytes.count >= 4:
            let raw = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            return Double(raw)
        default:
            return nil
        }
    }
}

// MARK: - SMC errors

enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case notOpen
    case callFailed(kern_return_t)
    case smcError(UInt8)
    case keyNotFound(String)

    var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let r): return "IOServiceOpen failed: \(ioReturnString(r))"
        case .notOpen: return "SMC connection not open"
        case .callFailed(let r): return "IOConnectCallStructMethod failed: \(ioReturnString(r))"
        case .smcError(let s): return "SMC returned result 0x\(String(s, radix: 16))"
        case .keyNotFound(let k): return "SMC key not found: \(k)"
        }
    }
}

private func ioReturnString(_ code: kern_return_t) -> String {
    "0x" + String(format: "%08x", UInt32(bitPattern: code))
}

// MARK: - SMC service

/// Thin, user-space wrapper around the AppleSMC IOKit user client.
/// Reading sensors and reading/writing fan keys all work without root.
final class SMC {
    private var connection: io_connect_t = 0
    private var isOpen = false

    init() throws {
        // MACH_PORT_NULL (0) selects the default IOKit port on every macOS
        // version. (`kIOMainPortDefault` only exists in the 12+ SDK and
        // `kIOMasterPortDefault` is deprecated — 0 avoids both.)
        let defaultPort: mach_port_t = 0
        let service = IOServiceGetMatchingService(
            defaultPort,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { throw SMCError.openFailed(result) }
        isOpen = true
    }

    deinit { close() }

    func close() {
        if isOpen {
            IOServiceClose(connection)
            isOpen = false
        }
    }

    // MARK: Low-level call

    private func call(_ input: [UInt8]) throws -> [UInt8] {
        guard isOpen else { throw SMCError.notOpen }
        let inputBuffer = input
        var outputBuffer = [UInt8](repeating: 0, count: Wire.size)
        var outputSize = Wire.size

        let result = inputBuffer.withUnsafeBytes { inPtr in
            outputBuffer.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(
                    connection,
                    kSMCKernelIndex,
                    inPtr.baseAddress,
                    Wire.size,
                    outPtr.baseAddress,
                    &outputSize
                )
            }
        }
        guard result == kIOReturnSuccess else { throw SMCError.callFailed(result) }
        guard outputBuffer[Wire.resultOffset] == 0 else {
            throw SMCError.smcError(outputBuffer[Wire.resultOffset])
        }
        return outputBuffer
    }

    private func newBuffer() -> [UInt8] { [UInt8](repeating: 0, count: Wire.size) }

    // MARK: Key info / enumeration

    /// How big a key's payload is and what type it holds, remembered per key.
    ///
    /// The SMC builds its key table when the machine boots and neither figure
    /// changes while it is up, but asking costs a full IOKit round trip — and
    /// it was asked before every single read and every single write, which
    /// made all of them cost twice what they had to. Only answers are kept: a
    /// key that is not there throws, and throws just as cheaply next time.
    private var keyInfoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]

    /// Returns (dataSize, dataType) for a key.
    private func keyInfo(_ key: UInt32) throws -> (size: UInt32, type: UInt32) {
        if let cached = keyInfoCache[key] { return cached }
        var buffer = newBuffer()
        putU32(&buffer, Wire.keyOffset, key)
        buffer[Wire.data8Offset] = SMCSelector.getKeyInfo.rawValue
        let out = try call(buffer)
        let info = (size: getU32(out, Wire.dataSizeOffset), type: getU32(out, Wire.dataTypeOffset))
        keyInfoCache[key] = info
        return info
    }

    /// Total number of keys exposed by the SMC (#KEY).
    func keyCount() throws -> Int {
        Int(try read("#KEY").double ?? 0)
    }

    /// The 4-char key name at a given enumeration index.
    func key(at index: Int) throws -> String {
        var buffer = newBuffer()
        buffer[Wire.data8Offset] = SMCSelector.getKeyFromIndex.rawValue
        putU32(&buffer, Wire.data32Offset, UInt32(index))
        let out = try call(buffer)
        return smcKeyString(getU32(out, Wire.keyOffset))
    }

    /// Enumerates every SMC key name on the machine.
    func allKeys() throws -> [String] {
        let count = try keyCount()
        var keys: [String] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            if let k = try? key(at: i) { keys.append(k) }
        }
        return keys
    }

    // MARK: Read

    func read(_ keyString: String) throws -> SMCValue {
        let key = smcKeyCode(keyString)
        let info = try keyInfo(key)

        var buffer = newBuffer()
        putU32(&buffer, Wire.keyOffset, key)
        putU32(&buffer, Wire.dataSizeOffset, info.size)
        buffer[Wire.data8Offset] = SMCSelector.readKey.rawValue

        let out = try call(buffer)
        let count = Int(min(info.size, UInt32(Wire.bytesCount)))
        let payload = Array(out[Wire.bytesOffset ..< Wire.bytesOffset + count])
        return SMCValue(
            key: keyString,
            type: smcKeyString(info.type),
            size: info.size,
            bytes: payload
        )
    }

    // MARK: Write

    func write(_ keyString: String, bytes payload: [UInt8]) throws {
        let key = smcKeyCode(keyString)
        let info = try keyInfo(key)

        var buffer = newBuffer()
        putU32(&buffer, Wire.keyOffset, key)
        putU32(&buffer, Wire.dataSizeOffset, info.size)
        buffer[Wire.data8Offset] = SMCSelector.writeKey.rawValue
        for i in 0 ..< min(payload.count, Wire.bytesCount) {
            buffer[Wire.bytesOffset + i] = payload[i]
        }
        _ = try call(buffer)
    }
}
