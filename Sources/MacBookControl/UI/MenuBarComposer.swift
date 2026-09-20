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

    /// Which card the machine is drawing on, as a letter or spelled out.
    enum GraphicsStyle: String, CaseIterable {
        case off, short, full
        var label: String {
            switch self {
            case .off: return "Off"
            case .short: return "iGPU / dGPU"
            case .full: return "Integrated / Discrete"
            }
        }
    }

    /// One thing the status item can show. The order is the user's, so this is
    /// a list rather than a set of switches.
    enum Item: String, CaseIterable, Codable {
        case temperature, fan, battery, power, cpuSpeed, cpuLoad, memory, network, graphics, throttle

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
            case .graphics: return "Graphics card"
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
            case .graphics: return "GPU"
            case .throttle: return ""
            }
        }

        /// What this field costs to keep up to date.
        ///
        /// Here rather than in the telemetry: an exhaustive switch over this
        /// enum means adding a field forces somebody to answer what it reads,
        /// and the answer belongs beside the code that draws it.
        var telemetryNeeds: Telemetry.Needs {
            var needs = Telemetry.Needs()
            switch self {
            case .temperature: needs.oneSensor = true
            // Read from the registry by the composer itself: it is a fact
            // about processes rather than a hardware reading, and asking for
            // it does not wake the card the way asking Metal would.
            case .graphics: break
            case .fan: needs.fans = true
            // The icon and the percentage are drawn from the charge alone.
            case .battery: needs.battery = true
            // Watts are the expensive half: the flow comes from properties the
            // charge does not need and the supply from two SMC registers.
            case .power:
                needs.battery = true
                needs.batteryInDetail = true
            // The thermal reading is taken every tick regardless, because the
            // session's throttle history is documented to cover the time
            // nobody was looking.
            case .cpuSpeed, .throttle: break
            case .cpuLoad, .memory: needs.load = true
            case .network: needs.network = true
            }
            return needs
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
        /// What the line was drawn from, as a string.
        ///
        /// Two contents with the same signature are the same pixels. The menu
        /// bar is redrawn twice a second whether or not anything moved, and
        /// handing `button.image` a fresh image marks the item dirty even when
        /// it is identical — so the caller compares this and leaves the item
        /// alone when it matches. Built from the values rather than from the
        /// pixels: comparing the drawn bytes costs 0.29 ms, which is more than
        /// drawing them.
        var signature: String = ""
    }

    /// A piece of the line: either text, or a drawing that has not been made
    /// yet.
    fileprivate enum Segment {
        /// A colour of its own, for the one field that has something to say.
        case text(String, NSColor? = nil)
        /// The key says what the drawing *would* be made from, and the maker
        /// is not called until something has decided the line is worth
        /// drawing. Two drawings with one key are the same pixels, which is
        /// what lets a line be compared without being painted.
        case drawing(key: String, make: () -> NSImage?)
    }

    /// A piece with its drawing made.
    private enum Drawn {
        case text(String, NSColor?)
        case image(NSImage)
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
    /// Cached between composes. The status item is redrawn every two seconds,
    /// and walking a card's clients that often — to learn a fact that changes
    /// when an application opens a window — is more than it is worth.
    private static var discreteBusy = (value: false, at: Date.distantPast)

    private static var discreteIsBusy: Bool {
        if Date().timeIntervalSince(discreteBusy.at) >= 10 {
            discreteBusy = (AcceleratorClients.discreteIsBusy(), Date())
        }
        return discreteBusy.value
    }

    /// What the line will be, before a pixel of it is drawn.
    ///
    /// The status item is refreshed on a timer and most of those refreshes
    /// change nothing — a temperature that has not moved, a battery that ticks
    /// once every few minutes. Drawing first and comparing afterwards meant
    /// every one of those ticks paid for an offscreen bitmap that was then
    /// thrown away; a sample of the idle app found the *whole* of its
    /// main-thread work inside that discarded drawing. So the values come
    /// first, the signature is built from them, and the drawing happens only
    /// when the caller says the signature is new.
    struct Plan {
        /// Grouped by the field that produced them, because a field is what
        /// succeeds or fails as a whole: a drawing that cannot be made takes
        /// its caption and its number with it, which is what the old code did
        /// by returning an empty list before anything was built.
        fileprivate var fields: [[Segment]]
        fileprivate var darkMenuBar: Bool
        /// What the line would be drawn from, as a string. Empty means there
        /// is nothing to show; a real line always names its appearance first,
        /// so the two can never collide.
        var signature: String
    }

    static func plan(telemetry: Telemetry, darkMenuBar: Bool) -> Plan {
        var fields: [[Segment]] = []
        for item in Preferences.menuBarItems {
            let pieces = render(item, telemetry: telemetry, darkMenuBar: darkMenuBar)
            if !pieces.isEmpty { fields.append(pieces) }
        }
        return Plan(fields: fields, darkMenuBar: darkMenuBar,
                    signature: fields.isEmpty ? ""
                        : signature(of: fields.flatMap { $0 }, darkMenuBar: darkMenuBar))
    }

    /// Makes the drawings and lays them out. The expensive half.
    static func draw(_ plan: Plan) -> Content {
        let drawn = plan.fields.compactMap(materialise).flatMap { $0 }
        guard !drawn.isEmpty else { return Content(image: nil, title: "Zephyr") }
        return Content(image: layout(drawn, darkMenuBar: plan.darkMenuBar), title: "",
                       signature: plan.signature)
    }

    /// How many drawings have been made since the process started.
    ///
    /// Diagnostic, and the only way from outside to tell a planned line from a
    /// drawn one: the point of planning separately is that an unchanged line
    /// makes none, and that is invisible in the picture because there is no
    /// picture. The self-test watches this.
    private(set) static var drawingsMade = 0

    /// Makes one field's drawings, or nothing at all.
    ///
    /// Nil when a maker declines: a field is all or nothing, so a battery icon
    /// that cannot be drawn takes its caption and its percentage with it. A
    /// `break` inside the switch would have left them behind — it ends the
    /// switch, not the loop — which is why this is its own function.
    private static func materialise(_ field: [Segment]) -> [Drawn]? {
        var pieces: [Drawn] = []
        for segment in field {
            switch segment {
            case .text(let value, let colour):
                pieces.append(.text(value, colour))
            case .drawing(_, let make):
                guard let image = make() else { return nil }
                drawingsMade += 1
                pieces.append(.image(image))
            }
        }
        return pieces
    }

    /// Both halves at once, for the callers that always want the picture: the
    /// settings preview, the icon dump and the timing harness.
    static func compose(telemetry: Telemetry, darkMenuBar: Bool) -> Content {
        draw(plan(telemetry: telemetry, darkMenuBar: darkMenuBar))
    }

    /// What the line is made of, as a string. Cheap: a few short pieces joined.
    private static func signature(of segments: [Segment], darkMenuBar: Bool) -> String {
        var parts: [String] = [darkMenuBar ? "dark" : "light"]
        for segment in segments {
            switch segment {
            case .text(let value, let colour):
                parts.append("t:" + value + (colour.map { ":\($0.hashValue)" } ?? ""))
            case .drawing(let key, _):
                parts.append(key)
            }
        }
        return parts.joined(separator: "|")
    }

    private static func render(_ item: Item, telemetry: Telemetry, darkMenuBar: Bool) -> [Segment] {
        let caption = Preferences.menuBarItemIsCaptioned(item) && !item.caption.isEmpty
            ? item.caption + " " : ""
        func text(_ value: String) -> [Segment] { [.text(caption + value, nil)] }

        switch item {
        case .temperature:
            guard let reading = chosenSensor(telemetry) else { return [] }
            // The one field that changes colour. A number that has to be
            // compared against a threshold in your head is a number nobody
            // checks; a number that turns orange is one you cannot miss.
            let limit = Preferences.sensorAlertCelsius
            let tint: NSColor? = limit > 0 && reading.celsius >= Double(limit)
                ? (darkMenuBar ? .systemOrange : .systemRed) : nil
            return [.text(caption + String(format: "%.0f°", reading.celsius), tint)]

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
                let key = batteryKey(battery, showingPercentage: false, darkMenuBar: darkMenuBar)
                let icon = Segment.drawing(key: key) {
                    batteryImage(battery, darkMenuBar: darkMenuBar)
                }
                return caption.isEmpty ? [icon]
                    : [.text(caption.trimmingCharacters(in: .whitespaces)), icon]
            case .iconAndPercent:
                // The iPhone puts the number inside the battery; every other
                // icon needs it written beside. Printing both would be the
                // obvious bug.
                let inside = Preferences.batteryIcon == .iOS
                var pieces: [Segment] = []
                if !caption.isEmpty { pieces.append(.text(caption.trimmingCharacters(in: .whitespaces))) }
                pieces.append(.drawing(key: batteryKey(battery, showingPercentage: inside,
                                                       darkMenuBar: darkMenuBar)) {
                    batteryImage(battery, showingPercentage: inside, darkMenuBar: darkMenuBar)
                })
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
                // The measured clock where it can be had; otherwise the base
                // against the firmware's cap, which is a ceiling rather than a
                // speed.
                if let measured = telemetry.load?.cpuHertz {
                    return text(String(format: "%.1f GHz", measured / 1e9))
                }
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
                // The bars are quantised to whole pixels, so the key is too:
                // a core wandering between 41.2 % and 41.4 % draws the same
                // bar and must not count as a change.
                let cores = load.perCore
                let key = "bars:" + cores.map { String(Int(($0 * 100).rounded())) }.joined(separator: ",")
                let bars = Segment.drawing(key: key) {
                    threadBars(cores, darkMenuBar: darkMenuBar)
                }
                return caption.isEmpty ? [bars]
                    : [.text(caption.trimmingCharacters(in: .whitespaces)), bars]
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

        case .graphics:
            switch Preferences.graphicsStyle {
            case .off: return []
            case .short: return text(discreteIsBusy ? "dGPU" : "iGPU")
            case .full: return text(discreteIsBusy ? "Discrete" : "Integrated")
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
    private static func layout(_ pieces: [Drawn], darkMenuBar: Bool) -> NSImage {
        let height = Height.strip
        let gap: CGFloat = 7
        // Monospaced digits so a changing number does not shove everything
        // beside it left and right twice a second.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let colour: NSColor = darkMenuBar ? .white : .black
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]

        var widths: [CGFloat] = []
        for piece in pieces {
            switch piece {
            case .text(let value, _):
                widths.append((value as NSString).size(withAttributes: attributes).width)
            case .image(let image):
                widths.append(image.size.width)
            }
        }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, pieces.count - 1))

        let canvas = NSImage(size: NSSize(width: max(1, total), height: height))
        canvas.lockFocus()
        var x: CGFloat = 0
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case .text(let value, let tint):
                var own = attributes
                if let tint = tint { own[.foregroundColor] = tint }
                let size = (value as NSString).size(withAttributes: own)
                (value as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2),
                                         withAttributes: own)
            case .image(let image):
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

    /// How tall the drawn things are, taken from the menu bar rather than
    /// written down three times.
    ///
    /// The three heights were constants — 18 for the strip, 15 for the
    /// battery, 14 for the load graph — chosen against a 22-point bar, which
    /// is what a Mac without a notch has. A taller bar left them where they
    /// were, so the item sat in the middle of a band with room to spare. The
    /// ratios below reproduce the old numbers exactly at 22 points and follow
    /// the bar anywhere else.
    enum Height {
        /// What the constants were measured against.
        static let referenceThickness: CGFloat = 22

        static var bar: CGFloat {
            let thickness = NSStatusBar.system.thickness
            return thickness > 0 ? thickness : referenceThickness
        }

        /// The thickness is a parameter so the arithmetic can be checked on a
        /// machine whose menu bar is whatever it happens to be.
        static func scaled(_ atReference: CGFloat, thickness: CGFloat = bar) -> CGFloat {
            (thickness * atReference / referenceThickness).rounded()
        }

        static var strip: CGFloat { scaled(18) }
        static var battery: CGFloat { scaled(15) }
        static var graph: CGFloat { scaled(14) }
    }

    /// Half-point alignment. The menu bar draws at 2×, so a coordinate landing
    /// between device pixels costs sharpness on text and on small glyphs —
    /// which at this size is most of what there is.
    static func pixelAligned(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }

    /// Everything the battery drawing is made from, and nothing else.
    ///
    /// The role rather than the three flags behind it: two states that paint
    /// the same colour draw the same battery, and saying so here is what keeps
    /// the menu bar still.
    static func batteryKey(_ battery: BatteryStatus, showingPercentage: Bool,
                           darkMenuBar: Bool) -> String {
        let role = forcedFillRole ?? fillRole(percent: battery.percent,
                                              isCharging: battery.isCharging,
                                              isPluggedIn: battery.isPluggedIn,
                                              lowPower: isLowPowerMode)
        return "bat:\(battery.percent):\(role):\(battery.isPluggedIn):"
            + "\(showingPercentage):\(darkMenuBar):\(Preferences.batteryIcon.rawValue)"
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

    /// Not private so the self-test can render it and hold two states against
    /// each other, which is the only way to check that the item keeps one
    /// width whatever the charger is doing.
    static func iOSBattery(_ battery: BatteryStatus, showingPercentage: Bool,
                                   darkMenuBar: Bool) -> NSImage {
        let height = Self.Height.battery
        let capWidth: CGFloat = 2
        let capGap: CGFloat = 1.2
        let fraction = max(0, min(1, Double(battery.percent) / 100))

        // The digits are sized from the pill rather than fixed, and the pill is
        // then widened to fit them. Fixing the font and guessing the width is
        // what made the number sit in the middle of a lot of empty space —
        // on the phone it very nearly fills the shape, and that is most of why
        // it reads at a glance.
        let text = "\(battery.percent)" as NSString
        // 0.72 rather than 0.80: against the reference the owner drew from, the
        // digits were running a little large and taking the pill with them.
        let font = NSFont.systemFont(ofSize: height * 0.68, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let measured = showingPercentage ? text.size(withAttributes: attributes) : .zero
        // Sized for the widest number it will ever hold, not for the one it is
        // holding now. Fitting the pill to "9" and then to "100" makes the
        // whole menu bar shift sideways every time the battery ticks over,
        // which is the sort of movement the eye cannot help following.
        let widest = ("100" as NSString).size(withAttributes: attributes).width

        // The bolt sits inside the pill, to the right of the number, and its
        // room is counted into the pill whether or not it is drawn — for the
        // same reason the pill is sized for "100" rather than for the figure
        // it happens to hold. An item that changes width when the charger goes
        // in drags everything to the left of it sideways.
        // The system's own bolt, at its own proportions. Drawing one by hand
        // at five pixels across produced something recognisable only if you
        // were told what it was; this is the glyph the phone uses, so there is
        // nothing to compare unfavourably against.
        // The slot is the drawing, not the box it is laid out in.
        //
        let boltHeight = height * 0.55
        let boltWidth = boltHeight * Self.boltInk.inkAspect
        let boltGap: CGFloat = 1
        let sidePadding: CGFloat = 2.5
        // One width, whatever is inside it. With the number it was 37 points
        // and without it 23, which is not one battery drawn two ways but two
        // different objects: at the same height the short one reads rounder
        // and stubbier. The pill is sized for everything it can ever hold —
        // three digits, the gap and the bolt — and what is not there simply
        // leaves the middle emptier.
        // Two points of side padding, not five: with three digits and a
        // bolt the pill was running at about two and a half times its
        // height, which in a real menu bar reads as a wide slab rather
        // than as a battery.
        // Padding on both sides. One point was not enough: the first digit came
        // out touching the left edge and the bolt ran into the curve on the
        // right, which cut its corner off.
        let bodyWidth = widest + boltGap + boltWidth + sidePadding * 2
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

        // The number and the bolt together, centred as one group.
        //
        // Mains or not is what the colour could not say. Green means a battery
        // that is filling; a machine sitting at 100 % on the charger, or held
        // at a charge ceiling, is not filling — so it drew exactly like one
        // running on battery, which is the state this Mac is in most of the
        // time.
        let boltShown = battery.isPluggedIn
        // The bolt keeps its place against the right, and the number is
        // centred in what is left of the pill. Centring the two together as
        // one group looked right at 100 % and wrong everywhere else: a shorter
        // number pulled the bolt along with it, so the bolt sat in a different
        // place at 9 % than at 100 %.
        let boltX = bodyWidth - sidePadding - boltWidth
        let textRegion = boltShown && showingPercentage
            ? sidePadding ... (boltX - boltGap)
            : sidePadding ... (bodyWidth - sidePadding)
        let groupX = textRegion.lowerBound
            + ((textRegion.upperBound - textRegion.lowerBound) - measured.width) / 2

        if showingPercentage || boltShown {
            // Punched through rather than painted on: both then read against
            // the filled part, against the grey remainder, and against a light
            // or dark menu bar without choosing a colour for each case.
            NSColor.black.setFill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            if showingPercentage {
                // Centred on where the glyphs actually land, not on the font's
                // metrics. Cap height and descender describe the typeface, not
                // this particular string, and centring by them put the digits
                // 2.5 points below the top of the pill and 5 above the bottom
                // — measured, by rendering and looking for the ink. The device
                // metrics give the drawn bounding box, and `minY` says where
                // it sits relative to the drawing origin.
                let ink = Self.digitInk(font)
                // `draw(at:)` places the baseline, and the ink sits above it by
                // its own bottom bearing; the two together are where the
                // drawing actually starts. Derived by drawing the string at
                // three known offsets and measuring where the ink landed,
                // because the font's own metrics describe the typeface and not
                // this string: centring by cap height and descender left the
                // number sitting high in the pill.
                text.draw(at: NSPoint(x: Self.pixelAligned(groupX),
                                      y: (height - ink.height) / 2 - ink.bottom),
                          withAttributes: attributes)
            }
            if boltShown {
                // Centred alone when there is no number to sit beside.
                let x = showingPercentage ? boltX : (bodyWidth - boltWidth) / 2
                let box = NSRect(x: Self.pixelAligned(x),
                                 y: Self.pixelAligned((height - boltHeight) / 2),
                                 width: boltWidth, height: boltHeight)
                if let symbol = Self.boltSymbol {
                    // Enlarged and shifted so its drawing — not its box —
                    // lands exactly in the slot reserved above.
                    let boxHeight = box.height / Self.boltInk.heightShare
                    let boxWidth = boxHeight * Self.boltInk.boxAspect
                    symbol.draw(in: NSRect(x: box.minX - Self.boltInk.leading * boxWidth,
                                           y: box.midY - boxHeight / 2,
                                           width: boxWidth, height: boxHeight),
                                from: .zero, operation: .destinationOut, fraction: 1)
                } else {
                    bolt(in: box).fill()
                }
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }

        image.unlockFocus()
        return image
    }

    /// The system's filled bolt, kept as a template so it can be punched
    /// through the pill the way the digits are.
    ///
    /// `bolt.fill` rather than `bolt`: the outline's strokes really do come out
    /// thinner than a pixel at this size, which is what made the symbol set
    /// look unusable at first. The filled one has no strokes to lose.
    private static let boltSymbol: NSImage? = {
        let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }()

    /// Where a digit's ink sits relative to where `draw(at:)` is told to put
    /// it, and how tall it is — measured once per font size.
    ///
    /// The font's own metrics describe the typeface, not the string: centring
    /// digits by cap height and descender left them a pixel and a half above
    /// the middle of the pill, which is visible when the pill is fifteen
    /// points tall and the number is punched through it. Rendering one digit
    /// and looking for the ink answers exactly, and the answer is the same for
    /// every digit, so one measurement serves.
    private static var digitInkCache: [CGFloat: (bottom: CGFloat, height: CGFloat)] = [:]

    static func digitInk(_ font: NSFont) -> (bottom: CGFloat, height: CGFloat) {
        if let known = digitInkCache[font.pointSize] { return known }
        let side = 64
        let measured: (bottom: CGFloat, height: CGFloat)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            ("0" as NSString).draw(at: NSPoint(x: 4, y: 8),
                                   withAttributes: [.font: font, .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            var top = side, bottom = -1
            for y in 0 ..< side {
                for x in 0 ..< side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    top = Swift.min(top, y); bottom = Swift.max(bottom, y)
                }
            }
            if bottom >= top {
                // The bitmap counts down from the top; the drawing origin was
                // eight points up from the bottom.
                measured = (CGFloat(side - 1 - bottom) - 8, CGFloat(bottom - top + 1))
            } else {
                measured = (-font.descender, font.capHeight)
            }
        } else {
            measured = (-font.descender, font.capHeight)
        }
        digitInkCache[font.pointSize] = measured
        return measured
    }

    /// Where the bolt actually is inside the symbol's box.
    ///
    /// `bolt.fill` is laid out with empty box around the drawing — measured by
    /// rendering it and looking for the first column that is not transparent:
    /// 15.7 % of the width at each side and 7.5 % of the height above and
    /// below. Reserving the box rather than the drawing spent a quarter of the
    /// pill's width on air, which is most of why it came out too wide.
    ///
    /// Measured rather than written down, so a symbol Apple redraws does not
    /// silently take the layout with it.
    static let boltInk: (boxAspect: CGFloat, inkAspect: CGFloat,
                         heightShare: CGFloat, leading: CGFloat) = {
        let fallback: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.765, 0.618, 0.850, 0.157)
        guard let symbol = boltSymbol, symbol.size.height > 0 else { return fallback }
        let boxAspect = symbol.size.width / symbol.size.height
        let side = 120
        let width = Int((CGFloat(side) * boxAspect).rounded())
        guard width > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return fallback }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        symbol.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(side)),
                    from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var minX = width, maxX = -1, minY = side, maxY = -1
        for y in 0 ..< side {
            for x in 0 ..< width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
                minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return fallback }
        let inkWidth = CGFloat(maxX - minX + 1), inkHeight = CGFloat(maxY - minY + 1)
        return (boxAspect, inkWidth / inkHeight, inkHeight / CGFloat(side),
                CGFloat(minX) / CGFloat(width))
    }()

    /// A lightning bolt in the given box, for a system that has no `bolt.fill`.
    private static func bolt(in rect: NSRect) -> NSBezierPath {
        func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        let path = NSBezierPath()
        path.move(to: at(0.58, 1.00))
        path.line(to: at(0.08, 0.38))
        path.line(to: at(0.46, 0.38))
        path.line(to: at(0.42, 0.00))
        path.line(to: at(0.92, 0.62))
        path.line(to: at(0.54, 0.62))
        path.close()
        return path
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
        let height = Height.graph
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
