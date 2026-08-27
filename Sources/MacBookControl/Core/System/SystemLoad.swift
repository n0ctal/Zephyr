import Darwin
import Foundation
import IOKit

/// Processor load per logical core, and memory pressure.
///
/// Load is a *rate*, and the kernel only publishes cumulative tick counters —
/// so a single reading says nothing. The difference between two readings is
/// the answer, which is why this holds the previous sample rather than being
/// a free function.
final class SystemLoad {
    struct Disk {
        let usedBytes: UInt64
        let totalBytes: UInt64
        var fraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    }

    struct Snapshot {
        /// One entry per logical core, 0...1. Sixteen of them on this machine.
        let perCore: [Double]
        let total: Double
        /// Bytes.
        let memoryUsed: UInt64
        let memoryTotal: UInt64
        /// Integrated GPU busy fraction, 0...1. The discrete card reports
        /// nothing while it is asleep, which is the usual state and not a
        /// failure — so this follows whichever accelerator is answering.
        let gpuFraction: Double?
        let disk: Disk?
        var memoryFraction: Double {
            memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0
        }
    }

    private var previousTicks: [[UInt32]] = []
    /// When those ticks were taken. Load is a rate, and a rate needs to know
    /// how long ago the other end of it was — with the window shut this is not
    /// read at all, so the first snapshot after it opens would otherwise be
    /// the average busy fraction over the whole closed afternoon, presented as
    /// what the machine is doing right now.
    private var previousAt: Date?

    /// Nominal frequency. macOS on Intel does not publish the instantaneous
    /// clock — `hw.cpufrequency` reports the base and never moves — so the
    /// only honest frequency Zephyr can show is this multiplied by the
    /// firmware's current speed limit: the ceiling being allowed, not the
    /// clock being run.
    static let nominalHz: UInt64 = {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.cpufrequency", &value, &size, nil, 0) == 0 else { return 0 }
        return value
    }()

    static let memoryTotal: UInt64 = {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0 else { return 0 }
        return value
    }()

    /// `includeGPU` is off by default because finding the accelerator's busy
    /// fraction means walking the I/O registry, which is the most expensive
    /// thing in here — and nothing shows it unless the window is open.
    func read(includeGPU: Bool = false) -> Snapshot? {
        guard let ticks = coreTicks() else { return nil }
        let elapsed = previousAt.map { Date().timeIntervalSince($0) }
        defer {
            previousTicks = ticks
            previousAt = Date()
        }

        // First call has nothing to subtract from. Reporting zero would be a
        // lie that looks like an idle machine; nil says "not yet".
        guard previousTicks.count == ticks.count else { return nil }
        // Nor does a gap: this becomes the first call again, and the next tick
        // two seconds later is a real reading.
        guard let elapsed = elapsed, elapsed < 20 else { return nil }

        var perCore: [Double] = []
        perCore.reserveCapacity(ticks.count)
        for (index, current) in ticks.enumerated() {
            let previous = previousTicks[index]
            let busy = Double((current[0] &- previous[0]) + (current[1] &- previous[1]) + (current[2] &- previous[2]))
            let idle = Double(current[3] &- previous[3])
            let span = busy + idle
            perCore.append(span > 0 ? busy / span : 0)
        }
        let total = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)
        return Snapshot(perCore: perCore, total: total,
                        memoryUsed: memoryUsed(), memoryTotal: Self.memoryTotal,
                        gpuFraction: includeGPU ? gpuUtilisation() : nil,
                        disk: Self.diskUsage())
    }

    /// Busy fraction from the graphics accelerator.
    ///
    /// `PerformanceStatistics` is where macOS publishes this; there is no
    /// public API. The frequency is deliberately not read from here — the
    /// dictionary does not contain one on this hardware, and a number that is
    /// not there cannot be shown honestly.
    private func gpuUtilisation() -> Double? {
        var best: Double?
        Registry.forEachService(matching: "IOAccelerator") { accelerator in
            // One property rather than the whole dictionary: copying every
            // key an accelerator publishes to read one integer out of it was
            // the most expensive thing in this reading.
            guard let stats: [String: Any] = Registry.property(accelerator, statisticsKey),
                  let used = stats["Device Utilization %"] as? Int else { return }
            // The busiest accelerator wins: with the discrete card awake both
            // answer, and the one doing the work is the interesting one.
            best = max(best ?? 0, Double(used) / 100)
        }
        return best
    }

    private let statisticsKey = "PerformanceStatistics" as CFString

    static func diskUsage() -> Disk? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = (attributes[.systemSize] as? NSNumber)?.uint64Value,
              let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value,
              total > 0 else { return nil }
        return Disk(usedBytes: total > free ? total - free : 0, totalBytes: total)
    }

    // MARK: Sources

    /// user, system, nice, idle per core.
    private func coreTicks() -> [[UInt32]]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info = info else { return nil }
        // The kernel allocated this; not freeing it leaks a page per poll.
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }
        let ticks = UnsafeBufferPointer(start: info, count: Int(infoCount))
        return (0..<Int(cpuCount)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            return [UInt32(bitPattern: ticks[base + Int(CPU_STATE_USER)]),
                    UInt32(bitPattern: ticks[base + Int(CPU_STATE_SYSTEM)]),
                    UInt32(bitPattern: ticks[base + Int(CPU_STATE_NICE)]),
                    UInt32(bitPattern: ticks[base + Int(CPU_STATE_IDLE)])]
        }
    }

    /// "Used" the way Activity Monitor means it: everything that is not free
    /// and not reclaimable. Counting only `wired` understates it wildly, and
    /// counting everything but `free` overstates it — inactive pages are
    /// available on demand.
    private func memoryUsed() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let reclaimable = UInt64(stats.free_count + stats.inactive_count) * page
        return Self.memoryTotal > reclaimable ? Self.memoryTotal - reclaimable : 0
    }
}
