import Foundation

/// Mach service name the privileged daemon registers and the app connects to.
let kHelperMachServiceName = "com.n0ctal.macbookcontrol.helper"

/// Bumped when the XPC contract changes; the app compares this against the
/// running daemon to detect a stale installed helper.
let kHelperVersion = "3"

/// XPC contract between the unprivileged app and the root daemon.
/// Only operations that genuinely require root live here; all reading
/// (sensors, fan RPM, GPU detection) happens unprivileged in the app.
@objc(MBCHelperProtocol)
protocol HelperProtocol {
    func getVersion(reply: @escaping (String) -> Void)

    /// The control mode of each fan, indexed by fan number:
    /// "auto" (firmware), "manual" (fixed target), or "curve" (temperature).
    func fanModes(reply: @escaping ([String]) -> Void)

    /// Force a fan to a target RPM. The daemon holds it by re-asserting
    /// in a control loop until told otherwise.
    func setFanManual(fan: Int, rpm: Int, reply: @escaping (Bool) -> Void)

    /// Put a fan under a temperature curve (linear ramp from min RPM at
    /// `minTemp` °C to max RPM at `maxTemp` °C, driven by CPU temperature).
    func setFanCurve(fan: Int, minTemp: Int, maxTemp: Int, reply: @escaping (Bool) -> Void)

    /// Return a single fan to firmware (automatic) control.
    func setFanAuto(fan: Int, reply: @escaping (Bool) -> Void)

    /// Re-apply the Turbo state after wake. The kext writes MSR bit 38 once at
    /// load, and firmware clears it across sleep, so the bit has to be set again.
    func reapplyTurboAfterWake(reply: @escaping (Bool) -> Void)

    /// Return all fans to automatic control and stop the control loop.
    func setAllFansAuto(reply: @escaping (Bool) -> Void)

    /// Set the GPU switching policy (0=integrated, 1=discrete, 2=automatic).
    func setGPUMode(_ rawValue: Int, reply: @escaping (Bool) -> Void)

    /// Enable (true) or disable (false) Intel Turbo Boost by unloading /
    /// loading the kext.
    func setTurboBoostEnabled(_ enabled: Bool, reply: @escaping (Bool) -> Void)
}
