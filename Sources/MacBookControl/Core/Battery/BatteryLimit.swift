import Foundation

/// Caps how far the firmware will charge the battery, the way AlDente does.
///
/// The SMC exposes `BCLM` — a single byte, "charge no further than this
/// percent". 100 means no limit. Parking a lithium cell at 100 % is what ages
/// it fastest, so holding it around 80 % on a machine that lives on the
/// charger is worth real capacity over a year.
///
/// Two things make this less trivial than one write:
///   * the firmware resets `BCLM` across sleep and power loss, so the value has
///     to be re-asserted — the same problem the Turbo bit has;
///   * a limit below the current charge does **not** discharge the battery. The
///     machine simply stops charging and sits there, which looks like a fault
///     until the menu says otherwise.
///
/// Writing lives in the daemon; the app only reads and asks.
enum BatteryLimit {
    static let key = "BCLM"

    /// Below this the machine spends its life nearly empty, which is its own
    /// kind of wear, and a typo of "5" should not brick the day.
    static let minimumPercent = 20
    static let unlimited = 100

    /// Whether this Mac exposes the key at all. Apple silicon and some Intel
    /// models do not, and the feature must then stay hidden rather than
    /// silently do nothing.
    static func isSupported() -> Bool {
        guard let smc = try? SMC() else { return false }
        defer { smc.close() }
        return (try? smc.read(key)) != nil
    }

    /// Current limit in percent, or nil when unreadable.
    static func current() -> Int? {
        guard let smc = try? SMC() else { return nil }
        defer { smc.close() }
        guard let value = try? smc.read(key), let d = value.double else { return nil }
        return Int(d)
    }

    /// Apply a limit. `unlimited` (100) restores normal charging.
    @discardableResult
    static func apply(_ percent: Int) -> Bool {
        let clamped = min(max(percent, minimumPercent), unlimited)
        guard let smc = try? SMC() else { return false }
        defer { smc.close() }
        do {
            try smc.write(key, bytes: [UInt8(clamped)])
            return true
        } catch {
            return false
        }
    }
}
