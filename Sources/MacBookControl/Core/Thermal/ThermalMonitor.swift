import Foundation
import IOKit

/// Reads how hard the firmware is currently holding the CPU back.
///
/// This is the number `pmset -g therm` prints and the one thermal-throttling
/// monitors show: when the package gets too hot (or the charger cannot supply
/// enough power) the SMC caps the CPU, and `CPU_Speed_Limit` drops below 100.
/// It is a firmware decision — nothing here changes it, we only surface it,
/// because a machine that is quietly running at 60 % looks "fine" otherwise.
///
/// Everything below is unprivileged: no helper, no SMC writes.
final class ThermalMonitor {
    /// `IOPMCopyCPUPowerStatus` is not exposed to Swift, so it is resolved at
    /// runtime from IOKit. A nil handle simply means the reading is
    /// unavailable and the UI hides the section rather than lying.
    private typealias CopyCPUPowerStatus = @convention(c) (UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> kern_return_t
    private let copyStatus: CopyCPUPowerStatus?

    init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        if let handle, let sym = dlsym(handle, "IOPMCopyCPUPowerStatus") {
            copyStatus = unsafeBitCast(sym, to: CopyCPUPowerStatus.self)
        } else {
            copyStatus = nil
        }
    }

    func read() -> ThermalStatus {
        ThermalStatus(
            speedLimitPercent: cpuPowerValue("CPU_Speed_Limit"),
            schedulerLimitPercent: cpuPowerValue("CPU_Scheduler_Limit"),
            availableCPUs: cpuPowerValue("CPU_Available_CPUs"),
            pressure: ThermalPressure(ProcessInfo.processInfo.thermalState)
        )
    }

    private func cpuPowerValue(_ key: String) -> Int? {
        guard let copyStatus else { return nil }
        var raw: Unmanaged<CFDictionary>?
        guard copyStatus(&raw) == KERN_SUCCESS, let dict = raw?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict[key] as? Int
    }
}
