import SwiftUI

/// A live prototype of the 2.0 look, behind `--preview-design`.
///
/// Built rather than rendered because two rounds with an image generator could
/// not hold seven section names, the real labels, or a toggle per section — and
/// no wording fixes that. Here the labels are the ones the app actually uses
/// and the numbers are the ones the machine is actually reporting, so what is
/// being judged is the design and not a plausible drawing of one.
///
/// The shipping settings window is untouched. Nothing here is reachable from
/// the menu.
/// One visual language. The structure and the words are identical in all of
/// them — only colour, face and how selection is marked differ, which is the
/// only honest way to compare directions.
struct PreviewStyle {
    let name: String
    let ground: Color
    let panel: Color
    let text: Color
    let dim: Color
    let accent: Color
    let rule: Color
    /// Monospaced throughout, or a sans face with monospaced digits.
    let monospaced: Bool
    /// Selection written with brackets rather than a filled shape.
    let bracketSelection: Bool
    /// A fill behind the selected sidebar row.
    let filledSelection: Bool
    /// Tabs across the top instead of a sidebar.
    var topTabs: Bool = false

    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        monospaced
            ? .system(size: size, weight: weight, design: .monospaced)
            : .system(size: size, weight: weight)
    }

    /// Numbers are always monospaced, whatever the body face: a value that
    /// changes width shoves everything beside it twice a second.
    func numberFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    static let terminal = PreviewStyle(
        name: "Terminal",
        ground: Color(red: 0.043, green: 0.043, blue: 0.043),
        panel: Color(red: 0.07, green: 0.07, blue: 0.07),
        text: Color(white: 0.92), dim: Color(white: 0.55),
        // Muted rather than phosphor: a bright green over a whole window stops
        // meaning "this is on" and starts meaning "this is a costume".
        accent: Color(red: 0.49, green: 0.83, blue: 0.56),
        rule: Color(white: 1).opacity(0.12),
        monospaced: true, bracketSelection: true, filledSelection: false)

    static let ma = PreviewStyle(
        name: "Ma — emptiness as material",
        ground: Color(red: 0.980, green: 0.976, blue: 0.965),
        panel: Color(red: 0.980, green: 0.976, blue: 0.965),
        text: Color(white: 0.10), dim: Color(white: 0.45),
        accent: Color(red: 0.30, green: 0.33, blue: 0.55),
        rule: Color(white: 0).opacity(0.10),
        monospaced: false, bracketSelection: false, filledSelection: false)

    static let instrument = PreviewStyle(
        name: "Instrument",
        ground: Color(red: 0.949, green: 0.949, blue: 0.937),
        panel: Color(red: 0.921, green: 0.921, blue: 0.909),
        text: Color(white: 0.08), dim: Color(white: 0.42),
        accent: Color(red: 0.72, green: 0.47, blue: 0.10),
        rule: Color(white: 0).opacity(0.14),
        monospaced: false, bracketSelection: false, filledSelection: true)

    static let ink = PreviewStyle(
        name: "Ink on paper",
        ground: Color(red: 0.984, green: 0.972, blue: 0.945),
        panel: Color(red: 0.965, green: 0.949, blue: 0.914),
        text: Color(white: 0.09), dim: Color(white: 0.44),
        accent: Color(red: 0.42, green: 0.36, blue: 0.28),
        rule: Color(white: 0).opacity(0.12),
        monospaced: false, bracketSelection: false, filledSelection: false)

    static let darkGlass = PreviewStyle(
        name: "Dark glass",
        ground: Color(red: 0.110, green: 0.110, blue: 0.118),
        panel: Color(red: 0.086, green: 0.086, blue: 0.094),
        text: Color(white: 0.95), dim: Color(white: 0.55),
        accent: Color(red: 0.20, green: 0.52, blue: 0.96),
        rule: Color(white: 1).opacity(0.09),
        monospaced: false, bracketSelection: false, filledSelection: true)

    static let classic = PreviewStyle(
        name: "Classic",
        ground: Color(red: 0.129, green: 0.129, blue: 0.137),
        panel: Color(red: 0.129, green: 0.129, blue: 0.137),
        text: Color(white: 0.95), dim: Color(white: 0.58),
        accent: Color(red: 0.20, green: 0.52, blue: 0.96),
        rule: Color(white: 1).opacity(0.10),
        monospaced: false, bracketSelection: false, filledSelection: true,
        topTabs: true)

    /// Only the two invented directions. "Classic" is not here because it is
    /// not a direction to imagine — it is the window that already ships, and
    /// it is rendered from the real view instead.
    static let all: [PreviewStyle] = [ma, terminal]
}

