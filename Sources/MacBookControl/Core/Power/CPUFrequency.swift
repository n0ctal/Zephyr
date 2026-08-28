import Foundation

/// What the CPU is actually running at.
///
/// macOS on Intel publishes no current clock: `hw.cpufrequency` reports the
/// base and never moves, and the P-state ladder in the IO registry lists every
/// rung without saying which one is in use. Until this existed the readout
/// showed the base multiplied by the firmware's speed limit — the ceiling
/// being allowed rather than the speed being reached, which is a different
/// number and, whenever the machine is idle, a much larger one.
///
/// The counters come from the power kext. Without it the estimate is still
/// what gets shown; the alternative would be a blank where a number used to be.
enum CPUFrequency {
    /// APERF advances with the clock the core is actually running at, MPERF at
    /// the fixed base rate. Summed across cores by the kext, because a single
    /// core's pair is whatever that core happened to be doing.
    struct Counters: Equatable {
        var aperf: UInt64
        var mperf: UInt64
    }

    static func counters() -> Counters? {
        var value = Counters(aperf: 0, mperf: 0)
        var size = MemoryLayout<Counters>.size
        guard sysctlbyname("kern.zephyr_perf_counters", &value, &size, nil, 0) == 0,
              size == MemoryLayout<Counters>.size else { return nil }
        return value
    }

    static var isAvailable: Bool { counters() != nil }

    /// The average clock between two samples, in hertz.
    ///
    /// Both counters run monotonically until they wrap or a core sleeps deeply
    /// enough to reset them, so a sample that went backwards is thrown away
    /// rather than turned into a nonsense frequency.
    static func hertz(from previous: Counters, to current: Counters,
                      base: UInt64) -> Double? {
        guard current.aperf >= previous.aperf, current.mperf > previous.mperf,
              base > 0 else { return nil }
        let active = Double(current.aperf - previous.aperf)
        let reference = Double(current.mperf - previous.mperf)
        let hertz = active / reference * Double(base)
        // A ratio far outside what any Intel part can turbo to means the
        // counters were reset between samples, not that the CPU reached it.
        guard hertz > 0, hertz < Double(base) * 3 else { return nil }
        return hertz
    }
}
