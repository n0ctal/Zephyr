import Foundation
import Security
import os

private let helperLog = Logger(subsystem: "com.n0ctal.macbookcontrol.helper", category: "daemon")

/// Root-owned file holding the cdhash of the one app allowed to connect.
/// Written by install-helper.sh from the installed /Applications/Zephyr.app.
private let kAuthorizedCDHashPath = "/Library/Application Support/MacBookControl/authorized-cdhash"

/// The root-side implementation of `HelperProtocol`. A single shared instance
/// serves every XPC connection. All SMC/pmset work is serialized on one queue.
final class HelperService: NSObject, HelperProtocol {
    private let queue = DispatchQueue(label: "com.n0ctal.macbookcontrol.helper.control")
    private let smc: SMC?
    private let fans: FanController?
    private let sensors: SensorReader?
    private let gpu = GPUController()
    private let turbo = TurboBoostController()

    /// Fans forced to a fixed target RPM, re-asserted by the control loop
    /// because the firmware reverts manual mode if it is not held.
    private var forcedTargets: [Int: Int] = [:]
    /// Fans following a temperature curve; each tick recomputes their target.
    private var curveFans: [Int: FanCurve] = [:]
    private var controlTimer: DispatchSourceTimer?

    override init() {
        let smc = try? SMC()
        self.smc = smc
        self.fans = smc.map { FanController(smc: $0) }
        self.sensors = smc.map { SensorReader(smc: $0) }
        super.init()
    }

    // MARK: HelperProtocol

    func getVersion(reply: @escaping (String) -> Void) {
        reply(kHelperVersion)
    }

    func fanModes(reply: @escaping ([String]) -> Void) {
        queue.async {
            let count = self.fans?.fanCount ?? 0
            let modes = (0 ..< count).map { fan -> String in
                if self.curveFans[fan] != nil { return "curve" }
                if self.forcedTargets[fan] != nil { return "manual" }
                return "auto"
            }
            reply(modes)
        }
    }

    func setFanManual(fan: Int, rpm: Int, reply: @escaping (Bool) -> Void) {
        queue.async {
            self.curveFans.removeValue(forKey: fan)   // fixed target overrides curve
            self.forcedTargets[fan] = rpm
            self.startControlLoopIfNeeded()
            let ok = (try? self.fans?.setManual(fan: fan, rpm: rpm)) != nil
            reply(ok)
        }
    }

    func setFanCurve(fan: Int, minTemp: Int, maxTemp: Int, reply: @escaping (Bool) -> Void) {
        queue.async {
            self.forcedTargets.removeValue(forKey: fan)
            self.curveFans[fan] = FanCurve(minTemp: Double(minTemp), maxTemp: Double(maxTemp))
            self.startControlLoopIfNeeded()
            self.applyCurve(fan: fan)   // apply immediately
            reply(true)
        }
    }

    func setFanAuto(fan: Int, reply: @escaping (Bool) -> Void) {
        queue.async {
            self.forcedTargets.removeValue(forKey: fan)
            self.curveFans.removeValue(forKey: fan)
            try? self.fans?.setAuto(fan: fan)
            self.stopControlLoopIfIdle()
            reply(true)
        }
    }

    func setAllFansAuto(reply: @escaping (Bool) -> Void) {
        queue.async {
            self.forcedTargets.removeAll()
            self.curveFans.removeAll()
            self.fans?.setAllAuto()
            self.stopControlLoopIfIdle()
            reply(true)
        }
    }

    func setGPUMode(_ rawValue: Int, reply: @escaping (Bool) -> Void) {
        queue.async {
            let mode = GPUMode(rawValue: rawValue) ?? .automatic
            reply(self.gpu.setMode(mode))
        }
    }

    func setTurboBoostEnabled(_ enabled: Bool, reply: @escaping (Bool) -> Void) {
        queue.async {
            reply(self.turbo.setTurboEnabled(enabled))
        }
    }

    // MARK: Control loop (re-asserts manual fan targets every 0.5s)