enum TerminalPalette {
    static let ground = PreviewStyle.terminal.ground
    static let panel = PreviewStyle.terminal.panel
    static let text = PreviewStyle.terminal.text
    static let dim = PreviewStyle.terminal.dim
    static let accent = PreviewStyle.terminal.accent
    static let rule = PreviewStyle.terminal.rule
}

/// The seven sections, after merging the ten tabs by meaning.
enum PreviewSection: String, CaseIterable, Identifiable {
    case thermals, graphics, batterySleep, display, input, profiles, menuBar, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .thermals: return "Thermals"
        case .graphics: return "Graphics"
        case .batterySleep: return "Battery & Sleep"
        case .display: return "Display"
        case .input: return "Input"
        case .profiles: return "Profiles"
        case .menuBar: return "Menu Bar"
        // Last, and about the app rather than the machine — which is why it
        // sits apart from the seven that touch hardware.
        case .settings: return "Settings"
        }
    }

    /// Which of the shipping features this section governs. The merge is only
    /// a matter of presentation — the features underneath keep their own
    /// switches, which is why a merged section shows more than one.
    var featureIDs: [String] {
        switch self {
        case .thermals: return ["cooling", "power"]
        case .graphics: return ["graphics"]
        case .batterySleep: return ["battery", "awake"]
        case .display: return ["display"]
        case .input: return ["keyboard", "pointer"]
        case .profiles: return ["profiles"]
        case .menuBar, .settings: return []
        }
    }
}

struct TerminalDesignView: View {
    @ObservedObject var registry: FeatureRegistry
    @ObservedObject var telemetry: Telemetry
    var style: PreviewStyle = .terminal
    var section: PreviewSection = .thermals
    @State private var selectionOverride: PreviewSection?

    private var selection: PreviewSection { selectionOverride ?? section }
    private var mono: Font { style.font(12) }

