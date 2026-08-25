import Foundation

/// Controls Intel Turbo Boost via the DisableTurboBoost kext.
///
/// Model: the kext being *loaded* means Turbo Boost is *disabled* (its start()
/// sets IA32_MISC_ENABLE bit 38 on every core); unloading re-enables it.
///
/// Reading state (is the kext loaded?) is unprivileged. Loading/unloading
/// requires root and runs in the helper. Requires SIP disabled + a one-time
/// System Settings approval of the kext.
final class TurboBoostController {
    static let kextIdentifier = "com.n0ctal.DisableTurboBoost"
    /// Where the helper install step places the kext (root-owned).
    static let kextPath = "/Library/Application Support/MacBookControl/DisableTurboBoost.kext"

    /// True if the discrete CPU actually has a turbo-capable design. We treat
    /// availability as "the kext file is installed"; callers can refine.
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.kextPath)
    }

    // MARK: Read (unprivileged)

    /// Cached because asking costs 813 ms, measured: `kextstat` walks every
    /// loaded extension, and this is asked on init and on every menu open.
    /// Nothing else on the machine loads or unloads this bundle, so our own
    /// writes are the only thing that can invalidate it.
    private var cachedDisabled: Bool?

    /// Whether Turbo Boost is currently disabled (i.e. the kext is loaded).
    func isTurboDisabled() -> Bool {
        if let cached = cachedDisabled { return cached }
        return refreshTurboState()
    }

    /// Asks the system and re-primes the cache. Call this off the main thread
    /// at startup, and after a wake — the firmware restores the register
    /// across sleep while the bundle stays loaded.
    @discardableResult
    func refreshTurboState() -> Bool {
        let loaded = Self.run("/usr/sbin/kextstat", ["-l"])?.contains(Self.kextIdentifier) ?? false
        cachedDisabled = loaded
        return loaded
    }

    var isTurboEnabled: Bool { !isTurboDisabled() }

    // MARK: Write (root — helper only)

    /// Enables (true) or disables (false) Turbo Boost by unloading / loading
    /// the kext. Idempotent. Returns false on failure (e.g. not approved).
    @discardableResult
    func setTurboEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            guard isTurboDisabled() else { return true }   // already on
            let ok = Self.run("/usr/bin/kmutil", ["unload", "-b", Self.kextIdentifier]) != nil
            if ok { cachedDisabled = false }
            return ok
        } else {
            guard !isTurboDisabled() else { return true }  // already off
            let ok = Self.run("/usr/bin/kmutil", ["load", "-p", Self.kextPath]) != nil
            if ok { cachedDisabled = true }
            return ok
        }
    }

    /// Re-applies the disable after a wake. The kext writes MSR bit 38 once in
    /// its start routine, and firmware restores the MSR across sleep, so the bit
    /// is gone while kextstat still reports the bundle loaded — hence the reload.
    @discardableResult
    func reapplyDisableAfterWake() -> Bool {
        guard isTurboDisabled() else { return true }   // nothing to re-apply
        guard Self.run("/usr/bin/kmutil", ["unload", "-b", Self.kextIdentifier]) != nil else { return false }
        return Self.run("/usr/bin/kmutil", ["load", "-p", Self.kextPath]) != nil
    }

    // MARK: Process bridge

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
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
