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
        var found: [Int: String] = [:]
        Registry.forEachService(matching: "IOAccelerator") { accelerator in
            guard isDiscrete(Registry.name(of: accelerator)) else { return }
            collectClients(of: accelerator, into: &found)
        }
        return found.map { Holder(pid: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Which accelerator is the discrete one, by the vendor's own name.
    static func isDiscrete(_ acceleratorName: String) -> Bool {
        acceleratorName.contains("AMD") || acceleratorName.contains("NVDA")
            || acceleratorName.contains("GeForce")
    }

    private static func collectClients(of service: io_service_t, into found: inout [Int: String]) {
        Registry.forEachChild(of: service) { child in
            guard isWorkClient(Registry.className(of: child)),
                  let creator: String = Registry.property(child, creatorKey),
                  let holder = parse(creator) else { return }
            found[holder.pid] = holder.name
        }
    }

    /// Bridged once rather than per child: this is asked of every client of
    /// every accelerator, and there are dozens.
    private static let creatorKey = "IOUserClientCreator" as CFString

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

}
