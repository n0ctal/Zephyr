import Foundation
import IOKit
import IOKit.ps

/// Unprivileged view of the battery: charge, wear, cycles and where the watts
/// are actually going.
///
/// The charge *ceiling* itself lives in the SMC and is written by the daemon
/// (see `BatteryLimit`); this type only reports state, so the menu can explain
/// what the ceiling is doing — a machine parked at 80 % with the charger
/// plugged in looks broken until you can see that it is deliberate.
final class BatteryReader {
    /// The connection the power registers are read through.
    ///
    /// Shared with the rest of telemetry when there is one. Opening a
    /// connection of its own for every reading — which is what this did — cost
    /// an IOServiceOpen and an IOServiceClose on every tick and made the
    /// battery the most expensive thing in it, above the sensor sweep.
    private let smc: SMC?

    /// The registry entry for the battery, kept rather than matched again.
    ///
    /// The node does not come and go on a laptop, and finding it costs a
    /// matching dictionary and a registry search on every tick. A read that
    /// fails releases it, so a machine that does somehow lose the node picks
    /// it up again on the next tick instead of never.
    ///
    /// Mutable, so this reader is bound to one queue like the SMC connection
    /// beside it — which is the contract telemetry already keeps for it, and
    /// why the blocking read goes through the same queue as the ticks.
    private var service: io_service_t = 0

    /// What the charge is worked out from, and what the menu bar's icon
    /// therefore needs: how full, and whether it is filling.
    ///
    /// The node carries fifty-one properties, nine of them nested structures —
    /// the IOReport legend, the telemetry blob, the adapter's details — and
    /// asking for all of them cost 317 us per tick against 110 for the
    /// fourteen the reading uses, and 35 for these four. The serialising of
    /// the blobs is the whole difference.
    private static let chargeKeys = [
        "CurrentCapacity", "MaxCapacity", "IsCharging", "ExternalConnected",
    ]

    /// The rest of what the reading uses. Health, cycles, the temperature, the
    /// flow and the estimate of the time left — all of it shown only inside
    /// the window.
    ///
    /// A key used by the parsing but missing from these lists reads as nil,
    /// not as wrong, which is invisible. `readWholeNode()` exists so the
    /// self-test can compare the two and fail when they disagree.
    private static let detailKeys = [
        "CycleCount", "AppleRawMaxCapacity", "DesignCapacity", "Temperature",
        "Amperage", "Voltage", "TimeRemaining", "AvgTimeToEmpty",
        "InstantTimeToEmpty", "AppleRawCurrentCapacity",
    ]

