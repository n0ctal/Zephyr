import Foundation

/// Reads temperature sensors. Discovers valid temperature keys once
/// (enumerating all SMC keys is expensive), then re-reads only that
/// cached set on each refresh.
final class SensorReader {
    private let smc: SMC
    private(set) var temperatureKeys: [String] = []

    /// Plausible on-die temperature range in °C; filters unrelated T* keys.
    private let plausibleRange = 1.0 ... 125.0

    /// Preferred CPU sensor keys, best first; first one that exists is used.
    private let cpuKeyPreference = ["TC0P", "TC0E", "TC0F", "TCXC", "TCGC", "TC0D", "TC0H"]

    /// The CPU sensor key chosen at startup (nil if none of the preferred keys exist).
    private(set) var cpuKey: String?

    init(smc: SMC) {
        self.smc = smc
        discoverTemperatureKeys()
        cpuKey = cpuKeyPreference.first { temperatureKeys.contains($0) }
    }

    private func discoverTemperatureKeys() {
        guard let keys = try? smc.allKeys() else { return }
        var discovered: [String] = []
        for key in keys where key.hasPrefix("T") {
            guard let value = try? smc.read(key), let celsius = value.double else { continue }
            if plausibleRange.contains(celsius) {
                discovered.append(key)
            }
        }
        temperatureKeys = discovered.sorted()
    }

    func readTemperatures() -> [TemperatureReading] {
        temperatureKeys.compactMap { key in
            guard let value = try? smc.read(key),
                  let celsius = value.double,
                  plausibleRange.contains(celsius) else { return nil }
            return TemperatureReading(
                key: key,
                label: SensorLabels.label(for: key),
                celsius: celsius
            )
        }
    }

    /// The single hottest reading.
    func hottest() -> TemperatureReading? {
        readTemperatures().max { $0.celsius < $1.celsius }
    }

    /// One named sensor, for the fan curve to follow.
    ///
    /// Falls back rather than fails. A sensor can stop answering — they come
    /// and go with what the machine has powered up — and the fans going back
    /// to the firmware because a chosen key vanished would be a cooling policy
    /// silently switching itself off.
    func temperature(forKey key: String) -> TemperatureReading? {
        if key == FanCurve.hottestSensorKey { return hottest() }
        guard !key.isEmpty else { return cpuTemperature() }
        if let value = try? smc.read(key),
           let celsius = value.double,
           plausibleRange.contains(celsius) {
            return TemperatureReading(key: key, label: SensorLabels.label(for: key), celsius: celsius)
        }
        return cpuTemperature()
    }

    /// The CPU temperature (reads just the one cached CPU key — cheap, for the
    /// menu-bar title). Falls back to the hottest sensor if no CPU key exists.
    func cpuTemperature() -> TemperatureReading? {
        if let key = cpuKey,
           let value = try? smc.read(key),
           let celsius = value.double,
           plausibleRange.contains(celsius) {
            return TemperatureReading(key: key, label: SensorLabels.label(for: key), celsius: celsius)
        }
        return hottest()
    }
}

/// Reads fan state and controls fan speed via the SMC.
///
/// On T2 Macs (and this MacBookPro16,1) there is no `FS!` force key.
/// Per-fan control instead uses:
///   - `F{i}Md` (ui8): 0 = automatic, 1 = manual (forced) mode
///   - `F{i}Tg` (target RPM): the requested speed
final class FanController {
    private let smc: SMC
    let fanCount: Int

    /// Pre-T2 Macs expose a global force bitmask under `FS! ` (one bit per
    /// fan). T2 and later Macs drop it and use the per-fan `F{i}Md` mode key.
    /// We pick the mechanism by probing for the key once.
    private let forceKey = "FS! "
    private let usesForceBits: Bool

    init(smc: SMC) {
        self.smc = smc
        self.fanCount = Int((try? smc.read("FNum").double) ?? 0)
        self.usesForceBits = (try? smc.read("FS! ")) != nil
    }

    // MARK: Keys

    private func key(_ fan: Int, _ suffix: String) -> String { "F\(fan)\(suffix)" }

    // MARK: Force bitmask (pre-T2)

