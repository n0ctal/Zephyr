import Foundation

/// App-side wrapper around the XPC connection to the privileged daemon.
/// All control actions (fan speed, GPU policy) flow through here; if the
/// helper is not installed, calls fail gracefully via the error handler.
final class HelperClient {
    static let shared = HelperClient()

    private var connection: NSXPCConnection?
    /// XPC handlers arrive on arbitrary queues; without this lock a late handler
    /// for the old connection nils out the live one, which then leaks.
    private let lock = NSLock()

    private func proxy(_ errorHandler: @escaping (Error) -> Void) -> HelperProtocol? {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let newConnection = NSXPCConnection(
                machServiceName: kHelperMachServiceName,
                options: .privileged
            )
            newConnection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            let drop: () -> Void = { [weak self, weak newConnection] in
                guard let self, let newConnection else { return }
                self.lock.lock()
                // Only clear it if this is still the same connection.
                if self.connection === newConnection { self.connection = nil }
                self.lock.unlock()
            }
            newConnection.invalidationHandler = drop
            newConnection.interruptionHandler = drop
            newConnection.resume()
            connection = newConnection
        }
        return connection?.remoteObjectProxyWithErrorHandler(errorHandler) as? HelperProtocol
    }

    // MARK: Convenience

    /// Returns the running daemon's version, or nil if it is not reachable.
    func version(timeout: TimeInterval = 5) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        let helper = proxy { _ in semaphore.signal() }
        helper?.getVersion { value in
            result = value
            semaphore.signal()
        }
        if helper == nil { return nil }
        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    var isInstalled: Bool { version() != nil }

    /// Synchronously fetches each fan's mode ("auto"/"manual"/"curve") from the
    /// daemon — the authoritative source, so the menu is correct after a restart.
    func fanModes(timeout: TimeInterval = 2) -> [String] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String] = []
        let helper = proxy { _ in semaphore.signal() }
        helper?.fanModes { modes in
            result = modes
            semaphore.signal()
        }
        if helper == nil { return [] }
        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    func setFanManual(fan: Int, rpm: Int) {
        proxy { _ in }?.setFanManual(fan: fan, rpm: rpm) { _ in }
    }

    func setFanCurve(fan: Int, curve: FanCurve = .default) {
        proxy { _ in }?.setFanCurve(fan: fan,
                                    minTemp: Int(curve.minTemp),
                                    maxTemp: Int(curve.maxTemp)) { _ in }
    }

    func setFanAuto(fan: Int) {
        proxy { _ in }?.setFanAuto(fan: fan) { _ in }
    }

    func setAllFansAuto() {
        proxy { _ in }?.setAllFansAuto { _ in }
    }

    func setGPUMode(_ mode: GPUMode) {
        proxy { _ in }?.setGPUMode(mode.rawValue) { _ in }
    }

    func setTurboBoostEnabled(_ enabled: Bool) {
        proxy { _ in }?.setTurboBoostEnabled(enabled) { _ in }
    }

    func reapplyTurboAfterWake() {
        proxy { _ in }?.reapplyTurboAfterWake { _ in }
    }
}
