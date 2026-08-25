import Foundation

/// Everything the app remembers between launches.
///
/// Two layers: `featureEnabled` is generic so adding a tab needs no change
/// here, while the per-feature values stay explicit properties — when
/// wondering what the app stores, this file is the whole answer.
enum Preferences {
    private static let d = UserDefaults.standard

    /// Carries the 1.2.0 keys forward once.
    ///
    /// Without this the charge ceiling and the menu-bar choices silently reset
    /// on upgrade, and a battery quietly starts charging to 100 % again — a
    /// setting failing open is worse than one that was never offered.
    static func migrateLegacyKeys() {
        guard !d.bool(forKey: "migrated.1.3") else { return }
        let moves: [(String, String)] = [
            ("chargeLimitPercent", "battery.limitPercent"),
            ("batteryInMenuBar", "menubar.battery"),
            ("throttleInMenuBar", "menubar.throttle"),
        ]
        for (old, new) in moves where d.object(forKey: new) == nil {
            if let value = d.object(forKey: old) { d.set(value, forKey: new) }
        }
        // The old build had no per-feature switches: anything the user had
        // actually turned on becomes an enabled feature, so upgrading does not
        // silently stop doing what it was doing.
        if d.bool(forKey: "chargeLimitEnabled") { setFeatureEnabled("battery", true) }
        d.set(true, forKey: "migrated.1.3")
    }

    // MARK: Per-feature enable

    private static func enableKey(_ id: String) -> String { "feature.\(id).enabled" }

    static func featureEnabled(_ id: String) -> Bool {
        d.bool(forKey: enableKey(id))
    }

    static func setFeatureEnabled(_ id: String, _ enabled: Bool) {
        d.set(enabled, forKey: enableKey(id))
    }

    // MARK: Menu bar

    /// What the status item spells out next to the icon. Each part is
    /// independent because the useful combination differs per person: some
    /// want a thermometer, some want the battery, few want everything.
    static var showTemperatureInMenuBar: Bool {
        get { d.object(forKey: "menubar.temperature") as? Bool ?? true }
        set { d.set(newValue, forKey: "menubar.temperature") }
    }
    static var showFanInMenuBar: Bool {
        get { d.bool(forKey: "menubar.fan") }
        set { d.set(newValue, forKey: "menubar.fan") }
    }
    static var showBatteryInMenuBar: Bool {
        get { d.bool(forKey: "menubar.battery") }
        set { d.set(newValue, forKey: "menubar.battery") }
    }
    /// Off by default: the mark only ever appears when something is wrong, and
    /// not everyone wants to watch for it.
    static var showThrottleInMenuBar: Bool {
        get { d.object(forKey: "menubar.throttle") as? Bool ?? true }
        set { d.set(newValue, forKey: "menubar.throttle") }
    }

    // MARK: Cooling

    /// Manual RPM per fan index, or nil for the curve. Stored as a dictionary
    /// so a machine with a different fan count doesn't lose the other's value.
    static var manualFanRPM: [Int: Int] {
        get {
            guard let raw = d.dictionary(forKey: "cooling.manualRPM") as? [String: Int] else { return [:] }
            return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
            d.set(raw, forKey: "cooling.manualRPM")
        }
    }

    /// The temperature at which the curve starts lifting the fans, and the one
    /// where it reaches full speed.
    static var curveMinTemp: Double {
        get { d.object(forKey: "cooling.curveMin") as? Double ?? 55 }
        set { d.set(newValue, forKey: "cooling.curveMin") }
    }
    static var curveMaxTemp: Double {
        get { d.object(forKey: "cooling.curveMax") as? Double ?? 85 }
        set { d.set(newValue, forKey: "cooling.curveMax") }
    }
    static var coolingMode: String {
        get { d.string(forKey: "cooling.mode") ?? "curve" }
        set { d.set(newValue, forKey: "cooling.mode") }
    }

    // MARK: Battery

    static var chargeLimitPercent: Int {
        get { d.object(forKey: "battery.limitPercent") as? Int ?? 80 }
        set { d.set(newValue, forKey: "battery.limitPercent") }
    }