    var body: some View {
        Group {
            if style.topTabs {
                VStack(spacing: 0) {
                    topTabRow
                    Rectangle().fill(style.rule).frame(height: 1)
                    content
                }
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Rectangle().fill(style.rule).frame(width: 1)
                    content
                }
            }
        }
        .background(style.ground)
        .frame(minWidth: 880, minHeight: 620)
    }

    /// The familiar arrangement, for comparison. Eight labels is close to the
    /// limit of what a row can hold before the words start truncating — which
    /// is the argument the sidebar makes for itself.
    private var topTabRow: some View {
        HStack(spacing: 2) {
            ForEach(PreviewSection.allCases) { section in
                Text(section.title)
                    .font(style.font(12))
                    .foregroundColor(selection == section ? .white : style.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        selection == section
                            ? AnyView(RoundedRectangle(cornerRadius: 5).fill(style.accent))
                            : AnyView(Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selectionOverride = section }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Zephyr")
                .font(style.font(12))
                .foregroundColor(style.dim)
                .padding(.leading, 22)
                .padding(.bottom, 14)

            ForEach(PreviewSection.allCases) { section in
                sidebarRow(section)
            }
            Spacer()
            statusBlock
        }
        .padding(.vertical, 18)
        .frame(width: 236, alignment: .leading)
        .background(style.panel)
    }

    private func sidebarRow(_ section: PreviewSection) -> some View {
        // No switch here on purpose. It duplicated the one at the top of the
        // section, and two controls for one thing means guessing which is
        // authoritative when they ever disagree.
        let isSelected = selection == section
        return HStack(spacing: 6) {
            // In a monospaced list the marker is a character, so every label
            // keeps the same left edge. Elsewhere a fill reads faster.
            if style.bracketSelection {
                Text(isSelected ? "›" : " ").font(mono).foregroundColor(style.accent)
            }
            Text(section.title)
                .font(mono)
                .foregroundColor(isSelected && !style.filledSelection ? style.accent : style.text)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            style.filledSelection && isSelected
                ? style.accent.opacity(0.22) : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture { selectionOverride = section }
    }

    /// The full reading, at the foot of the sidebar.
    ///
    /// It overlaps the menu bar, and that is the point rather than a fault:
    /// the menu bar is a glance and holds five or six values chosen by hand,
    /// while this is everything the machine is reporting — both fans, every
    /// temperature, the power split three ways. A summary and its detail are
    /// supposed to agree.
    ///
    /// The alternative — showing only what the menu bar does not — was
    /// considered and dropped: the contents would then change whenever the
    /// menu bar is edited, and a panel that rearranges itself for reasons
    /// elsewhere is harder to read than one that repeats a number.
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle().fill(style.rule).frame(height: 1)
                .padding(.bottom, 6)
            ForEach(statusLines, id: \.self) { line in
                Text(line)
                    .font(style.numberFont(11))
                    .foregroundColor(style.text)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    /// Composed as whole strings so the columns line up by character count,
    /// which is what a monospaced face is for. Laying them out as separate
    /// views would need widths guessed per column and would drift the moment
    /// a value gained a digit.
    private var statusLines: [String] {
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        func right(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
        }
        func gb(_ bytes: UInt64) -> String {
            String(format: "%.0f", Double(bytes) / 1_073_741_824)
        }

        var lines: [String] = []

        // CPU: temperature, load, and the frequency the firmware is allowing.
        // Not the live clock — macOS on Intel does not publish one — so this
        // is the ceiling, and it is labelled that way in the section itself.
        let cpuTemp = telemetry.cpuTemperature.map { String(format: "%.0f°C", $0.celsius) } ?? "—"
        let cpuLoad = telemetry.load.map { "\(Int(($0.total * 100).rounded()))%" } ?? "—"
        var cpuGHz = "—"
        if let limit = telemetry.thermal?.speedLimitPercent, SystemLoad.nominalHz > 0 {
            cpuGHz = String(format: "%.1f GHz", Double(SystemLoad.nominalHz) / 1e9 * Double(limit) / 100)
        }
        lines.append(pad("CPU", 5) + right(cpuTemp, 6) + right(cpuLoad, 6) + right(cpuGHz, 9))

        // GPU: temperature and load. There is no frequency — the accelerator
        // does not publish one on this hardware, and a dash is more honest
        // than a number that came from somewhere else.
        let gpuTemp = telemetry.temperatures.first { $0.key == "TG0P" }
            .map { String(format: "%.0f°C", $0.celsius) } ?? "—"
        let gpuLoad = telemetry.load?.gpuFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        lines.append(pad("GPU", 5) + right(gpuTemp, 6) + right(gpuLoad, 6) + right("—", 9))

        if let load = telemetry.load, load.memoryTotal > 0 {
            let ram = "\(gb(load.memoryUsed))/\(gb(load.memoryTotal)) GB"
            lines.append(pad("RAM", 5) + right(ram, 12) + right("\(Int((load.memoryFraction * 100).rounded()))%", 9))
        }
        // Read directly rather than out of the load snapshot: disk usage is a
        // single reading and has no business waiting for the second poll that
        // a *rate* like CPU load needs.
        if let disk = SystemLoad.diskUsage() {
            let rom = "\(gb(disk.usedBytes))/\(gb(disk.totalBytes)) GB"
            lines.append(pad("ROM", 5) + right(rom, 12) + right("\(Int((disk.fraction * 100).rounded()))%", 9))
        }
        if let battery = telemetry.battery {
            // Time is only shown while the system is willing to estimate it —
            // on the charger there is nothing to count down to.
            let remaining = battery.minutesRemaining.map { "\($0 / 60)h \($0 % 60)m" }
                ?? (battery.isCharging ? "charging" : "—")
            lines.append(pad("BAT", 5) + right("\(battery.percent)%", 6) + right(remaining, 15))
        }
        return lines
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(selection.title)
                    .font(style.font(19, weight: .medium))
                    .foregroundColor(style.text)

                if selection == .thermals { thermals } else { render(rows(for: selection)) }
                Spacer(minLength: 0)
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var thermals: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("FANS") {
                switchRow("Enable Cooling", id: "cooling")
                if let cooling = registry.feature(id: "cooling") as? CoolingFeature {
                    segmented(["Firmware": "auto", "Temperature curve": "curve", "Fixed speed": "manual"],
                              selected: cooling.mode) { cooling.mode = $0 }
                    if cooling.mode == "curve" {
                        valueRow("Start lifting the fans at", value: cooling.curveMin,
                                 unit: "°C", range: 40...80) { cooling.curveMin = $0 }
                        valueRow("Reach full speed at", value: cooling.curveMax,
                                 unit: "°C", range: 60...100) { cooling.curveMax = $0 }
                    }
                }
            }

            group("POWER") {
                switchRow("Enable Power", id: "power")
                if let power = registry.feature(id: "power") as? PowerFeature {
                    toggleRow("Disable Turbo Boost", isOn: power.turboDisabled) {
                        power.setTurboDisabled($0)
                    }
                    if let limits = power.limits, !limits.isLocked {
                        valueRow("Sustained limit", value: power.pl1, unit: "W",
                                 range: limits.lowerBound...limits.upperBound) {
                            power.pl1 = $0; power.applyLimits()
                        }
                        valueRow("Burst limit", value: power.pl2, unit: "W",
                                 range: limits.lowerBound...limits.upperBound) {
                            power.pl2 = $0; power.applyLimits()
                        }
                    }
                }
            }

            group("THROTTLING") {
                if let thermal = telemetry.thermal, let limit = thermal.speedLimitPercent {
                    statement(limit < 100
                              ? "The firmware is holding the CPU at \(limit) % of full speed right now."
                              : "The CPU is running at full speed.")
                } else {
                    statement("Reading…")
                }
                statement(telemetry.stats.everThrottled
                          ? "Lowest this session: \(telemetry.stats.lowestSpeedLimit) % · held back for \(telemetry.stats.throttledLabel)"
                          : "Nothing has been capped since Zephyr started.")
            }
        }
    }

    /// Every section as data, so one renderer draws them all in whatever
    /// language is selected. Bespoke views per section would drift apart the
    /// moment a style changed, which is the opposite of what a comparison
    /// needs.
    private enum Row {
        case heading(String)
        case toggle(String, Bool)
        case segmented([String], String)
        case value(String, Double, String, ClosedRange<Double>)
        case statement(String)
        case pair(String, String)
    }

    private func rows(for section: PreviewSection) -> [Row] {
        switch section {
        case .thermals:
            return []   // drawn live, with working controls
        case .graphics:
            return [
                .heading("GRAPHICS"),
                .toggle("Enable Graphics", registry.feature(id: "graphics")?.isEnabled == true),
                .segmented(["Integrated only", "Discrete only", "Automatic"], "Automatic"),
                .pair("Integrated", "Intel UHD Graphics 630"),
                .pair("Discrete", "AMD Radeon Pro 5500M"),
                .pair("Rendering now", "Intel UHD Graphics 630"),
                .statement("Zephyr re-asserts this every few seconds, because macOS hands the discrete GPU to whatever asks."),
            ]
        case .batterySleep:
            let battery = telemetry.battery
            return [
                .heading("BATTERY"),
                .toggle("Enable Battery", registry.feature(id: "battery")?.isEnabled == true),
                .value("Stop charging at", Double(Preferences.chargeLimitPercent), "%", 20...100),
                .pair("Now", battery.map { "\($0.percent) % · \($0.stateLabel)" } ?? "—"),
                .pair("Health", battery.flatMap { b in b.healthPercent.map { "\($0) % of design capacity, \(b.cycleCount ?? 0) cycles" } } ?? "—"),
                .heading("SLEEP"),
                .toggle("Enable Awake", registry.feature(id: "awake")?.isEnabled == true),
                .toggle("Keep the display on too", Preferences.awakeKeepsDisplayOn),
                .toggle("Stay awake with the lid closed", Preferences.awakeWhenLidClosed),
            ]
        case .display:
            let screen = telemetry.temperatures.isEmpty ? nil : DisplayControl().screens().first
            return [
                .heading("DISPLAY"),
                .toggle("Enable Display", registry.feature(id: "display")?.isEnabled == true),
                .pair("Built-in display", screen.map { "\($0.width) × \($0.height) on \($0.pixelWidth) pixels across" } ?? "—"),
                .value("Brightness", Double((screen?.brightness ?? 0.75) * 100), "%", 0...100),
                .statement("A resolution is put back by itself unless you confirm you can still see."),
            ]
        case .input:
            return [
                .heading("KEYBOARD"),
                .toggle("Enable Keyboard", registry.feature(id: "keyboard")?.isEnabled == true),
                .pair("Caps Lock", "→  Escape"),
                .heading("POINTER"),
                .toggle("Enable Pointer", registry.feature(id: "pointer")?.isEnabled == true),
                .toggle("Reverse scrolling on a mouse", Preferences.reverseMouseScroll),
                .toggle("Take the acceleration out of the pointer", Preferences.flattenPointerAcceleration),
                .pair("Side button 1", "Previous desktop"),
                .pair("Side button 2", "Next desktop"),
            ]
        case .profiles:
            return [
                .heading("PROFILES"),
                .toggle("Enable Profiles", registry.feature(id: "profiles")?.isEnabled == true),
                .pair("In force now", "On battery"),
                .heading("ON BATTERY"),
                .statement("Fires when all of these hold — power is battery"),
                .pair("Then set", "Turbo Boost off"),
                .pair("", "Graphics: Integrated only"),
                .pair("", "Stop charging at 80 %"),
            ]
        case .settings:
            return [
                .heading("APPEARANCE"),
                .segmented(["Light", "System", "Dark"],
                           Preferences.appearance == "light" ? "Light"
                             : Preferences.appearance == "dark" ? "Dark" : "System"),
                .statement("System follows whatever the Mac is set to. The menu-bar readout always follows the menu bar's own appearance, which is not always the window's."),
                .heading("STARTUP"),
                .toggle("Launch at login", LaunchAtLogin.isEnabled),
                .heading("HELPER"),
                .pair("State", "running"),
                .statement("Fans, graphics, Turbo Boost, the charge ceiling and the power limit all write to hardware, which needs root."),
            ]
        case .menuBar:
            return [
                .heading("MENU BAR"),
                .pair("Now showing", "50°  1834 rpm  99 %  2.3 GHz  57 %"),
                .toggle("Label this number", !Preferences.captionedMenuBarItems.isEmpty),
                .heading("SHOWN, IN THIS ORDER"),
                .pair("1", "Temperature"),
                .pair("2", "Fan speed"),
                .pair("3", "Battery"),
                .pair("4", "CPU speed"),
                .pair("5", "Memory"),
            ]
        }
    }

    @ViewBuilder private func render(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .heading(let text):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(text)
                            .font(style.font(10, weight: .semibold))
                            .tracking(style.monospaced ? 2.2 : 1.4)
                            .foregroundColor(style.accent)
                        Rectangle().fill(style.rule).frame(height: 1)
                    }
                    .padding(.top, 6)
                case .toggle(let title, let on):
                    HStack { switchGlyph(on); Text(title).font(mono).foregroundColor(style.text); Spacer() }
                case .segmented(let options, let selected):
                    segmented(Dictionary(uniqueKeysWithValues: options.map { ($0, $0) }),
                              selected: selected) { _ in }
                case .value(let title, let value, let unit, let range):
                    valueRow(title, value: value, unit: unit, range: range) { _ in }
                case .statement(let text):
                    Text(text).font(mono).foregroundColor(style.dim)
                        .fixedSize(horizontal: false, vertical: true)
                case .pair(let key, let value):
                    HStack {
                        Text(key).font(mono).foregroundColor(style.dim)
                            .frame(width: 160, alignment: .leading)
                        Text(value).font(mono).foregroundColor(style.text)
                        Spacer()
                    }
                }
            }
        }
    }

    private var placeholder: some View {
        Text("This section is not part of the prototype. Only Thermals is wired, because one section fully working says more about the design than seven half-drawn ones.")
            .font(mono)
            .foregroundColor(style.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Pieces

    private func group<Content: View>(_ heading: String,
                                      @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading)
                .font(style.font(10, weight: .semibold))
                .tracking(style.monospaced ? 2.2 : 1.4)
                .foregroundColor(style.accent)
            Rectangle().fill(style.rule).frame(height: 1)
            body()
        }
    }

    /// A switch, written the way the language writes one.
    @ViewBuilder private func switchGlyph(_ on: Bool) -> some View {
        if style.bracketSelection {
            Text(on ? "[x]" : "[ ]").font(mono).foregroundColor(on ? style.accent : style.dim)
        } else {
            RoundedRectangle(cornerRadius: 7)
                .fill(on ? style.accent : style.dim.opacity(0.35))
                .frame(width: 26, height: 15)
                .overlay(
                    Circle().fill(.white).frame(width: 11, height: 11)
                        .offset(x: on ? 5.5 : -5.5)
                )
        }
    }

    private func switchRow(_ title: String, id: String) -> some View {
        let feature = registry.feature(id: id)
        let on = feature?.isEnabled == true
        return HStack {
            switchGlyph(on)
            Text(title).font(mono).foregroundColor(style.text)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { feature?.setEnabled(!on) }
    }

    private func toggleRow(_ title: String, isOn: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack {
            switchGlyph(isOn)
            Text(title).font(mono).foregroundColor(style.text)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { set(!isOn) }
    }

    private func segmented(_ options: [String: String], selected: String,
                           _ set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 14) {
            ForEach(options.sorted(by: { $0.value < $1.value }), id: \.key) { label, tag in
                let active = tag == selected
                // Brackets rather than a filled pill: in a monospaced setting
                // they are how selection has always been written, and they cost
                // no colour.
                Text(style.bracketSelection ? (active ? "[ \(label) ]" : "  \(label)  ") : label)
                    .font(mono)
                    .foregroundColor(active ? (style.filledSelection ? .white : style.accent) : style.dim)
                    .padding(.horizontal, style.bracketSelection ? 0 : 10)
                    .padding(.vertical, style.bracketSelection ? 0 : 4)
                    .background(
                        style.filledSelection && active
                            ? AnyView(RoundedRectangle(cornerRadius: 5).fill(style.accent))
                            : AnyView(Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { set(tag) }
            }
            Spacer()
        }
    }

    private func valueRow(_ title: String, value: Double, unit: String,
                          range: ClosedRange<Double>,
                          _ set: @escaping (Double) -> Void) -> some View {
        // Every part has a fixed width and the row as a whole is bounded, so
        // the unit cannot be pushed off the edge by a long label — which is
        // exactly what happened when the row was free to grow.
        HStack(spacing: 14) {
            Text(title).font(mono).foregroundColor(style.text)
                .frame(width: 220, alignment: .leading)
            TerminalSlider(value: value, range: range, style: style, set: set)
                .frame(width: 250, height: 18)
            Text(String(format: "%.0f", value))
                .font(style.numberFont(12)).foregroundColor(style.text)
                .frame(width: 52, alignment: .trailing)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .overlay(
                    // A box, because this is a field you can type into — the
                    // border is what says so.
                    Rectangle().stroke(style.rule, lineWidth: 1)
                )
            Text(unit).font(mono).foregroundColor(style.dim)
                .frame(width: 26, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 660, alignment: .leading)
    }

    private func statement(_ text: String) -> some View {
        Text(text).font(mono).foregroundColor(style.dim)
            .fixedSize(horizontal: false, vertical: true)
    }
}


/// A slider drawn to match the rest.
///
/// The system one on macOS ignores `accentColor` and keeps its blue fill and
/// round grey knob, which in a monospaced green panel reads as a control
/// borrowed from another application. This is a thin rule with a square knob —
/// the same square the text is set on.
private struct TerminalSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let style: PreviewStyle
    let set: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let span = max(0.0001, range.upperBound - range.lowerBound)
            let fraction = min(1, max(0, (value - range.lowerBound) / span))
            let knob: CGFloat = 9
            let travel = max(0, geometry.size.width - knob)
            let x = travel * CGFloat(fraction)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(style.rule)
                    .frame(height: style.monospaced ? 1 : 3)
                Capsule()
                    .fill(style.accent.opacity(style.monospaced ? 0.55 : 1))
                    .frame(width: x + knob / 2, height: style.monospaced ? 1 : 3)
                // A square in a monospaced setting, a disc elsewhere: the knob
                // should be made of the same geometry as everything around it.
                Group {
                    if style.monospaced {
                        Rectangle().fill(style.accent)
                    } else {
                        Circle().fill(.white).shadow(radius: 1)
                    }
                }
                .frame(width: knob, height: knob)
                .offset(x: x)
            }
            .frame(height: geometry.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let position = min(max(0, drag.location.x - knob / 2), travel)
                    let f = travel > 0 ? Double(position / travel) : 0
                    set(range.lowerBound + f * span)
                }
            )
        }
    }
}
