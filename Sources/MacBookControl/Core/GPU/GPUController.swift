import Foundation
import Metal
import CoreGraphics

/// Graphics-switching policy, matching macOS's `pmset gpuswitch` values.
enum GPUMode: Int, CaseIterable {
    case integratedOnly = 0
    case discreteOnly = 1
    case automatic = 2

    var label: String {
        switch self {
        case .integratedOnly: return "Integrated only"
        case .discreteOnly: return "Discrete only"
        case .automatic: return "Automatic"
        }
    }
}

/// A snapshot of the GPU subsystem for display.
struct GPUInfo {
    let integratedName: String?
    let discreteName: String?
    let mode: GPUMode?
    let activeName: String?
    let activeIsLowPower: Bool?
}

/// Reads and controls the dual-GPU switching policy.
///
/// Detection (which GPUs exist, which is active) is unprivileged and uses
/// Metal / CoreGraphics. The policy itself is read via `pmset -g` and changed
/// via `pmset -a gpuswitch <0|1|2>` — Apple's own supported lever, which
/// requires root (routed through the privileged helper in the app).
final class GPUController {
    /// True only on machines that expose a switchable dual-GPU setup.
    let isDualGPU: Bool
    let integratedName: String?
    let discreteName: String?

    init() {
        let devices = MTLCopyAllDevices()
        integratedName = devices.first(where: { $0.isLowPower })?.name
        discreteName = devices.first(where: { !$0.isLowPower && !$0.isRemovable })?.name
        isDualGPU = integratedName != nil && discreteName != nil
    }

    // MARK: Live state

    /// The Metal device currently driving the main display, if known.
    func activeDevice() -> MTLDevice? {
        CGDirectDisplayCopyCurrentMetalDevice(CGMainDisplayID())
    }

    /// `includeActive` instantiates a Metal device to learn which GPU is
    /// rendering. That is the only way to ask — and it can itself wake the
    /// discrete GPU, so it is off by default and requested only by the tab
    /// that displays the answer, never by anything on a timer.
    func info(includeActive: Bool = false) -> GPUInfo {
        let active = includeActive ? activeDevice() : nil
        return GPUInfo(
            integratedName: integratedName,
            discreteName: discreteName,
            mode: currentMode(),
            activeName: active?.name,
            activeIsLowPower: active?.isLowPower
        )
    }

    // MARK: Policy (read)

    /// Reads the current `gpuswitch` policy by parsing `pmset -g` (unprivileged).
    func currentMode() -> GPUMode? {
        // `pmset -g` costs 228 ms measured on this machine, and the GPU
        // watchdog asks every five seconds — that alone made the whole app
        // feel sticky. The same value sits in the preferences file pmset
        // itself writes, and reading it costs 1 ms.
        if let mode = Self.modeFromPreferences() { return mode }
        guard let output = Self.runPmset(["-g"]) else { return nil }
        for line in output.split(separator: "\n") where line.contains("gpuswitch") {
            if let value = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap({ Int($0) }).first {
                return GPUMode(rawValue: value)
            }
        }
        return nil
    }

    /// Digs `GPUSwitch` out of the power-management preferences. The file
    /// nests it under a profile key that differs by machine, so it is searched
    /// for rather than addressed — a wrong guess would silently read nothing
    /// and fall back to the slow path forever.
    private static func modeFromPreferences() -> GPUMode? {
        let path = "/Library/Preferences/com.apple.PowerManagement.plist"
        guard let root = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
        func search(_ any: Any) -> Int? {
            guard let dict = any as? [String: Any] else { return nil }
            if let value = dict["GPUSwitch"] as? Int { return value }
            for (_, nested) in dict {
                if let found = search(nested) { return found }
            }
            return nil
        }
        return search(root).flatMap(GPUMode.init(rawValue:))
    }

    // MARK: Policy (write — requires root)

    /// Sets the `gpuswitch` policy. Must run as root (helper or sudo);
    /// returns false if pmset reports failure or we lack privilege.
    @discardableResult
    func setMode(_ mode: GPUMode) -> Bool {
        Self.runPmset(["-a", "gpuswitch", "\(mode.rawValue)"]) != nil
    }

    // MARK: pmset bridge

    private static func runPmset(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Not a Pipe: nothing drains it, and a chatty child would block forever
        // on the one serial queue that also drives fan control.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return nil
        }
    }
}
