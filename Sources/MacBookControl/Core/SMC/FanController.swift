import Foundation

/// Reads temperature sensors. Enumerating every SMC key is expensive, so the
/// list of temperature keys is found once and only that list is re-read on
/// each refresh.
final class SensorReader {
    private let smc: SMC

    /// Every key that answered as a number at startup, including the ones
    /// reading zero because the part behind them was powered down. Whether a
    /// reading is believable is decided on each refresh instead of once, so a
    /// sensor that wakes up later — a discrete GPU, most often — starts being
    /// reported. Keeping only what was live at startup hid it for the whole
    /// life of the process. The cost is re-reading a handful of keys that may
    /// never answer; on the machine this was written on that is two of fifty.
    private(set) var temperatureKeys: [String] = []

    /// Plausible on-die temperature range in °C; filters unrelated T* keys.
    static let plausibleRange = 1.0 ... 125.0

    /// Preferred CPU sensor keys, best first; first one that exists is used.
    ///
    /// The one list, for everything that asks "how hot is the CPU". There used
    /// to be two — this one, and a shorter one in `Telemetry` — and they
    /// disagreed about the first key, so the narrow read fetched one sensor
    /// while the reader that consumed it preferred another. With the settings
    /// window shut the preferred key was simply never read, and the number
    /// fell through to whatever had been.
    ///
    /// TCMX first: it is the register the firmware keeps the hottest core in,
    /// and it behaves like one. Measured across twelve samples from idle
    /// through a build, it matched the hottest of the eight per-core sensors
    /// exactly ten times and read 2.3 °C above it twice — never below. It also
    /// moves at once when the load arrives (64 → 69 → 78 °C) while TC0F, which
    /// carries the heatspreader's lag, was still reading 63 → 65 → 67.
    ///
    /// Never reading low is the property that matters. Everything downstream
    /// is a decision about cooling: the fan curve's ramp, and the ceiling at
    /// which a pinned fan is handed back to the firmware.
    ///
    /// TC0P last, though it used to be first. It sits beside the package
    /// rather than on it and lags badly: measured under a sustained build it
    /// read 69.4 °C against TC0F's 87.2 at the same instant, and earlier in
    /// the same build 54 °C against a hottest core of 94.
    static let cpuKeyPreference = ["TCMX", "TC0F", "TC0E", "TCXC", "TCGC", "TC0D", "TC0H", "TC0P"]

    init(smc: SMC) {
        self.smc = smc
        discoverTemperatureKeys()
    }

    private func discoverTemperatureKeys() {
        guard let keys = try? smc.allKeys() else { return }
        var readings: [(key: String, celsius: Double)] = []
        for key in keys where key.hasPrefix("T") {
            guard let value = try? smc.read(key), let celsius = value.double else { continue }
            readings.append((key, celsius))
        }
        temperatureKeys = SensorReader.select(from: readings)
    }

    /// The startup decision apart from the machine that answers it: which keys
    /// are worth re-reading.
    ///
    /// Everything that answered as a number, believable or not. Which of them
    /// to believe is decided on each refresh instead, and which one is the
    /// CPU's is decided when it is asked — see `cpuTemperature()` for why
    /// neither is settled here.
    static func select(from readings: [(key: String, celsius: Double)]) -> [String] {
        readings.map(\.key).sorted()
    }

    func readTemperatures() -> [TemperatureReading] {
        temperatureKeys.compactMap { key in
            guard let value = try? smc.read(key),
                  let celsius = value.double,
                  Self.plausibleRange.contains(celsius) else { return nil }
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
           Self.plausibleRange.contains(celsius) {
            return TemperatureReading(key: key, label: SensorLabels.label(for: key), celsius: celsius)
        }
        return cpuTemperature()
    }

    /// The CPU temperature, by preference, reading one key in the ordinary
    /// case — the first choice answers and the walk stops there.
    ///
    /// Walked live rather than resolved once at startup. A key frozen in at
    /// launch is a key chosen from whatever happened to be awake then, and the
    /// consumer picks from the same list over the full sweep — so the two
    /// disagreed again whenever a preferred sensor was dormant at launch and
    /// woke later, which is exactly the divergence this list was unified to
    /// remove. Falls back to the hottest sensor when none of them answers.
    func cpuTemperature() -> TemperatureReading? {
        for key in Self.cpuKeyPreference where temperatureKeys.contains(key) {
            if let value = try? smc.read(key),
               let celsius = value.double,
               Self.plausibleRange.contains(celsius) {
                return TemperatureReading(key: key, label: SensorLabels.label(for: key), celsius: celsius)
            }
        }
        return hottest()
    }

    /// Which key `cpuTemperature()` will try first on a machine with these
    /// keys. Separate so the order can be checked without the machine.
    static func preferredCPUKey(among available: [String]) -> String? {
        cpuKeyPreference.first(where: available.contains)
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
    ///
    /// `known` is a reading the caller already has. The control loop takes one
    /// every half-second before working out where the fan should be, and
    /// reading the same five keys again here cost as much as the rest of the
    /// tick put together.
    func setManual(fan: Int, rpm requested: Int, known: FanReading? = nil) throws {
        guard let current = known ?? readFan(fan) else { throw SMCError.keyNotFound(key(fan, "Ac")) }
        guard current.maxRPM >= current.minRPM, current.maxRPM > 0 else {
            throw SMCError.keyNotFound(key(fan, "Mx"))
        }
        let clamped = FanController.clamp(requested, to: current)

        // Most visits from the control loop have nothing to change: the
        // temperature moved by a tenth of a degree and the target lands on the
        // same rpm. Holding a fan steady used to cost exactly as much as
        // moving it. The reading is fresh, so the firmware cannot have taken
        // the fan back without us seeing it on the next tick.
        if FanController.isAlreadySet(current, to: clamped) { return }

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

    /// The clamped target, and whether the fan is already sitting on it. Both
    /// are separate from the SMC so the loop's decision to stay silent can be
    /// checked without a fan to watch.
    static func clamp(_ requested: Int, to reading: FanReading) -> Int {
        min(max(requested, reading.minRPM), reading.maxRPM)
    }

    /// Compares against the clamped figure, not the requested one: asking for
    /// less than the fan's minimum every half-second would otherwise look like
    /// a new instruction every time.
    static func isAlreadySet(_ reading: FanReading, to clamped: Int) -> Bool {
        reading.isManual && reading.targetRPM == clamped
    }

    /// The byte layout each target key expects. It is a fact about the
    /// machine, not about the moment, but asking costs an SMC round trip and
    /// the control loop would pay it twice a second for as long as it runs.
    private var targetEncodings: [String: UInt32] = [:]

    /// Encodes an RPM value into the byte layout the target key expects.
    /// Newer Macs use `flt` (native 32-bit float); older ones use `fpe2`
    /// (big-endian, value × 4).
    private func encodeRPM(_ rpm: Int, forKey keyString: String) -> [UInt8]? {
        // Never guess the key type: writing a float into an fpe2 key turns a
        // 3000 rpm target into ~32 rpm, i.e. a stopped fan.
        let typeCode: UInt32
        if let cached = targetEncodings[keyString] {
            typeCode = cached
        } else {
            guard let type = (try? smc.read(keyString))?.type else { return nil }
            typeCode = smcKeyCode(type.padding(toLength: 4, withPad: " ", startingAt: 0))
            targetEncodings[keyString] = typeCode
        }
        switch typeCode {
        case SMCDataType.fpe2:
            let raw = UInt16(min(max(rpm, 0), 16383) * 4)
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        default: // flt
            return withUnsafeBytes(of: Float32(rpm)) { Array($0) }
        }
    }
}
