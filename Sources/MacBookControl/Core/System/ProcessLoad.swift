import Darwin
import Foundation

/// Which processes are actually costing something.
///
/// The readings elsewhere say the machine is busy; this says what is making it
/// busy, which is the question anybody watching a fan spin up actually has.
/// It is the useful half of what Activity Monitor is opened for, and the half
/// iStat Menus and Stats put in the menu bar.
///
/// Everything here is `libproc`, so it needs no privileges — with the honest
/// limit that another user's processes will not answer, and are skipped rather
/// than guessed at.
final class ProcessLoad {
    /// One reader for the whole app: the rate is a difference between two
    /// readings, and two readers taking turns would each see half the gaps.
    static let shared = ProcessLoad()


    struct Entry: Identifiable, Equatable {
        let pid: Int32
        let name: String
        /// Share of one core, so a process using two cores fully reads 200 %.
        /// That is what Activity Monitor shows, and matching it matters more
        /// than being tidy.
        let cpu: Double
        let memoryBytes: UInt64
        var id: Int32 { pid }
    }

    struct Snapshot: Equatable {
        let byCPU: [Entry]
        let byMemory: [Entry]
    }

    /// Cumulative CPU nanoseconds per process, from the previous reading.
    private var previous: [Int32: UInt64] = [:]
    private var previousAt: Date?

    /// Nil until two samples exist: a share of a core is a rate, and the first
    /// reading has nothing to subtract from.
    func read(top count: Int = 5) -> Snapshot? {
        let now = Date()
        let elapsed = previousAt.map { now.timeIntervalSince($0) }
        defer { previousAt = now }

        var current: [Int32: UInt64] = [:]
        var entries: [Entry] = []

        for pid in pids() {
            var usage = rusage_info_current()
            let read = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            // Another user's process, or one that exited between the list and
            // the question. Neither is worth a word.
            guard read == 0 else { continue }

            let cpuNanoseconds = usage.ri_user_time + usage.ri_system_time
            current[pid] = cpuNanoseconds

            guard let elapsed = elapsed, elapsed > 0.2, elapsed < 60,
                  let before = previous[pid] else { continue }
            let share = Double(cpuNanoseconds &- before) / 1_000_000_000 / elapsed * 100
            entries.append(Entry(pid: pid, name: name(of: pid),
                                 cpu: max(0, share),
                                 memoryBytes: usage.ri_phys_footprint))
        }
        previous = current
        guard !entries.isEmpty else { return nil }

        return Snapshot(
            byCPU: Array(entries.sorted { $0.cpu > $1.cpu }.prefix(count)),
            byMemory: Array(entries.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(count)))
    }

    // MARK: libproc

    private func pids() -> [Int32] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var buffer = [Int32](repeating: 0, count: Int(count) / MemoryLayout<Int32>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer,
                                    Int32(buffer.count * MemoryLayout<Int32>.size))
        guard written > 0 else { return [] }
        return buffer.prefix(Int(written) / MemoryLayout<Int32>.size).filter { $0 > 0 }
    }

    private func name(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }
}