    /// Last answer from the expensive kext-state query, so a launch can show
    /// something truthful before the background read lands.
    static var lastKnownTurboDisabled: Bool {
        get { d.bool(forKey: "power.turboDisabled") }
        set { d.set(newValue, forKey: "power.turboDisabled") }
    }

    // MARK: Graphics

    static var gpuMode: Int {
        get { d.object(forKey: "graphics.mode") as? Int ?? GPUMode.automatic.rawValue }
        set { d.set(newValue, forKey: "graphics.mode") }
    }

    // MARK: Pointer

    static var reverseMouseScroll: Bool {
        get { d.bool(forKey: "pointer.reverseMouse") }
        set { d.set(newValue, forKey: "pointer.reverseMouse") }
    }
    static var reverseTrackpadScroll: Bool {
        get { d.bool(forKey: "pointer.reverseTrackpad") }
        set { d.set(newValue, forKey: "pointer.reverseTrackpad") }
    }
    static var linearScrolling: Bool {
        get { d.bool(forKey: "pointer.linear") }
        set { d.set(newValue, forKey: "pointer.linear") }
    }
    static var scrollLinesPerNotch: Int {
        get { d.object(forKey: "pointer.lines") as? Int ?? 3 }
        set { d.set(newValue, forKey: "pointer.lines") }
    }

    static var flattenPointerAcceleration: Bool {
        get { d.bool(forKey: "pointer.flatten") }
        set { d.set(newValue, forKey: "pointer.flatten") }
    }
    /// 1.0 is what the device shipped with, 0 removes the curve entirely.
    static var pointerAccelerationMultiplier: Double {
        get { d.object(forKey: "pointer.accel") as? Double ?? 0 }
        set { d.set(newValue, forKey: "pointer.accel") }
    }

    /// Acceleration values as found before Zephyr changed them. See
    /// `PointerAcceleration` for why these outlive the process.
    static var pointerOriginals: [String: Int] {
        get { (d.dictionary(forKey: "pointer.originals") as? [String: Int]) ?? [:] }
        set { newValue.isEmpty ? d.removeObject(forKey: "pointer.originals")
                               : d.set(newValue, forKey: "pointer.originals") }
    }

    // MARK: Keyboard

    static var keyMappings: [KeyRemapper.Mapping] {
        get {
            guard let data = d.data(forKey: "keyboard.mappings"),
                  let decoded = try? JSONDecoder().decode([KeyRemapper.Mapping].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            d.set(data, forKey: "keyboard.mappings")
        }
    }

    /// Whether a mapping is currently written to the hardware. Survives the
    /// process so a killed run can be cleaned up at the next launch.
    static var keyboardMappingApplied: Bool {
        get { d.bool(forKey: "keyboard.applied") }
        set { d.set(newValue, forKey: "keyboard.applied") }
    }

    // MARK: Profiles

    static var profiles: [Profile] {
        get {
            guard let data = d.data(forKey: "profiles.list"),
                  let decoded = try? JSONDecoder().decode([Profile].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            d.set(data, forKey: "profiles.list")
        }
    }

    // MARK: Awake

    /// Whether keeping the machine awake also keeps the screen lit. Off means
    /// the display may sleep while the work underneath keeps running.
    static var awakeKeepsDisplayOn: Bool {
        get { d.object(forKey: "awake.display") as? Bool ?? true }
        set { d.set(newValue, forKey: "awake.display") }
    }
    /// Minutes after which the assertion drops itself, or 0 for indefinite.
    static var awakeDurationMinutes: Int {
        get { d.integer(forKey: "awake.minutes") }
        set { d.set(newValue, forKey: "awake.minutes") }
    }
    /// Hold the machine awake whenever the lid is shut and power is attached.
    static var awakeWhenLidClosed: Bool {
        get { d.bool(forKey: "awake.lidClosed") }
        set { d.set(newValue, forKey: "awake.lidClosed") }
    }
}
