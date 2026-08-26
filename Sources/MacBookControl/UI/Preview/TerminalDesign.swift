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
enum TerminalPalette {
    static let ground = Color(red: 0.043, green: 0.043, blue: 0.043)
    static let panel = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let text = Color(white: 0.92)
    static let dim = Color(white: 0.55)
    /// Muted rather than phosphor: a bright green over a whole window stops
    /// meaning "this is on" and starts meaning "this is a terminal costume".
    static let accent = Color(red: 0.49, green: 0.83, blue: 0.56)
    static let rule = Color(white: 1).opacity(0.12)
}

/// The seven sections, after merging the ten tabs by meaning.
enum PreviewSection: String, CaseIterable, Identifiable {
    case thermals, graphics, batterySleep, display, input, profiles, menuBar

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
        case .menuBar: return []
        }
    }
}

struct TerminalDesignView: View {
    @ObservedObject var registry: FeatureRegistry
    @ObservedObject var telemetry: Telemetry
    @State private var selection: PreviewSection = .thermals

    private let mono = Font.system(size: 12, design: .monospaced)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(TerminalPalette.rule).frame(width: 1)
            content
        }
        .background(TerminalPalette.ground)
        .frame(minWidth: 880, minHeight: 620)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Zephyr")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(TerminalPalette.dim)
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
        .background(TerminalPalette.panel)
    }

    private func sidebarRow(_ section: PreviewSection) -> some View {
        let isSelected = selection == section
        let on = section.featureIDs.contains { registry.feature(id: $0)?.isEnabled == true }
        return HStack(spacing: 6) {
            // The marker is a character, not a filled bar: in a monospaced
            // list a glyph keeps the left edge of every label aligned.
            Text(isSelected ? "›" : " ")
                .font(mono)
                .foregroundColor(TerminalPalette.accent)
            Text(section.title)
                .font(mono)
                .foregroundColor(isSelected ? TerminalPalette.accent : TerminalPalette.text)
            Spacer()
            if !section.featureIDs.isEmpty {
                Text(on ? "[x]" : "[ ]")
                    .font(mono)
                    .foregroundColor(on ? TerminalPalette.accent : TerminalPalette.dim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { selection = section }
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
            Rectangle().fill(TerminalPalette.rule).frame(height: 1)
                .padding(.bottom, 6)
            ForEach(statusLines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TerminalPalette.text)
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
                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalPalette.text)

                switch selection {
                case .thermals: thermals
                default: placeholder
                }
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

    private var placeholder: some View {
        Text("This section is not part of the prototype. Only Thermals is wired, because one section fully working says more about the design than seven half-drawn ones.")
            .font(mono)
            .foregroundColor(TerminalPalette.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Pieces

    private func group<Content: View>(_ heading: String,
                                      @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2.2)
                .foregroundColor(TerminalPalette.accent)
            Rectangle().fill(TerminalPalette.rule).frame(height: 1)
            body()
        }
    }

    private func switchRow(_ title: String, id: String) -> some View {
        let feature = registry.feature(id: id)
        let on = feature?.isEnabled == true
        return HStack {
            Text(on ? "[x]" : "[ ]")
                .font(mono).foregroundColor(on ? TerminalPalette.accent : TerminalPalette.dim)
            Text(title).font(mono).foregroundColor(TerminalPalette.text)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { feature?.setEnabled(!on) }
    }

    private func toggleRow(_ title: String, isOn: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(isOn ? "[x]" : "[ ]")
                .font(mono).foregroundColor(isOn ? TerminalPalette.accent : TerminalPalette.dim)
            Text(title).font(mono).foregroundColor(TerminalPalette.text)
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
                Text(active ? "[ \(label) ]" : "  \(label)  ")
                    .font(mono)
                    .foregroundColor(active ? TerminalPalette.accent : TerminalPalette.dim)
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
            Text(title).font(mono).foregroundColor(TerminalPalette.text)
                .frame(width: 220, alignment: .leading)
            TerminalSlider(value: value, range: range, set: set)
                .frame(width: 250, height: 18)
            Text(String(format: "%.0f", value))
                .font(mono).foregroundColor(TerminalPalette.text)
                .frame(width: 52, alignment: .trailing)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .overlay(
                    // A box, because this is a field you can type into — the
                    // border is what says so.
                    Rectangle().stroke(TerminalPalette.rule, lineWidth: 1)
                )
            Text(unit).font(mono).foregroundColor(TerminalPalette.dim)
                .frame(width: 26, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 660, alignment: .leading)
    }

    private func statement(_ text: String) -> some View {
        Text(text).font(mono).foregroundColor(TerminalPalette.dim)
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
    let set: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let span = max(0.0001, range.upperBound - range.lowerBound)
            let fraction = min(1, max(0, (value - range.lowerBound) / span))
            let knob: CGFloat = 9
            let travel = max(0, geometry.size.width - knob)
            let x = travel * CGFloat(fraction)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(TerminalPalette.rule)
                    .frame(height: 1)
                Rectangle()
                    .fill(TerminalPalette.accent.opacity(0.55))
                    .frame(width: x + knob / 2, height: 1)
                Rectangle()
                    .fill(TerminalPalette.accent)
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
