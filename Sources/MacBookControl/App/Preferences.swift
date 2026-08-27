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
        // The battery display grew from a switch into a choice of styles.
        if d.bool(forKey: "menubar.battery"), d.string(forKey: "menubar.batteryStyle") == nil {
            d.set(MenuBarComposer.BatteryStyle.percent.rawValue, forKey: "menubar.batteryStyle")
        }
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

    /// Which sensor the temperature reading comes from. Empty means "whatever
    /// looks like the CPU", which is the right default on a machine whose
    /// sensor names nobody has memorised.
    static var temperatureSensorKey: String {
        get { d.string(forKey: "menubar.sensor") ?? "" }
        set {
            d.set(newValue, forKey: "menubar.sensor")
            Feature.needsDidChange()
        }
    }

    /// Signed watts: plus while charging, minus while the battery carries the
    /// machine.
    static var showPowerInMenuBar: Bool {
        get { d.bool(forKey: "menubar.power") }
        set { d.set(newValue, forKey: "menubar.power") }
    }

    static var batteryStyle: MenuBarComposer.BatteryStyle {
        get { MenuBarComposer.BatteryStyle(rawValue: d.string(forKey: "menubar.batteryStyle") ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: "menubar.batteryStyle") }
    }
    /// Which fields the status item shows, in the order they appear. A list
    /// rather than a set of switches, because the order is the user's.
    static var menuBarItems: [MenuBarComposer.Item] {
        get {
            if let data = d.data(forKey: "menubar.items"),
               let decoded = try? JSONDecoder().decode([MenuBarComposer.Item].self, from: data) {
                return decoded
            }
            // Carried forward from the era of individual switches, so an
            // upgrade shows the same things in a sensible order.
            var items: [MenuBarComposer.Item] = []
            if d.object(forKey: "menubar.temperature") as? Bool ?? true { items.append(.temperature) }
            if d.bool(forKey: "menubar.fan") { items.append(.fan) }
            if (d.string(forKey: "menubar.batteryStyle") ?? "off") != "off" { items.append(.battery) }
            if d.bool(forKey: "menubar.power") { items.append(.power) }
            if (d.string(forKey: "menubar.speedStyle") ?? "off") != "off" { items.append(.cpuSpeed) }
            if (d.string(forKey: "menubar.loadStyle") ?? "off") != "off" { items.append(.cpuLoad) }
            if (d.string(forKey: "menubar.memoryStyle") ?? "off") != "off" { items.append(.memory) }
            if d.object(forKey: "menubar.throttle") as? Bool ?? true { items.append(.throttle) }
            return items.isEmpty ? [.temperature] : items
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            d.set(data, forKey: "menubar.items")
            // What the status item shows decides what is worth reading.
            Feature.needsDidChange()
        }
    }

    /// Which fields carry a caption, by raw value.
    ///
    /// Per field rather than one switch for all of them: two percentages need
    /// telling apart, a temperature does not — "T 55°" says nothing that "55°"
    /// did not, and every caption costs width in a bar that has none to spare.
    static var captionedMenuBarItems: Set<String> {
        get {
            seedCaptionsIfNeeded()
            return Set(d.stringArray(forKey: "menubar.captionedItems") ?? [])
        }
        set { d.set(Array(newValue), forKey: "menubar.captionedItems") }
    }

    static func menuBarItemIsCaptioned(_ item: MenuBarComposer.Item) -> Bool {
        seedCaptionsIfNeeded()
        return captionedMenuBarItems.contains(item.rawValue)
    }

    /// Turns the old single switch into a set, once.
    ///
    /// Reading the fallback on every query was not enough: the first time one
    /// caption was switched off, the set was written starting from empty —
    /// because it did not exist yet — so removing one item removed all of
    /// them. The set has to exist, holding the state that was in force, before
    /// anything can be taken out of it.
    private static func seedCaptionsIfNeeded() {
        guard d.object(forKey: "menubar.captionedItems") == nil else { return }
        let everything = d.bool(forKey: "menubar.captions")
        d.set(everything ? MenuBarComposer.Item.allCases.map(\.rawValue) : [],
              forKey: "menubar.captionedItems")
    }

    static var fanStyle: MenuBarComposer.FanStyle {
        get { MenuBarComposer.FanStyle(rawValue: d.string(forKey: "menubar.fanStyle") ?? "") ?? .rpm }
        set { d.set(newValue.rawValue, forKey: "menubar.fanStyle") }
    }

    static var powerStyle: MenuBarComposer.PowerStyle {
        get { MenuBarComposer.PowerStyle(rawValue: d.string(forKey: "menubar.powerStyle") ?? "") ?? .battery }
        set { d.set(newValue.rawValue, forKey: "menubar.powerStyle") }
    }

    static var batteryIcon: MenuBarComposer.BatteryIcon {
        get { MenuBarComposer.BatteryIcon(rawValue: d.string(forKey: "menubar.batteryIcon") ?? "") ?? .iOS }
        set { d.set(newValue.rawValue, forKey: "menubar.batteryIcon") }
    }
    static var cpuSpeedStyle: MenuBarComposer.SpeedStyle {
        get { MenuBarComposer.SpeedStyle(rawValue: d.string(forKey: "menubar.speedStyle") ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: "menubar.speedStyle") }
    }
    static var cpuLoadStyle: MenuBarComposer.LoadStyle {
        get { MenuBarComposer.LoadStyle(rawValue: d.string(forKey: "menubar.loadStyle") ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: "menubar.loadStyle") }
    }
    static var memoryStyle: MenuBarComposer.MemoryStyle {
        get { MenuBarComposer.MemoryStyle(rawValue: d.string(forKey: "menubar.memoryStyle") ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: "menubar.memoryStyle") }
    }

    static var networkStyle: MenuBarComposer.NetworkStyle {
        get { MenuBarComposer.NetworkStyle(rawValue: d.string(forKey: "menubar.networkStyle") ?? "") ?? .both }
        set { d.set(newValue.rawValue, forKey: "menubar.networkStyle") }
    }

    /// How the settings window arranges itself. Kept apart from `appearance`:
    /// one is light or dark, the other is where the sections live, and a
    /// person who wants a sidebar in the dark is asking for both.
    static var windowLayout: WindowLayout {
        get { WindowLayout(rawValue: d.string(forKey: "window.layout") ?? "") ?? .classic }
        set { d.set(newValue.rawValue, forKey: "window.layout") }
    }

    /// Which appearance the window takes. "System" is the neutral option and
    /// the default: an app that ignores the system setting is the one that
    /// looks out of place.
    static var appearance: String {
        get { d.string(forKey: "window.appearance") ?? "system" }
        set { d.set(newValue, forKey: "window.appearance") }
    }

    // MARK: Cooling

    /// Which sensor the fan curve follows. Empty means whatever looks like the
    /// CPU, which is the right default on a machine whose sensor names nobody
    /// has memorised.
    static var curveSensorKey: String {
        get { d.string(forKey: "cooling.curveSensor") ?? "" }
        set { d.set(newValue, forKey: "cooling.curveSensor") }
    }

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

    /// The flow diagram in the Battery tab. Off by default: it answers a
    /// question not everyone is asking, and it costs vertical space.
    static var showPowerFlow: Bool {
        get { d.bool(forKey: "battery.showFlow") }
        set { d.set(newValue, forKey: "battery.showFlow") }
    }

    /// The power limit the user chose, so it can be put back after a sleep and
    /// at the next launch. Zero means "never set one".
    static var desiredPL1: Double {
        get { d.double(forKey: "power.pl1") }
        set { d.set(newValue, forKey: "power.pl1") }
    }
    static var desiredPL2: Double {
        get { d.double(forKey: "power.pl2") }
        set { d.set(newValue, forKey: "power.pl2") }
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

    static var pointerStore: DeviceScopedStore<PointerProfile> {
        get {
            if let data = d.data(forKey: "pointer.store"),
               let decoded = try? JSONDecoder().decode(DeviceScopedStore<PointerProfile>.self, from: data) {
                return decoded
            }
            // Carry the single-set-of-settings version forward as the
            // defaults, so an upgrade does not quietly stop doing anything.
            var profile = PointerProfile()
            profile.reverseScroll = d.bool(forKey: "pointer.reverseMouse")
            profile.linearScroll = d.bool(forKey: "pointer.linear")
            profile.linesPerNotch = d.object(forKey: "pointer.lines") as? Int ?? 3
            profile.flattenAcceleration = d.bool(forKey: "pointer.flatten")
            profile.accelerationMultiplier = d.object(forKey: "pointer.accel") as? Double ?? 0
            return DeviceScopedStore<PointerProfile>(defaults: profile)
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            d.set(data, forKey: "pointer.store")
        }
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

    static var keyboardStore: DeviceScopedStore<[KeyRemapper.Mapping]> {
        get {
            if let data = d.data(forKey: "keyboard.store"),
               let decoded = try? JSONDecoder().decode(DeviceScopedStore<[KeyRemapper.Mapping]>.self, from: data) {
                return decoded
            }
            // Carry a single-table setup forward as the defaults, so an
            // upgrade does not quietly stop swapping keys.
            var store = DeviceScopedStore<[KeyRemapper.Mapping]>(defaults: [])
            if let data = d.data(forKey: "keyboard.mappings"),
               let legacy = try? JSONDecoder().decode([KeyRemapper.Mapping].self, from: data) {
                store.defaults = legacy
            }
            return store
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            d.set(data, forKey: "keyboard.store")
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
