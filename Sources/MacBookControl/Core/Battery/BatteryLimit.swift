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
    ///
    /// Remembered, because this is asked from a view body: SwiftUI re-runs
    /// those on every published change, so with the settings window open the
    /// question was being answered by opening a connection to the SMC, reading
    /// a key and closing it again, on every telemetry tick. Whether the
    /// machine has the key is not something that changes while it is running.
    ///
    /// Only an answer is kept. Failing to open the SMC at all is not an
    /// answer, and caching it would hide the feature for the rest of the
    /// session over one bad moment.
    private static var known: Bool?

    static func isSupported() -> Bool {
        if let known { return known }
        guard let smc = try? SMC() else { return false }
        defer { smc.close() }
        do {
            _ = try smc.read(key)
            known = true
            return true
        } catch SMCError.smcError(kSMCKeyNotFound) {
            // The chip answered, and what it said is that there is no such
            // key. That will not change while the machine is running.
            known = false
            return false
        } catch {
            // Everything else — a failed call, a connection that went away,
            // any other status byte — is the asking failing rather than the
            // key being absent. Remembering it would hide the feature for the
            // rest of the session over one bad moment, which is what the note
            // above promises not to do. Matching every status byte, as this
            // did, made that promise false for all but one of them.
            return false
        }
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