    private func startControlLoopIfNeeded() {
        guard controlTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Re-assert fixed manual targets.
            for (fan, rpm) in self.forcedTargets {
                try? self.fans?.setManual(fan: fan, rpm: rpm)
            }
            // Recompute and apply curve-driven targets.
            for fan in self.curveFans.keys {
                self.applyCurve(fan: fan)
            }
        }
        timer.resume()
        controlTimer = timer
    }

    /// Reads the CPU temperature and drives a curve fan to its computed target.
    private func applyCurve(fan: Int) {
        guard let curve = curveFans[fan],
              let cpu = sensors?.cpuTemperature(),
              let reading = fans?.readFan(fan) else { return }
        let target = curve.targetRPM(cpuTemp: cpu.celsius,
                                     fanMin: reading.minRPM,
                                     fanMax: reading.maxRPM)
        try? fans?.setManual(fan: fan, rpm: target)
    }

    private func stopControlLoopIfIdle() {
        guard forcedTargets.isEmpty, curveFans.isEmpty else { return }
        controlTimer?.cancel()
        controlTimer = nil
    }
}

/// Accepts XPC connections and wires them to the shared service — but only
/// from the authorized app. Since there is no Developer ID to anchor a team
/// requirement, we pin the app's **cdhash**: only a process whose code matches
/// the exact hash recorded at install time may command the root daemon. This
/// closes the privilege-escalation surface of an open root XPC service
/// (important here because SIP is disabled for the Turbo Boost kext).
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard connectionIsAuthorized(newConnection) else {
            helperLog.error("Rejected unauthorized connection (pid \(newConnection.processIdentifier))")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

/// Verifies the connecting process's code satisfies `cdhash H"<pinned>"`.
private func connectionIsAuthorized(_ connection: NSXPCConnection) -> Bool {
    guard let pinned = pinnedCDHash() else {
        helperLog.error("No authorized cdhash on file — denying all connections")
        return false   // fail closed
    }
    guard let peerCode = peerSecCode(for: connection) else { return false }

    var requirement: SecRequirement?
    guard SecRequirementCreateWithString("cdhash H\"\(pinned)\"" as CFString, [], &requirement) == errSecSuccess,
          let requirement else { return false }

    return SecCodeCheckValidity(peerCode, [], requirement) == errSecSuccess
}

/// Resolves the connecting process to a `SecCode`. Prefers the kernel **audit
/// token** — it's immune to the PID-reuse race that affects PID-based lookups,
/// which is why Apple's engineers recommend it — and falls back to the PID only
/// if the token can't be read.
private func peerSecCode(for connection: NSXPCConnection) -> SecCode? {
    var code: SecCode?
    if var token = auditToken(of: connection) {
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size) as CFData
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        if SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess {
            return code
        }
    }
    let attributes = [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)] as CFDictionary
    return SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess ? code : nil
}

/// NSXPCConnection doesn't expose the audit token in its public API; read it
/// via KVC (the documented workaround). Returns nil if unavailable.
private func auditToken(of connection: NSXPCConnection) -> audit_token_t? {
    let key = "auditToken"
    guard connection.responds(to: NSSelectorFromString(key)),
          let value = connection.value(forKey: key) as? NSData,
          value.length == MemoryLayout<audit_token_t>.size else { return nil }
    var token = audit_token_t()
    value.getBytes(&token, length: MemoryLayout<audit_token_t>.size)
    return token
}

private func pinnedCDHash() -> String? {
    guard let raw = try? String(contentsOfFile: kAuthorizedCDHashPath, encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Strong references kept for the lifetime of the daemon process. The
/// listener's `delegate` is a *weak* reference, so without a strong owner
/// here ARC frees the delegate in release builds right after assignment,
/// and every incoming connection is silently rejected (interrupted, 4097).
private var gHelperListener: NSXPCListener?
private var gHelperDelegate: HelperListenerDelegate?

/// Entry point when launched by launchd as the privileged daemon.
func runHelperDaemon() -> Never {
    helperLog.info("starting, registering machServiceName=\(kHelperMachServiceName, privacy: .public)")
    let delegate = HelperListenerDelegate()
    let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
    listener.delegate = delegate
    gHelperDelegate = delegate
    gHelperListener = listener
    listener.resume()
    helperLog.info("listener resumed; entering run loop")
    dispatchMain()
}
