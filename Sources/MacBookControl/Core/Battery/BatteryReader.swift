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

    init(smc: SMC? = nil) {
        self.smc = smc
    }

    func read() -> BatteryStatus? {
        guard let props = smartBatteryProperties() else { return nil }

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
            power: power(batteryWatts: batteryWatts(props)),
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

    private func power(batteryWatts: Double?) -> PowerDraw? {
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
    private func smartBatteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return raw?.takeRetainedValue() as? [String: Any]
    }
}
