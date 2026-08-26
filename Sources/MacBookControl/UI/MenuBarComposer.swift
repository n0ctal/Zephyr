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

    /// Fans in revolutions or as a share of their own range. A percentage
    /// means something without knowing that this machine idles at 1800 and
    /// tops out at 5600, which almost nobody does.
    enum FanStyle: String, CaseIterable {
        case rpm, percent
        var label: String { self == .rpm ? "Revolutions" : "Percentage" }
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

    /// Which of the three powers the field shows. The machine reports all
    /// three and they answer different questions: what the battery is doing,
    /// what the machine is drawing, what the charger is supplying.
    enum PowerStyle: String, CaseIterable {
        case battery, system, adapter
        var label: String {
            switch self {
            case .battery: return "Battery flow"
            case .system: return "System draw"
            case .adapter: return "From the charger"
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

    /// Down, up, or both. Both is what a network field is usually for —
    /// asking whether the upload finished is the other half of asking whether
    /// the download did — but it costs twice the width.
    enum NetworkStyle: String, CaseIterable {
        case off, both, download, upload
        var label: String {
            switch self {
            case .off: return "Off"
            case .both: return "Down and up"
            case .download: return "Download only"
            case .upload: return "Upload only"
            }
        }
    }

    /// One thing the status item can show. The order is the user's, so this is
    /// a list rather than a set of switches.
    enum Item: String, CaseIterable, Codable {
        case temperature, fan, battery, power, cpuSpeed, cpuLoad, memory, network, throttle

        var title: String {
            switch self {
            case .temperature: return "Temperature"
            case .fan: return "Fan speed"
            case .battery: return "Battery"
            case .power: return "Power in watts"
            case .cpuSpeed: return "CPU speed"
            case .cpuLoad: return "CPU load"
            case .memory: return "Memory"
            case .network: return "Network speed"
            case .throttle: return "Throttle mark"
            }
        }

        /// Shown when captions are on. Short because the menu bar is not a
        /// place for sentences — but "4 %" beside "57 %" is unreadable without
        /// them, which is the whole reason they exist.
        var caption: String {
            switch self {
            // No caption: the degree sign already says what this is, and a
            // letter in front of it only takes width.
            case .temperature: return ""
            case .fan: return "FAN"
            case .battery: return "BAT"
            // No caption, for the same reason temperature has none: the unit
            // is already written after the number, and "W 23.5 W" is what a
            // label on top of a unit actually looks like.
            case .power: return ""
            case .cpuSpeed: return "CPU"
            case .cpuLoad: return "LOAD"
            case .memory: return "RAM"
            // No caption: the arrows already say which direction is which,
            // and they say it in less width than the word would.
            case .network: return ""
            case .throttle: return ""
            }
        }

        /// The settings list in menu-bar order: what is shown, in the order it
        /// is shown, then everything that is not.
        ///
        /// Pure and separate so it can be checked. A list that disagrees with
        /// the menu bar is not a crash — it is a row that quietly stays put
        /// while its number changes, which nothing but a test or an eye
        /// will catch.
        static func listOrder(shown: [Item]) -> [Item] {
            shown + allCases.filter { !shown.contains($0) }
        }
    }

    struct Content {
        var image: NSImage?
        var title: String
    }

    /// A piece of the line: either text or a drawing.
    private enum Segment {
        case text(String)
        case drawing(NSImage)
    }

    /// The whole status item is drawn as one image.
    ///
    /// The obvious way — a system image plus a title — cannot work here: the
    /// image is always leftmost whatever order the fields are in, so the
    /// battery icon jumped to the front while the battery percentage stayed
    /// where it was put. Drawing everything means the order, the spacing and
    /// the captions are all ours.
    ///
    /// The cost is that the image cannot be a template one, because a template
    /// is repainted as a flat mask and the coloured battery would lose its
    /// colour. So the text colour is chosen from the menu bar's own appearance
    /// instead, passed in by the caller.
    static func compose(telemetry: Telemetry, darkMenuBar: Bool) -> Content {
        var segments: [Segment] = []
        for item in Preferences.menuBarItems {
            segments.append(contentsOf: render(item, telemetry: telemetry, darkMenuBar: darkMenuBar))
        }
        guard !segments.isEmpty else { return Content(image: nil, title: "Zephyr") }
        return Content(image: layout(segments, darkMenuBar: darkMenuBar), title: "")
    }

    private static func render(_ item: Item, telemetry: Telemetry, darkMenuBar: Bool) -> [Segment] {
        let caption = Preferences.menuBarItemIsCaptioned(item) && !item.caption.isEmpty
            ? item.caption + " " : ""
        func text(_ value: String) -> [Segment] { [.text(caption + value)] }

        switch item {
        case .temperature:
            guard let reading = chosenSensor(telemetry) else { return [] }
            return text(String(format: "%.0f°", reading.celsius))

        case .fan:
            guard let fan = telemetry.fans.max(by: { $0.actualRPM < $1.actualRPM }) else { return [] }
            switch Preferences.fanStyle {
            case .rpm:
                return text("\(fan.actualRPM) rpm")
            case .percent:
                return text("\(Int((fan.loadFraction * 100).rounded()))%")
            }

        case .battery:
            guard let battery = telemetry.battery else { return [] }
            switch Preferences.batteryStyle {
            case .off:
                return []
            case .percent:
                return text("\(battery.percent)%")
            case .icon:
                guard let icon = batteryImage(battery, darkMenuBar: darkMenuBar) else { return [] }
                return caption.isEmpty ? [.drawing(icon)] : [.text(caption.trimmingCharacters(in: .whitespaces)), .drawing(icon)]
            case .iconAndPercent:
                // The iPhone puts the number inside the battery; every other
                // icon needs it written beside. Printing both would be the
                // obvious bug.
                let inside = Preferences.batteryIcon == .iOS
                guard let icon = batteryImage(battery, showingPercentage: inside,
                                              darkMenuBar: darkMenuBar) else { return [] }
                var pieces: [Segment] = []
                if !caption.isEmpty { pieces.append(.text(caption.trimmingCharacters(in: .whitespaces))) }
                pieces.append(.drawing(icon))
                if !inside { pieces.append(.text("\(battery.percent) %")) }
                return pieces
            }

        case .power:
            guard let draw = telemetry.battery?.power else { return [] }
            switch Preferences.powerStyle {
            case .battery:
                // Signed on purpose: the sign is the whole message. A plus
                // means the battery is filling, a minus that it is carrying
                // the machine, and the number alone cannot say which.
                //
                // Shown even at zero. A field switched on that then displays
                // nothing reads as broken — and "0.0 W" is the true answer for
                // a full battery sitting on a charger.
                guard let watts = draw.batteryWatts else { return [] }
                return text(String(format: "%+.1f W", watts))
            case .system:
                guard let watts = draw.systemWatts else { return [] }
                return text(String(format: "%.1f W", watts))
            case .adapter:
                guard let watts = draw.adapterWatts else { return [] }
                return text(String(format: "%.1f W", watts))
            }

        case .cpuSpeed:
            guard let limit = telemetry.thermal?.speedLimitPercent else { return [] }
            switch Preferences.cpuSpeedStyle {
            case .off: return []
            case .percent: return text("\(limit)%")
            case .frequency:
                guard SystemLoad.nominalHz > 0 else { return [] }
                let ghz = Double(SystemLoad.nominalHz) / 1e9 * Double(limit) / 100
                return text(String(format: "%.1f GHz", ghz))
            }

        case .cpuLoad:
            guard let load = telemetry.load else { return [] }
            switch Preferences.cpuLoadStyle {
            case .off: return []
            case .total: return text("\(Int((load.total * 100).rounded()))%")
            case .perThread:
                guard let bars = threadBars(load.perCore, darkMenuBar: darkMenuBar) else { return [] }
                return caption.isEmpty ? [.drawing(bars)]
                    : [.text(caption.trimmingCharacters(in: .whitespaces)), .drawing(bars)]
            }

        case .memory:
            guard let load = telemetry.load else { return [] }
            switch Preferences.memoryStyle {
            case .off: return []
            case .percent: return text("\(Int((load.memoryFraction * 100).rounded()))%")
            case .used: return text(String(format: "%.1f GB", Double(load.memoryUsed) / 1_073_741_824))
            }

        case .network:
            guard let network = telemetry.network else { return [] }
            switch Preferences.networkStyle {
            case .off: return []
            case .both:
                return text("↓" + NetworkThroughput.format(network.downloadBytes)
                            + " ↑" + NetworkThroughput.format(network.uploadBytes))
            case .download:
                return text("↓" + NetworkThroughput.format(network.downloadBytes))
            case .upload:
                return text("↑" + NetworkThroughput.format(network.uploadBytes))
            }

        case .throttle:
            guard let thermal = telemetry.thermal, thermal.isThrottling,
                  let limit = thermal.speedLimitPercent else { return [] }
            return [.text("↓\(limit)%")]
        }
    }

    /// Lays the pieces out with one gap between them and no other spacing, so
    /// the fields are evenly separated however many there are.
    ///
    /// The percent sign sits against its number — "99%", not "99 %". The space
    /// is correct typography and wrong here: six fields each pay for it, and
    /// the menu bar is the one place on the screen with no room to give.
    private static func layout(_ segments: [Segment], darkMenuBar: Bool) -> NSImage {
        let height: CGFloat = 18
        let gap: CGFloat = 7
        // Monospaced digits so a changing number does not shove everything
        // beside it left and right twice a second.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let colour: NSColor = darkMenuBar ? .white : .black
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]

        var widths: [CGFloat] = []
        for segment in segments {
            switch segment {
            case .text(let value):
                widths.append((value as NSString).size(withAttributes: attributes).width)
            case .drawing(let image):
                widths.append(image.size.width)
            }
        }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, segments.count - 1))

        let canvas = NSImage(size: NSSize(width: max(1, total), height: height))
        canvas.lockFocus()
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text(let value):
                let size = (value as NSString).size(withAttributes: attributes)
                (value as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2),
                                         withAttributes: attributes)
            case .drawing(let image):
                image.draw(in: NSRect(x: x, y: (height - image.size.height) / 2,
                                      width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1)
            }
            x += widths[index] + gap
        }
        canvas.unlockFocus()
        // Never a template: a template is flattened to a mask and the coloured
        // battery would come out the same shade as the text.
        canvas.isTemplate = false
        return canvas
    }

    /// The sensor the user picked, falling back to whatever looks like the CPU
    /// so the display never silently empties when a chosen key disappears.
    static func chosenSensor(_ telemetry: Telemetry) -> TemperatureReading? {
        let key = Preferences.temperatureSensorKey
        if !key.isEmpty, let match = telemetry.temperatures.first(where: { $0.key == key }) {
            return match
        }
        return telemetry.cpuTemperature
    }

    // MARK: Drawing

    static func batteryImage(_ battery: BatteryStatus?, showingPercentage: Bool = false,
                             darkMenuBar: Bool = true) -> NSImage? {
        guard let battery = battery else { return nil }
        switch Preferences.batteryIcon {
        case .iOS: return iOSBattery(battery, showingPercentage: showingPercentage, darkMenuBar: darkMenuBar)
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

    private static func iOSBattery(_ battery: BatteryStatus, showingPercentage: Bool,
                                   darkMenuBar: Bool) -> NSImage {
        let height: CGFloat = 15
        let capWidth: CGFloat = 2
        let capGap: CGFloat = 1.2
        let fraction = max(0, min(1, Double(battery.percent) / 100))

        // The digits are sized from the pill rather than fixed, and the pill is
        // then widened to fit them. Fixing the font and guessing the width is
        // what made the number sit in the middle of a lot of empty space —
        // on the phone it very nearly fills the shape, and that is most of why
        // it reads at a glance.
        let text = "\(battery.percent)" as NSString
        let font = NSFont.systemFont(ofSize: height * 0.80, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let measured = showingPercentage ? text.size(withAttributes: attributes) : .zero
        // Sized for the widest number it will ever hold, not for the one it is
        // holding now. Fitting the pill to "9" and then to "100" makes the
        // whole menu bar shift sideways every time the battery ticks over,
        // which is the sort of movement the eye cannot help following.
        let widest = ("100" as NSString).size(withAttributes: attributes).width
        let bodyWidth: CGFloat = showingPercentage ? widest + 4 : 23

        let size = NSSize(width: bodyWidth + capGap + capWidth, height: height)

        let fill = (Self.forcedFillRole
            ?? fillRole(percent: battery.percent, isCharging: battery.isCharging,
                        isPluggedIn: battery.isPluggedIn, lowPower: isLowPowerMode)).colour
        // The neutral colour follows the menu bar, since this is no longer a
        // template image that the system would repaint for us.
        let neutral: NSColor = darkMenuBar ? .white : .black
        let paint = fill ?? neutral
        let empty = neutral.withAlphaComponent(0.35)

        let image = NSImage(size: size)
        image.lockFocus()

        let body = NSRect(x: 0, y: 0, width: bodyWidth, height: height)
        // Squarer than a stadium: iOS 27 rounds the corners noticeably less
        // than 26 did, and that is a large part of why the shape reads as new.
        let radius = height * 0.30
        let pill = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        empty.setFill()
        pill.fill()

        if fraction > 0 {
            NSGraphicsContext.saveGraphicsState()
            pill.addClip()
            paint.setFill()
            NSRect(x: 0, y: 0, width: bodyWidth * CGFloat(fraction), height: height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        (fraction >= 1 ? paint : empty).setFill()
        NSBezierPath(roundedRect: NSRect(x: bodyWidth + capGap, y: height / 2 - 2.5,
                                         width: capWidth, height: 5),
                     xRadius: 1, yRadius: 1).fill()

        if showingPercentage {
            // Punched through rather than painted on: the digits then read
            // against the filled part, against the grey remainder, and against
            // a light or dark menu bar without choosing a colour for each case.
            // Centred on the cap height, not on the line height. A line box
            // carries room for descenders that digits never use, so centring
            // on it pushes the number visibly high and makes it look smaller
            // than the space it occupies.
            let capHeight = font.capHeight
            // `descender` is negative, so it is added: subtracting it pushes
            // the digits up out of the pill, which is what happened first.
            let origin = NSPoint(x: (bodyWidth - measured.width) / 2,
                                 y: (height - capHeight) / 2 + font.descender)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            text.draw(at: origin, withAttributes: attributes)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }

        image.unlockFocus()
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
    ///
    /// The bars hang from the top rather than standing on the bottom. Growing
    /// upward, an idle machine drew sixteen specks along the lower edge that
    /// read as dirt on the screen rather than as a graph; hanging down, the
    /// row lines up with the text beside it and an idle machine is a thin even
    /// line instead of scattered dots.
    static func threadBars(_ load: [Double], darkMenuBar: Bool = true) -> NSImage? {
        guard !load.isEmpty else { return nil }
        let barWidth: CGFloat = 2
        let gap: CGFloat = 1
        let height: CGFloat = 14
        let width = CGFloat(load.count) * (barWidth + gap)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        // Painted rather than left as a mask: the line is drawn into a
        // non-template image now, so it has to carry its own colour.
        (darkMenuBar ? NSColor.white : NSColor.black).setFill()
        for (index, value) in load.enumerated() {
            let clamped = max(0.06, min(1, value))   // a visible mark at idle
            let x = CGFloat(index) * (barWidth + gap)
            let barHeight = height * CGFloat(clamped)
            NSRect(x: x, y: height - barHeight, width: barWidth, height: barHeight).fill()
        }
        image.unlockFocus()
        return image
    }
}
