import Darwin
import Foundation

/// How fast bytes are moving over the network, in and out.
///
/// macOS publishes totals, not rates: every interface carries a running count
/// of bytes since it came up. A speed is the difference between two of those
/// counts divided by the time between them, which is why this holds state and
/// why the first reading produces nothing at all.
final class NetworkThroughput {
    struct Snapshot {
        /// Bytes per second, averaged over the gap between the last two reads.
        let downloadBytes: Double
        let uploadBytes: Double
    }

    private var previous: (received: UInt32, sent: UInt32, at: Date)?

    /// Nil until two samples exist, and after a gap long enough that the
    /// average would be meaningless — waking from sleep is the usual case, and
    /// dividing an hour of overnight traffic by an hour is not a speed anybody
    /// asked about.
    func read() -> Snapshot? {
        guard let totals = Self.totals() else { return nil }
        let now = Date()
        defer { previous = (totals.received, totals.sent, now) }
        guard let last = previous else { return nil }

        let elapsed = now.timeIntervalSince(last.at)
        guard elapsed > 0.2, elapsed < 60 else { return nil }

        // Wrapping subtraction on purpose. These counters are 32 bits wide, so
        // on a fast link they roll over about every four gigabytes — plain
        // subtraction would then go negative and print a speed of minus several
        // hundred megabytes a second.
        let received = Double(totals.received &- last.received) / elapsed
        let sent = Double(totals.sent &- last.sent) / elapsed
        // An interface that goes away between two reads takes its lifetime
        // total with it, and the sum drops by several gigabytes — which the
        // wrapping subtraction above faithfully reports as a very large
        // positive number. Unplugging a dock would flash "3.4 GB/s" across the
        // menu bar. Nothing here does that speed, so a reading that claims to
        // is a counter that moved for some reason other than traffic.
        guard Self.isPlausible(received), Self.isPlausible(sent) else { return nil }
        return Snapshot(downloadBytes: received, uploadBytes: sent)
    }

    /// Every interface that is up, added together — minus loopback and the
    /// tunnels.
    ///
    /// Loopback is the machine talking to itself and is not network traffic in
    /// any sense the person watching the menu bar means. Tunnels are excluded
    /// because the same bytes are counted twice: once as they pass through the
    /// VPN interface and again as they leave over Wi-Fi, and a menu bar that
    /// doubles its reading the moment a VPN connects is worse than useless.
    private static func totals() -> (received: UInt32, sent: UInt32)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var received: UInt32 = 0
        var sent: UInt32 = 0
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            // The byte counts hang off the link-level entry; the same interface
            // also appears once per IP address, carrying no counters.
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = current.pointee.ifa_data else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard !isTunnel(name) else { continue }

            let counters = data.assumingMemoryBound(to: if_data.self)
            received &+= counters.pointee.ifi_ibytes
            sent &+= counters.pointee.ifi_obytes
        }
        return (received, sent)
    }

    /// Two gigabytes a second — sixteen gigabits, comfortably past ten-gigabit
    /// Ethernet and every Wi-Fi radio, and below the rate at which these
    /// counters become unreliable anyway: they are 32 bits wide, so at this
    /// speed they wrap between one reading and the next and the difference
    /// stops meaning anything. A number above it is a counter that moved for
    /// some reason other than traffic.
    static func isPlausible(_ bytesPerSecond: Double) -> Bool {
        bytesPerSecond >= 0 && bytesPerSecond < 2 * 1024 * 1024 * 1024
    }

    static func isTunnel(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "gif", "stf"].contains { name.hasPrefix($0) }
    }

    /// One rate, written the way a menu bar can hold it.
    ///
    /// Three digits at most and never a changing number of them: a field that
    /// grows from "9.9" to "10.0" shoves everything beside it sideways, which
    /// in a status item happens in the corner of the eye and reads as a glitch.
    static func format(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1 { return "0 KB/s" }
        if kb < 1000 { return String(format: "%.0f KB/s", kb) }
        let mb = kb / 1024
        if mb < 1000 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.1f GB/s", mb / 1024)
    }
}
