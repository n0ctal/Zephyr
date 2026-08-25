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

    /// Which battery drawing to use.
    enum BatteryIcon: String, CaseIterable {
        case iOS, system, bar, ring
        var label: String {
            switch self {
            case .iOS: return "iPhone style"
            case .system: return "System battery"
            case .bar: return "Filled bar"
            case .ring: return "Ring"
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
            // The iPhone puts the number inside the battery; every other icon
            // here needs it written beside. Printing it twice would be the
            // obvious bug.
            let inside = Preferences.batteryIcon == .iOS
            image = batteryImage(battery, showingPercentage: inside)
            if !inside, let battery = battery { parts.append("\(battery.percent) %") }
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
                // A status item carries one image, so both drawings are joined
                // into it. Dropping one because the other was there made a
                // deliberate choice silently do nothing.
                image = join(image, bars)
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

    static func batteryImage(_ battery: BatteryStatus?, showingPercentage: Bool = false) -> NSImage? {
        guard let battery = battery else { return nil }
        switch Preferences.batteryIcon {
        case .iOS: return iOSBattery(battery, showingPercentage: showingPercentage)
        case .system: return systemBatteryGlyph(battery)
        case .bar: return drawnBattery(battery, rounded: false)
        case .ring: return drawnRing(battery)
        }
    }

    private static func systemBatteryGlyph(_ battery: BatteryStatus) -> NSImage? {
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

    /// The iPhone battery, iOS 27 style.
    ///
    /// The shape changed with that release and the difference matters when
    /// drawing it: there is no outline any more. The pill is solid, the filled
    /// part carries the colour and the *empty* part is grey rather than
    /// transparent — so a half-full battery is half coloured and half grey,
    /// not a coloured stub inside an outline.
    ///
    /// Colours: green while charging, yellow in Low Power Mode, red at twenty
    /// percent or less with nothing plugged in, otherwise the ordinary label
    /// colour. Red was not asked for, but leaving it out would make this
    /// *nearly* the iPhone.
    ///
    /// A coloured image cannot be a template one: macOS repaints templates to
    /// match the menu bar and the colour would be thrown away. So the neutral
    /// state stays a template and adapts to a light or dark bar on its own,
    /// while the coloured states opt out and carry their own paint.
    /// Which colour the fill takes. Separated from the drawing so the rule
    /// can be checked without inspecting pixels — the rule is the part that
    /// can be wrong in a way nobody notices until the charger is unplugged.
    enum FillRole: Equatable {
        case charging, lowPower, critical, neutral

        var colour: NSColor? {
            switch self {
            case .charging: return .systemGreen
            case .lowPower: return .systemYellow
            case .critical: return .systemRed
            case .neutral: return nil   // template: painted by the system
            }
        }
    }

    static func fillRole(percent: Int, isCharging: Bool,
                         isPluggedIn: Bool, lowPower: Bool) -> FillRole {
        // Order matters and follows the phone: charging wins over everything,
        // Low Power Mode is yellow at any level, and red is only for a battery
        // that is nearly empty with nothing plugged in.
        if isCharging { return .charging }
        if lowPower { return .lowPower }
        if percent <= 20 && !isPluggedIn { return .critical }
        return .neutral
    }

    static var isLowPowerMode: Bool {
        if #available(macOS 12.0, *) { return ProcessInfo.processInfo.isLowPowerModeEnabled }
        return false
    }

    /// Set only by the icon dump, so a state the machine is not currently in
    /// can still be drawn and compared against a reference.
    static var forcedFillRole: FillRole?

    private static func iOSBattery(_ battery: BatteryStatus, showingPercentage: Bool) -> NSImage {
        let height: CGFloat = 13
        // Wider when it has to hold a number, as on the phone.
        let bodyWidth: CGFloat = showingPercentage ? 30 : 22
        let capWidth: CGFloat = 2
        let capGap: CGFloat = 1.2
        let size = NSSize(width: bodyWidth + capGap + capWidth, height: height)
        let fraction = max(0, min(1, Double(battery.percent) / 100))

        let fill = (Self.forcedFillRole
            ?? fillRole(percent: battery.percent, isCharging: battery.isCharging,
                        isPluggedIn: battery.isPluggedIn, lowPower: isLowPowerMode)).colour
        let paint = fill ?? NSColor.black
        // The empty part. On a template image this has to be an alpha level
        // rather than a grey, because the system repaints every opaque pixel.
        let empty = fill == nil ? NSColor.black.withAlphaComponent(0.35)
                                : NSColor.systemGray.withAlphaComponent(0.55)

        let image = NSImage(size: size)
        image.lockFocus()

        let body = NSRect(x: 0, y: 0, width: bodyWidth, height: height)
        let radius = height * 0.34
        let pill = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        empty.setFill()
        pill.fill()

        if fraction > 0 {
            // Clipped to the pill so the fill keeps the rounded ends instead
            // of squaring off where it stops.
            NSGraphicsContext.saveGraphicsState()
            pill.addClip()
            paint.setFill()
            NSRect(x: 0, y: 0, width: bodyWidth * CGFloat(fraction), height: height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // The cap follows the empty colour until the battery is full, which is
        // what the phone does.
        (fraction >= 1 ? paint : empty).setFill()
        NSBezierPath(roundedRect: NSRect(x: bodyWidth + capGap, y: height / 2 - 2,
                                         width: capWidth, height: 4),
                     xRadius: 1, yRadius: 1).fill()

        if showingPercentage {
            // Punched through rather than painted on: the digits then read
            // against both the filled part and the grey remainder, and against
            // a light or dark menu bar, without picking a colour for each case.
            let text = "\(battery.percent)" as NSString
            let font = NSFont.systemFont(ofSize: 9, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let measured = text.size(withAttributes: attributes)
            let origin = NSPoint(x: (bodyWidth - measured.width) / 2,
                                 y: (height - measured.height) / 2)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            text.draw(at: origin, withAttributes: attributes)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }

        image.unlockFocus()
        image.isTemplate = (fill == nil)
        return image
    }

    /// A battery outline filled to the level, drawn rather than taken from the
    /// symbol set so the fill is continuous instead of stepping between five
    /// stock images.
    private static func drawnBattery(_ battery: BatteryStatus, rounded: Bool) -> NSImage {
        let size = NSSize(width: 24, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let body = NSRect(x: 0.5, y: 0.5, width: 19, height: 11)
        let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1
        outline.stroke()

        // The nub, so it reads as a battery and not as a progress bar.
        NSBezierPath(roundedRect: NSRect(x: 20.5, y: 4, width: 2.5, height: 4),
                     xRadius: 1, yRadius: 1).fill()

        let fraction = max(0, min(1, Double(battery.percent) / 100))
        let inset = body.insetBy(dx: 2, dy: 2)
        if fraction > 0 {
            NSRect(x: inset.minX, y: inset.minY,
                   width: inset.width * CGFloat(fraction), height: inset.height).fill()
        }
        if battery.isCharging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
            bolt.isTemplate = true
            bolt.draw(in: NSRect(x: 6, y: 1, width: 8, height: 10),
                      from: .zero, operation: .xor, fraction: 1)
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// A ring that fills clockwise. Reads as a proportion without a number.
    private static func drawnRing(_ battery: BatteryStatus) -> NSImage {
        let side: CGFloat = 15
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.black.setStroke()

        let centre = NSPoint(x: side / 2, y: side / 2)
        let radius = side / 2 - 1.5

        let track = NSBezierPath()
        track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 1
        NSColor.black.withAlphaComponent(0.3).setStroke()
        track.stroke()

        let fraction = max(0, min(1, Double(battery.percent) / 100))
        if fraction > 0 {
            let arc = NSBezierPath()
            // Clockwise from the top, which is how a gauge is read.
            arc.appendArc(withCenter: centre, radius: radius,
                          startAngle: 90, endAngle: 90 - CGFloat(fraction * 360), clockwise: true)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
        }
        if battery.isCharging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
            bolt.isTemplate = true
            bolt.draw(in: NSRect(x: side / 2 - 3, y: side / 2 - 4, width: 6, height: 8),
                      from: .zero, operation: .sourceOver, fraction: 1)
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Puts two drawings side by side so a status item can carry both.
    static func join(_ left: NSImage?, _ right: NSImage) -> NSImage {
        guard let left = left else { return right }
        let gap: CGFloat = 4
        let height = max(left.size.height, right.size.height)
        let size = NSSize(width: left.size.width + gap + right.size.width, height: height)
        let combined = NSImage(size: size)
        combined.lockFocus()
        left.draw(in: NSRect(x: 0, y: (height - left.size.height) / 2,
                             width: left.size.width, height: left.size.height))
        right.draw(in: NSRect(x: left.size.width + gap, y: (height - right.size.height) / 2,
                              width: right.size.width, height: right.size.height))
        combined.unlockFocus()
        // Only a template if both halves were: forcing it would repaint a
        // coloured battery to match the menu bar and lose the colour.
        combined.isTemplate = left.isTemplate && right.isTemplate
        return combined
    }

    /// A bar per logical core, the way a system monitor draws it. Sixteen
    /// numbers would not fit and could not be read; sixteen bars can.
    static func threadBars(_ load: [Double]) -> NSImage? {
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
