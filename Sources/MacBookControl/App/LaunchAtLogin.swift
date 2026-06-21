import Foundation

/// Launch-at-login via a per-user LaunchAgent. Works uniformly on macOS 11–26
/// without code-signing requirements (unlike SMAppService, which is 13+ and
/// fussy about ad-hoc signatures). Toggling writes / removes the agent plist;
/// it takes effect at the next login (we don't load it now, to avoid spawning
/// a duplicate of the already-running app).
enum LaunchAtLogin {
    static let label = "com.n0ctal.macbookcontrol.login"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// The executable to launch at login. Prefer the copy installed in
    /// /Applications (the canonical location) over whichever bundle happens to
    /// be running — there may be a dev build with the same bundle id.
    private static var loginExecutablePath: String? {
        let installed = "/Applications/Zephyr.app/Contents/MacOS/Zephyr"
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        return Bundle.main.executableURL?.path
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            guard let executable = loginExecutablePath else { return }
            let directory = plistURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
            ]
            (plist as NSDictionary).write(to: plistURL, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}
