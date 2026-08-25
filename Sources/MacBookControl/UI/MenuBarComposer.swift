import AppKit
import Foundation

/// Builds what the status item shows.
///
/// Every part is independent because the useful combination differs per
/// person: some want a thermometer, some want to watch the battery drain in
/// watts, few want all of it. The order is fixed rather than configurable —
/// a menu bar whose fields move around is harder to read at a glance than one
/// that is slightly wrong.
enum MenuBarComposer {

    enum BatteryStyle: String, CaseIterable {
        case off, percent, icon, iconAndPercent
        var label: String {
            switch self {
            case .off: return "Off"
            case .percent: return "Percentage"
            case .icon: return "Icon"
            case .iconAndPercent: return "Icon and percentage"
            }
        }
    }

    enum SpeedStyle: String, CaseIterable {
        case off, percent, frequency
        var label: String {
            switch self {
            case .off: return "Off"
            case .percent: return "Percentage"
            case .frequency: return "Frequency"
            }
        }
    }

    enum LoadStyle: String, CaseIterable {
        case off, total, perThread
        var label: String {
            switch self {
            case .off: return "Off"
            case .total: return "Total"
            case .perThread: return "A bar per thread"
            }
        }
    }

    enum MemoryStyle: String, CaseIterable {
        case off, percent, used
        var label: String {
            switch self {
            case .off: return "Off"
            case .percent: return "Percentage"
            case .used: return "Gigabytes used"
            }
        }
    }

    struct Content {
        var image: NSImage?
        var title: String
    }

    static func compose(telemetry: Telemetry) -> Content {
        var parts: [String] = []
        var image: NSImage?

        if Preferences.showTemperatureInMenuBar, let reading = chosenSensor(telemetry) {
            parts.append(String(format: "%.0f°", reading.celsius))
        }

        if Preferences.showFanInMenuBar, let fastest = telemetry.fans.map(\.actualRPM).max() {
            parts.append("\(fastest) rpm")
        }

        let battery = telemetry.battery
        switch Preferences.batteryStyle {
        case .off: break
        case .percent:
            if let battery = battery { parts.append("\(battery.percent) %") }
        case .icon:
            image = batteryImage(battery)
        case .iconAndPercent:
            image = batteryImage(battery)
            if let battery = battery { parts.append("\(battery.percent) %") }
        }

        // Signed on purpose: the sign is the whole message. A plus means the
        // battery is filling, a minus means it is carrying the machine, and
        // the number alone cannot say which.
        if Preferences.showPowerInMenuBar, let watts = battery?.power?.batteryWatts, abs(watts) >= 0.1 {
            parts.append(String(format: "%+.1f W", watts))
        }

        switch Preferences.cpuSpeedStyle {
        case .off: break
        case .percent:
            if let limit = telemetry.thermal?.speedLimitPercent { parts.append("\(limit) %") }
        case .frequency:
            if let limit = telemetry.thermal?.speedLimitPercent, SystemLoad.nominalHz > 0 {
                let ghz = Double(SystemLoad.nominalHz) / 1e9 * Double(limit) / 100
                parts.append(String(format: "%.1f GHz", ghz))
            }
        }

        switch Preferences.cpuLoadStyle {
        case .off: break
        case .total:
            if let load = telemetry.load { parts.append("\(Int((load.total * 100).rounded())) %") }
        case .perThread:
            if let load = telemetry.load, let bars = threadBars(load.perCore) {
                // Only one image fits on a status item, so the battery icon
                // wins if both were asked for — it is the one people glance at.
                if image == nil { image = bars }
            }
        }

        switch Preferences.memoryStyle {
        case .off: break
        case .percent:
            if let load = telemetry.load {
                parts.append("\(Int((load.memoryFraction * 100).rounded())) %")
            }
        case .used:
            if let load = telemetry.load {
                parts.append(String(format: "%.1f GB", Double(load.memoryUsed) / 1_073_741_824))
            }
        }

        if Preferences.showThrottleInMenuBar,
           let thermal = telemetry.thermal, thermal.isThrottling,
           let limit = thermal.speedLimitPercent,
           Preferences.cpuSpeedStyle == .off {
            // Suppressed when the speed is already displayed: the same number
            // twice reads as a bug.
            parts.append("↓\(limit) %")
        }

        let title = parts.joined(separator: "  ")
        return Content(image: image,
                       title: title.isEmpty && image == nil ? "Zephyr" : title)
    }

    /// The sensor the user picked, falling back to whatever is hottest so the
    /// display never silently empties when a chosen key disappears.
    static func chosenSensor(_ telemetry: Telemetry) -> TemperatureReading? {
        let key = Preferences.temperatureSensorKey
        if !key.isEmpty, let match = telemetry.temperatures.first(where: { $0.key == key }) {
            return match
        }
        return telemetry.cpuTemperature
    }

    // MARK: Drawing

    private static func batteryImage(_ battery: BatteryStatus?) -> NSImage? {
        guard let battery = battery else { return nil }
        let name: String
        if battery.isCharging {
            name = "battery.100.bolt"
        } else {
            switch battery.percent {
            case ..<13: name = "battery.0"
            case ..<38: name = "battery.25"
            case ..<63: name = "battery.50"
            case ..<88: name = "battery.75"
            default: name = "battery.100"
            }
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Battery")
        image?.isTemplate = true
        return image
    }

    /// A bar per logical core, the way a system monitor draws it. Sixteen
    /// numbers would not fit and could not be read; sixteen bars can.
    private static func threadBars(_ load: [Double]) -> NSImage? {
        guard !load.isEmpty else { return nil }
        let barWidth: CGFloat = 2
        let gap: CGFloat = 1
        let height: CGFloat = 14
        let width = CGFloat(load.count) * (barWidth + gap)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.black.setFill()
        for (index, value) in load.enumerated() {
            let clamped = max(0.04, min(1, value))   // a visible stub at idle
            let x = CGFloat(index) * (barWidth + gap)
            NSRect(x: x, y: 0, width: barWidth, height: height * clamped).fill()
        }
        image.unlockFocus()
        // Template so macOS inverts it for light and dark menu bars.
        image.isTemplate = true
        return image
    }
}
