import Foundation

/// Why the privileged helper is not answering.
///
/// The helper accepts connections only from the exact binary whose code
/// signature was recorded when it was installed. That is deliberate — it is an
/// XPC service running as root on a machine with SIP disabled, and an open one
/// would be a way in. But Zephyr is signed ad-hoc, so **every rebuild changes
/// that signature**, and an updated app is a stranger to the helper it shipped
/// with.
///
/// The two failures look identical from the app — no answer — and need
/// opposite advice, so they are told apart here rather than lumped into
/// "install the helper".
enum HelperState: Equatable {
    case working(version: String)
    /// Installed, running, and refusing us because the app was rebuilt.
    case notAuthorized
    case notInstalled

    static let daemonPlist = "/Library/LaunchDaemons/com.n0ctal.macbookcontrol.helper.plist"

    static func current(_ client: HelperClient) -> HelperState {
        from(version: client.version(),
             daemonInstalled: FileManager.default.fileExists(atPath: daemonPlist))
    }

    /// The decision itself, separated from the two lookups so it can be
    /// checked without a helper or a filesystem.
    static func from(version: String?, daemonInstalled: Bool) -> HelperState {
        if let version = version { return .working(version: version) }
        return daemonInstalled ? .notAuthorized : .notInstalled
    }

    var isWorking: Bool { if case .working = self { return true }; return false }

    var summary: String {
        switch self {
        case .working(let version): return "Helper \(version) running"
        case .notAuthorized: return "Helper installed but not authorised"
        case .notInstalled: return "Helper not installed"
        }
    }

    var explanation: String? {
        switch self {
        case .working:
            return nil
        case .notAuthorized:
            return """
            The helper only accepts the exact copy of Zephyr that was present \
            when it was installed, and updating the app changes that. Nothing \
            that needs root works until it is told about the new copy — fans, \
            graphics, Turbo Boost, the charge ceiling and the power limit all \
            go quiet. Re-run the installer; it takes a moment and asks for a \
            password once.
            """
        case .notInstalled:
            return """
            Fans, graphics, Turbo Boost, the charge ceiling and the power limit \
            all write to hardware, which needs root. Run the installer once.
            """
        }
    }

    /// Built from the running bundle so it is right wherever Zephyr lives.
    static var installCommand: String {
        let script = Bundle.main.resourceURL?
            .appendingPathComponent("scripts/install-helper.sh").path
            ?? "/Applications/Zephyr.app/Contents/Resources/scripts/install-helper.sh"
        return "sudo \"\(script)\""
    }
}
