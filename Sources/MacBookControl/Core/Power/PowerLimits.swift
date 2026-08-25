import Foundation

/// Reads and sets the Intel package power limit.
///
/// PL1 is the sustained ceiling the CPU may draw, PL2 the short burst above
/// it. Lowering PL1 is the honest substitute for undervolting on a Mac built
/// after 2018: the undervolt register is locked by the firmware's Plundervolt
/// mitigation (CVE-2019-11157) and nothing in software gets past it, whereas
/// the power limit is a documented mechanism Intel intends to be used.
///
/// The register itself is ring 0, so the numbers come through sysctls that a
/// small kext publishes. When that kext is not loaded the sysctls are simply
/// absent, and the feature says so rather than pretending.
///
/// Field layout of MSR_PKG_POWER_LIMIT (0x610), from Intel SDM vol. 4:
///   bits  14:0  PL1 limit, in power units
///   bit     15  PL1 enable
///   bits 23:17  PL1 time window
///   bits 46:32  PL2 limit
///   bit     47  PL2 enable
///   bit     63  lock — once set, the firmware owns it until a power cycle
enum PowerLimits {
    struct Reading {
        let pl1Watts: Double
        let pl2Watts: Double
        let pl1Enabled: Bool
        let pl2Enabled: Bool
        let isLocked: Bool
        /// The package's rated TDP and the range the hardware will accept.
        let tdpWatts: Double?
        let minWatts: Double?
        let maxWatts: Double?
        let raw: UInt64
    }

    /// Whether the kext that publishes these is loaded.
    static var isAvailable: Bool { read(name: "kern.zephyr_power_limit") != nil }

    static func current() -> Reading? {
        guard let limit = read(name: "kern.zephyr_power_limit"),
              let unit = read(name: "kern.zephyr_power_unit") else { return nil }

        // Power unit is 1 / 2^(bits 3:0) watts — 1/8 W on most parts.
        let wattsPerStep = 1.0 / Double(1 << (unit & 0xF))
        let info = read(name: "kern.zephyr_power_info")

        return Reading(
            pl1Watts: Double(limit & 0x7FFF) * wattsPerStep,
            pl2Watts: Double((limit >> 32) & 0x7FFF) * wattsPerStep,
            pl1Enabled: limit & (1 << 15) != 0,
            pl2Enabled: limit & (1 << 47) != 0,
            isLocked: limit & (1 << 63) != 0,
            tdpWatts: info.map { Double($0 & 0x7FFF) * wattsPerStep },
            minWatts: info.map { Double(($0 >> 16) & 0x7FFF) * wattsPerStep },
            maxWatts: info.map { Double(($0 >> 32) & 0x7FFF) * wattsPerStep },
            raw: limit
        )
    }

    /// Sets PL1 and PL2, leaving every other field of the register as found.
    ///
    /// Read-modify-write rather than composing a fresh value: the time windows
    /// and clamp bits are the firmware's, and rewriting them from a guess is
    /// how a machine ends up with a power limit that behaves nothing like the
    /// watts printed next to the slider.
    /// Composes the new register value. The write itself goes through the
    /// privileged helper: the sysctl is deliberately root-only, so that the
    /// CPU's power ceiling is not a lever any process on the machine can pull.
    static func composed(pl1Watts: Double, pl2Watts: Double) -> UInt64? {
        guard let limit = read(name: "kern.zephyr_power_limit"),
              let unit = read(name: "kern.zephyr_power_unit"),
              limit & (1 << 63) == 0 else { return nil }

        let stepsPerWatt = Double(1 << (unit & 0xF))
        let pl1 = UInt64(max(1, (pl1Watts * stepsPerWatt).rounded())) & 0x7FFF
        let pl2 = UInt64(max(1, (pl2Watts * stepsPerWatt).rounded())) & 0x7FFF

        var value = limit
        value = (value & ~0x7FFF) | pl1
        value = (value & ~(0x7FFF << 32)) | (pl2 << 32)
        value |= (1 << 15) | (1 << 47)   // both limits enabled
        return value
    }

    // MARK: sysctl plumbing

    private static func read(name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

}