    /// Reads the `FS! ` force bitmask (big-endian 16-bit, one bit per fan).
    private func forceBits() -> UInt16 {
        guard let value = try? smc.read(forceKey), value.bytes.count >= 2 else { return 0 }
        return (UInt16(value.bytes[0]) << 8) | UInt16(value.bytes[1])
    }

    private func writeForceBits(_ bits: UInt16) throws {
        try smc.write(forceKey, bytes: [UInt8(bits >> 8), UInt8(bits & 0xff)])
    }

    private func isFanManual(_ index: Int) -> Bool {
        if usesForceBits {
            return (forceBits() & (1 << UInt16(index))) != 0
        }
        return ((try? smc.read(key(index, "Md")))?.double ?? 0) >= 1
    }

    // MARK: Read

    func readFans() -> [FanReading] {
        (0 ..< fanCount).compactMap { readFan($0) }
    }

    func readFan(_ index: Int) -> FanReading? {
        guard let actual = rpm(index, "Ac") else { return nil }
        // A failed Mn/Mx read must not read as "this fan may run at 0 rpm": the
        // clamp in setManual would then command a stop and hold it there.
        guard let minRPM = rpm(index, "Mn"), let maxRPM = rpm(index, "Mx"), maxRPM > 0 else { return nil }
        let target = rpm(index, "Tg") ?? actual
        return FanReading(
            index: index,
            actualRPM: actual,
            minRPM: minRPM,
            maxRPM: maxRPM,
            targetRPM: target,
            isManual: isFanManual(index)
        )
    }

    private func rpm(_ fan: Int, _ suffix: String) -> Int? {
        guard let value = try? smc.read(key(fan, suffix)), let d = value.double else { return nil }
        // Int(_:) traps on NaN and out-of-range values, and this runs in the root
        // daemon's control loop — an unchecked conversion kills it mid-cycle.
        guard d.isFinite, d >= 0, d <= 65535 else { return nil }
        return Int(d.rounded())
    }

    // MARK: Control

    /// Switches a fan to manual mode and sets a target RPM (clamped to min/max).
    func setManual(fan: Int, rpm requested: Int) throws {
        guard let current = readFan(fan) else { throw SMCError.keyNotFound(key(fan, "Ac")) }
        guard current.maxRPM >= current.minRPM, current.maxRPM > 0 else {
            throw SMCError.keyNotFound(key(fan, "Mx"))
        }
        let clamped = min(max(requested, current.minRPM), current.maxRPM)

        if usesForceBits {
            try writeForceBits(forceBits() | (1 << UInt16(fan)))
        } else {
            try smc.write(key(fan, "Md"), bytes: [1])
        }
        guard let payload = encodeRPM(clamped, forKey: key(fan, "Tg")) else {
            throw SMCError.keyNotFound(key(fan, "Tg"))
        }
        try smc.write(key(fan, "Tg"), bytes: payload)
    }

    /// Returns a fan to automatic (firmware-controlled) mode.
    func setAuto(fan: Int) throws {
        if usesForceBits {
            try writeForceBits(forceBits() & ~(1 << UInt16(fan)))
        } else {
            try smc.write(key(fan, "Md"), bytes: [0])
        }
    }

    /// Returns all fans to automatic mode.
    func setAllAuto() {
        for i in 0 ..< fanCount { try? setAuto(fan: i) }
    }

    /// Encodes an RPM value into the byte layout the target key expects.
    /// Newer Macs use `flt` (native 32-bit float); older ones use `fpe2`
    /// (big-endian, value × 4).
    private func encodeRPM(_ rpm: Int, forKey keyString: String) -> [UInt8]? {
        // Never guess the key type: writing a float into an fpe2 key turns a
        // 3000 rpm target into ~32 rpm, i.e. a stopped fan.
        guard let type = (try? smc.read(keyString))?.type else { return nil }
        let typeCode = smcKeyCode(type.padding(toLength: 4, withPad: " ", startingAt: 0))
        switch typeCode {
        case SMCDataType.fpe2:
            let raw = UInt16(min(max(rpm, 0), 16383) * 4)
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        default: // flt
            return withUnsafeBytes(of: Float32(rpm)) { Array($0) }
        }
    }
}
