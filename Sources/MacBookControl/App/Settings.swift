import Foundation

/// The handful of user choices that must survive a restart.
///
/// Deliberately tiny and untyped-key-free: every setting is a property here, so
/// there is one place to look when wondering what the app remembers.
enum Settings {
    private static let d = UserDefaults.standard

    /// Show the firmware's CPU speed cap in the menu (and mark the status bar
    /// when it is actively holding the machine back).
    static var throttlingMonitorEnabled: Bool {
        get { d.object(forKey: "throttlingMonitor") as? Bool ?? true }
        set { d.set(newValue, forKey: "throttlingMonitor") }
    }

    /// Whether the charge ceiling is in force. Kept separately from the percent
    /// so turning it off and on again returns to the same number.
    static var chargeLimitEnabled: Bool {
        get { d.bool(forKey: "chargeLimitEnabled") }
        set { d.set(newValue, forKey: "chargeLimitEnabled") }
    }

    /// Show the battery percentage next to the temperature in the menu bar.
    static var batteryInMenuBar: Bool {
        get { d.bool(forKey: "batteryInMenuBar") }
        set { d.set(newValue, forKey: "batteryInMenuBar") }
    }

    /// Mark the menu bar while the firmware is capping the CPU. Off by default
    /// because the mark only ever appears when something is wrong, and some
    /// people would rather not watch for it.
    static var throttleInMenuBar: Bool {
        get { d.object(forKey: "throttleInMenuBar") as? Bool ?? true }
        set { d.set(newValue, forKey: "throttleInMenuBar") }
    }

    /// The ceiling to apply when enabled. 80 is the usual longevity compromise.
    static var chargeLimitPercent: Int {
        get { d.object(forKey: "chargeLimitPercent") as? Int ?? 80 }
        set { d.set(newValue, forKey: "chargeLimitPercent") }
    }
}
