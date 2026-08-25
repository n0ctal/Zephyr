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
            power: power(batteryWatts: batteryWatts(props))
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

    private func power(batteryWatts: Double?) -> PowerDraw? {
        guard let smc = try? SMC() else { return nil }
        defer { smc.close() }
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
