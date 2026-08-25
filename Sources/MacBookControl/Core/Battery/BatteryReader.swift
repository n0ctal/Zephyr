import Foundation
import IOKit.ps

/// Unprivileged view of the battery: charge, health and whether the charger is
/// actually pushing current right now.
///
/// The charge *limit* itself lives in the SMC and is written by the daemon
/// (see `BatteryLimit`); this type only reports state so the menu can explain
/// what the limit is doing — a machine parked at 80 % with the charger plugged
/// in looks broken until you can see that it is deliberate.
final class BatteryReader {
    func read() -> BatteryStatus? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }

            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            return BatteryStatus(
                percent: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                isCharging: d[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                healthPercent: designCapacityPercent()
            )
        }
        return nil
    }

    /// Health from the SMC's own full-charge vs design capacity. IOKit reports
    /// a coarse "Good/Fair/Poor" string; the raw ratio is more useful.
    private func designCapacityPercent() -> Int? {
        guard let smc = try? SMC() else { return nil }
        defer { smc.close() }
        guard let full = (try? smc.read("B0FC"))?.double,
              let design = (try? smc.read("B0DC"))?.double,
              design > 0
        else { return nil }
        return Int((full / design * 100).rounded())
    }
}