    init(smc: SMC? = nil) {
        self.smc = smc
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// `inDetail` false reads the charge and nothing else: four registry
    /// properties instead of fourteen, and neither of the two SMC registers
    /// behind the power readout. Everything it leaves out — health, cycles,
    /// temperature, watts, time left — is shown only inside the window, and
    /// comes back nil.
    func read(inDetail: Bool = true) -> BatteryStatus? {
        guard let props = smartBatteryProperties(inDetail: inDetail) else { return nil }
        return status(from: props, includingSupply: inDetail)
    }

    /// The same reading, taken by fetching every property of the node.
    ///
    /// Only the self-test calls this: it is the slow way, kept so the fast way
    /// can be checked against it.
    func readWholeNode() -> BatteryStatus? {
        guard let node = batteryService() else { return nil }
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(node, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = raw?.takeRetainedValue() as? [String: Any] else { return nil }
        return status(from: props, includingSupply: true)
    }

    private func status(from props: [String: Any], includingSupply: Bool) -> BatteryStatus? {
        let current = props["CurrentCapacity"] as? Int ?? 0
        let max = props["MaxCapacity"] as? Int ?? 0
        let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : 0

        return BatteryStatus(
            percent: percent,
            isCharging: props["IsCharging"] as? Bool ?? false,
            isPluggedIn: props["ExternalConnected"] as? Bool ?? false,
            healthPercent: health(props),
            cycleCount: props["CycleCount"] as? Int,
            fullChargeCapacity: (props["AppleRawMaxCapacity"] as? Int)
                ?? (props["MaxCapacity"] as? Int),
            designCapacity: props["DesignCapacity"] as? Int,
            // Tenths of a kelvin. Two wrong readings of this register were
            // shipped before it was checked against something: hundredths of a
            // kelvin gave −243 °C, hundredths of a degree gave 30.0 °C while
            // the SMC's own battery sensors read 27.4–27.7 °C for the same
            // moment. Tenths of a kelvin puts 3002 at 27.05 °C, which is what
            // the sensors beside it say.
            celsius: (props["Temperature"] as? Int).map { Double($0) / 10 - 273.15 },
            power: power(batteryWatts: batteryWatts(props), includingSupply: includingSupply),
            minutesRemaining: minutesRemaining(props)
        )
    }

    /// Wear is the *raw* full-charge capacity against the design capacity.
    /// The SMC's own `B0DC` is not in the same units as `B0FC` — using it
    /// produced a health figure of 33 % on a battery that is actually at 82 %.
    private func health(_ props: [String: Any]) -> Int? {
        guard let design = props["DesignCapacity"] as? Int, design > 0,
              let raw = (props["AppleRawMaxCapacity"] as? Int) ?? (props["MaxCapacity"] as? Int)
        else { return nil }
        return Int((Double(raw) / Double(design) * 100).rounded())
    }

    /// Where the power is going right now. The SMC publishes these as floats:
    /// what the system draws, what the adapter supplies, and what the battery
    /// is contributing (or absorbing).
    /// Battery flow in watts, signed. Positive while charging, negative while
    /// the battery carries the machine.
    ///
    /// From IOKit rather than the SMC: the SMC's `PPBR` reports the magnitude
    /// only, so a discharging machine read as a positive number and the menu
    /// bar claimed the battery was filling while the charger was unplugged.
    /// `Amperage` is signed and `Voltage` is in millivolts, so the product is
    /// in microwatts.
    private func batteryWatts(_ props: [String: Any]) -> Double? {
        guard let milliAmps = props["Amperage"] as? Int,
              let milliVolts = props["Voltage"] as? Int else { return nil }
        return Double(milliAmps) * Double(milliVolts) / 1_000_000
    }

    /// How long the battery has left, or how long until it is full.
    ///
    /// The system's own estimate is asked first, but it answers 65535 — "do
    /// not know" — far more often than it answers a number: on the charger,
    /// after a wake, whenever the reading has not settled. So when it declines,
    /// the figure is worked out instead: charge remaining divided by the
    /// current flowing. Both are already read for other purposes and the
    /// arithmetic is exact, which beats waiting for the system to feel ready.
    private func minutesRemaining(_ props: [String: Any]) -> Int? {
        for key in ["TimeRemaining", "AvgTimeToEmpty", "InstantTimeToEmpty"] {
            if let value = props[key] as? Int, value > 0, value < 65535 { return value }
        }

        guard let milliAmps = props["Amperage"] as? Int, milliAmps != 0 else { return nil }
        let current = abs(Double(milliAmps))

        if milliAmps < 0 {
            // Discharging: what is left, over what is being drawn.
            guard let charge = (props["AppleRawCurrentCapacity"] as? Int)
                    ?? (props["CurrentCapacity"] as? Int), charge > 0 else { return nil }
            return Int((Double(charge) / current) * 60)
        }
        // Charging: the gap to full, over what is going in.
        guard let charge = (props["AppleRawCurrentCapacity"] as? Int)
                ?? (props["CurrentCapacity"] as? Int),
              let full = (props["AppleRawMaxCapacity"] as? Int)
                ?? (props["MaxCapacity"] as? Int),
              full > charge else { return nil }
        return Int((Double(full - charge) / current) * 60)
    }

    private func power(batteryWatts: Double?, includingSupply: Bool) -> PowerDraw? {
        guard includingSupply else {
            guard let batteryWatts = batteryWatts else { return nil }
            return PowerDraw(systemWatts: nil, adapterWatts: nil, batteryWatts: batteryWatts)
        }
        if let shared = smc { return power(batteryWatts: batteryWatts, through: shared) }
        // Nobody handed us one — a command-line probe, or a caller that has no
        // telemetry behind it. Open one for the reading and give it back.
        guard let own = try? SMC() else { return nil }
        defer { own.close() }
        return power(batteryWatts: batteryWatts, through: own)
    }

    private func power(batteryWatts: Double?, through smc: SMC) -> PowerDraw? {
        let system = (try? smc.read("PSTR"))?.double
        let adapter = (try? smc.read("PDTR"))?.double
        guard system != nil || adapter != nil || batteryWatts != nil else { return nil }
        return PowerDraw(systemWatts: system, adapterWatts: adapter, batteryWatts: batteryWatts)
    }

    /// AppleSmartBattery carries the numbers IOPowerSources rounds away.
    ///
    /// Asked for by name: see `chargeKeys` for why the whole node is not.
    private func smartBatteryProperties(inDetail: Bool) -> [String: Any]? {
        guard let node = batteryService() else { return nil }
        let keys = inDetail ? Self.chargeKeys + Self.detailKeys : Self.chargeKeys
        var props: [String: Any] = [:]
        props.reserveCapacity(keys.count)
        for key in keys {
            guard let value = IORegistryEntryCreateCFProperty(node, key as CFString,
                                                              kCFAllocatorDefault, 0)
            else { continue }
            props[key] = value.takeRetainedValue()
        }
        // An empty answer means the node went away under us rather than that
        // the battery has nothing to say, so let the next tick find it again.
        guard !props.isEmpty else {
            IOObjectRelease(node)
            service = 0
            return nil
        }
        return props
    }

    private func batteryService() -> io_service_t? {
        if service != 0 { return service }
        let found = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"))
        guard found != 0 else { return nil }
        service = found
        return found
    }
}
