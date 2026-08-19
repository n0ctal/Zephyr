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

    func info() -> GPUInfo {
        let active = activeDevice()
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
        guard let output = Self.runPmset(["-g"]) else { return nil }
        for line in output.split(separator: "\n") where line.contains("gpuswitch") {
            if let value = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap({ Int($0) }).first {
                return GPUMode(rawValue: value)
            }
        }
        return nil
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
