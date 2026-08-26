import AppKit
import SwiftUI

/// How the settings window arranges itself.
///
/// Three, and only three, because each one is a different answer to the same
/// question rather than a different colour: tabs put every section one click
/// away and run out of room at about ten; a sidebar has no such limit and has
/// somewhere to put a permanent readout; and the terminal is the sidebar again
/// for people who would rather read a machine than a brochure.
///
/// Deliberately separate from light and dark. Both are honest preferences and
/// neither implies the other — a sidebar in the dark is a normal thing to want.
enum WindowLayout: String, CaseIterable, Identifiable {
    case classic, quiet, terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .quiet: return "Quiet"
        case .terminal: return "Terminal"
        }
    }

    var explanation: String {
        switch self {
        case .classic:
            return "Tabs across the top, one per feature. What Zephyr has always looked like."
        case .quiet:
            return "Sections down the side, merged by meaning, with the full reading kept in the corner."
        case .terminal:
            return "The same sidebar, set in a monospaced face with the readings in aligned columns."
        }
    }

    var usesSidebar: Bool { self != .classic }
    var monospaced: Bool { self == .terminal }
}

/// The colours one layout is drawn in, resolved against light or dark.
///
/// Fixed palettes were tried first and were wrong in the obvious way: a light
/// panel keeps its light ground when the Mac is dark, and every native control
/// inside it — the pickers, the sliders, the checkboxes — still draws itself
/// for dark. The result is grey-on-grey text nobody chose. So each layout
/// states both of its faces and the appearance picks one.
struct LayoutPalette {
    let ground: Color
    let panel: Color
    let text: Color
    let dim: Color
    let accent: Color
    let rule: Color

    static func of(_ layout: WindowLayout, dark: Bool) -> LayoutPalette {
        switch (layout, dark) {
        case (.classic, _):
            // Nothing of its own: the classic window is the system's, and
            // painting a ground under it is how an app starts looking foreign.
            return LayoutPalette(ground: Color(NSColor.windowBackgroundColor),
                                 panel: Color(NSColor.underPageBackgroundColor),
                                 text: Color(NSColor.labelColor),
                                 dim: Color(NSColor.secondaryLabelColor),
                                 accent: Color(NSColor.controlAccentColor),
                                 rule: Color(NSColor.separatorColor))
        case (.quiet, false):
            return LayoutPalette(ground: Color(red: 0.980, green: 0.976, blue: 0.965),
                                 panel: Color(red: 0.965, green: 0.960, blue: 0.947),
                                 text: Color(white: 0.10), dim: Color(white: 0.45),
                                 accent: Color(red: 0.30, green: 0.33, blue: 0.55),
                                 rule: Color(white: 0).opacity(0.10))
        case (.quiet, true):
            return LayoutPalette(ground: Color(red: 0.118, green: 0.117, blue: 0.113),
                                 panel: Color(red: 0.145, green: 0.143, blue: 0.138),
                                 text: Color(white: 0.93), dim: Color(white: 0.58),
                                 accent: Color(red: 0.65, green: 0.68, blue: 0.90),
                                 rule: Color(white: 1).opacity(0.10))
        case (.terminal, false):
            // A light terminal is not a contradiction — it is what a printed
            // listing looks like. The accent stays green so the two faces of
            // this layout are recognisably the same one.
            return LayoutPalette(ground: Color(red: 0.976, green: 0.968, blue: 0.945),
                                 panel: Color(red: 0.957, green: 0.945, blue: 0.917),
                                 text: Color(white: 0.12), dim: Color(white: 0.45),
                                 accent: Color(red: 0.16, green: 0.45, blue: 0.24),
                                 rule: Color(white: 0).opacity(0.14))
        case (.terminal, true):
            return LayoutPalette(ground: Color(red: 0.043, green: 0.043, blue: 0.043),
                                 panel: Color(red: 0.070, green: 0.070, blue: 0.070),
                                 text: Color(white: 0.92), dim: Color(white: 0.55),
                                 // Muted rather than phosphor: a bright green
                                 // over a whole window stops meaning "this is
                                 // on" and starts meaning "this is a costume".
                                 accent: Color(red: 0.49, green: 0.83, blue: 0.56),
                                 rule: Color(white: 1).opacity(0.12))
        }
    }
}

/// The sections a sidebar shows, after merging the ten tabs by meaning.
///
/// A sidebar can hold ten rows perfectly well — the merge is not about room.
/// It is that Cooling and Power are one subject, and so are Keyboard and
/// Pointer, and a list that says so is quicker to search than one that makes
/// you remember which tab the fan curve was under.
enum SettingsSection: String, CaseIterable, Identifiable {
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

/// The whole window, when a sidebar is chosen.
///
/// The controls inside are the shipping ones, unchanged and native. Only the
/// frame around them is ours: the list, the headings, the readout in the
/// corner. Re-drawing every slider and picker in a house style was tried in
/// the prototype and is exactly how an app ends up with controls that look
/// almost right and behave subtly differently from every other app on the Mac.
struct SidebarSettingsView: View {
    @ObservedObject var registry: FeatureRegistry
    @ObservedObject var telemetry: Telemetry
    let helperState: HelperState
    let layout: WindowLayout
    @Binding var selection: String
    @Environment(\.colorScheme) private var scheme

    private var palette: LayoutPalette { .of(layout, dark: scheme == .dark) }
    private var section: SettingsSection {
        SettingsSection(rawValue: selection) ?? .thermals
    }

    private func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        layout.monospaced
            ? .system(size: size, weight: weight, design: .monospaced)
            : .system(size: size, weight: weight)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(palette.rule).frame(width: 1)
            content
        }
        .background(palette.ground)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Zephyr")
                .font(font(12))
                .foregroundColor(palette.dim)
                .padding(.leading, 20)
                .padding(.bottom, 12)

            ForEach(SettingsSection.allCases) { section in
                row(section)
            }
            Spacer(minLength: 12)
            statusBlock
        }
        .padding(.vertical, 16)
        .frame(width: 228, alignment: .leading)
        .background(palette.panel)
    }

    private func row(_ item: SettingsSection) -> some View {
        // No switch in the list. It duplicated the one at the top of the
        // section, and two controls for one thing means guessing which is
        // authoritative the first time they disagree.
        let isSelected = section == item
        return HStack(spacing: 6) {
            if layout.monospaced {
                // In a monospaced list the marker is a character, so every
                // label keeps the same left edge.
                Text(isSelected ? "›" : " ").font(font(12)).foregroundColor(palette.accent)
            }
            Text(item.title)
                .font(font(12))
                .foregroundColor(isSelected && layout.monospaced ? palette.accent : palette.text)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(!layout.monospaced && isSelected
                    ? palette.accent.opacity(0.20) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = item.rawValue }
    }

    /// The full reading, at the foot of the sidebar.
    ///
    /// It overlaps the menu bar, and that is the point rather than a fault:
    /// the menu bar is a glance and holds five or six values chosen by hand,
    /// while this is everything the machine is reporting. A summary and its
    /// detail are supposed to agree.
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle().fill(palette.rule).frame(height: 1).padding(.bottom, 6)
            ForEach(StatusReadout.lines(telemetry: telemetry), id: \.self) { line in
                Text(line)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(palette.text)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(section.title)
                    .font(font(19, .medium))
                    .foregroundColor(palette.text)

                switch section {
                case .menuBar:
                    MenuBarTab(telemetry: telemetry)
                case .settings:
                    AppSettingsSection(helperState: helperState)
                default:
                    ForEach(section.featureIDs, id: \.self) { id in
                        if let feature = registry.feature(id: id) {
                            FeatureBlock(feature: feature, showsTitle: section.featureIDs.count > 1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One feature, with its own switch — the same block whether it is alone in a
/// tab or stacked with another in a section.
struct FeatureBlock: View {
    @ObservedObject var feature: Feature
    /// Shown when a section holds more than one, because "Enable Cooling"
    /// above "Enable Power" is otherwise the only thing saying where one ends.
    var showsTitle: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if feature.isSupported {
                if showsTitle {
                    Text(feature.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.4)
                        .foregroundColor(.secondary)
                }
                Toggle(isOn: Binding(get: { feature.isEnabled },
                                     set: { feature.setEnabled($0) })) {
                    Text("Enable \(feature.title)").font(.headline)
                }
                Text(feature.summary)
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                feature.makeView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(!feature.isEnabled)
                    .opacity(feature.isEnabled ? 1 : 0.4)
            } else {
                Text(feature.title).font(.headline)
                Text(feature.unsupportedReason ?? "Not available on this Mac.")
                    .font(.subheadline).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 6)
    }
}

/// About the app rather than about the machine: how it looks, whether it
/// starts itself, and whether the part that needs root is answering.
struct AppSettingsSection: View {
    let helperState: HelperState
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Layout").font(.headline)
            Picker("", selection: Binding(
                get: { Preferences.windowLayout },
                set: { Preferences.windowLayout = $0; SettingsWindowController.layoutDidChange() }
            )) {
                ForEach(WindowLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(SegmentedPickerStyle())
            .labelsHidden()
            Text(Preferences.windowLayout.explanation)
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The controls themselves stay the system's in every layout. A slider drawn by hand looks nearly right and then behaves differently from every other slider on the Mac, which is a worse trade than it sounds.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Appearance").font(.headline)
            Picker("", selection: Binding(
                get: { Preferences.appearance },
                set: { Preferences.appearance = $0; AppearanceControl.apply(); revision += 1 }
            )) {
                Text("Light").tag("light")
                Text("System").tag("system")
                Text("Dark").tag("dark")
            }
            .pickerStyle(SegmentedPickerStyle())
            .labelsHidden()
            Text("System follows whatever the Mac is set to. The menu-bar readout is not affected: it always follows the menu bar's own appearance, which is not always the window's.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Startup").font(.headline)
            Toggle("Launch at login", isOn: Binding(
                get: { LaunchAtLogin.isEnabled },
                set: { LaunchAtLogin.setEnabled($0); revision += 1 }
            ))

            Divider()
            Text("Helper").font(.headline)
            Text(helperState.summary)
                .font(.subheadline)
                .foregroundColor(helperState.isWorking ? .secondary : .orange)
            Text("Fans, graphics, Turbo Boost, the charge ceiling and the power limits all write to hardware, which needs root. Everything else works without it.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .id(revision)
    }
}

/// The lines of the corner readout, composed as whole strings.
///
/// Whole strings rather than a grid of views so the columns line up by
/// character count, which is what a monospaced face is for. Laying them out as
/// separate views needs a width guessed per column, and the guess drifts the
/// moment a value gains a digit.
enum StatusReadout {
    static func lines(telemetry: Telemetry) -> [String] {
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
        // Not the live clock — macOS on Intel does not publish one — so this is
        // the ceiling being permitted, not the speed being run.
        let cpuTemp = telemetry.cpuTemperature.map { String(format: "%.0f°C", $0.celsius) } ?? "—"
        let cpuLoad = telemetry.load.map { "\(Int(($0.total * 100).rounded()))%" } ?? "—"
        var cpuGHz = "—"
        if let limit = telemetry.thermal?.speedLimitPercent, SystemLoad.nominalHz > 0 {
            cpuGHz = String(format: "%.1f GHz", Double(SystemLoad.nominalHz) / 1e9 * Double(limit) / 100)
        }
        lines.append(pad("CPU", 5) + right(cpuTemp, 6) + right(cpuLoad, 6) + right(cpuGHz, 9))

        // GPU has no frequency here: the accelerator does not publish one on
        // this hardware, and a dash is more honest than a number from elsewhere.
        let gpuTemp = telemetry.temperatures.first { $0.key == "TG0P" }
            .map { String(format: "%.0f°C", $0.celsius) } ?? "—"
        let gpuLoad = telemetry.load?.gpuFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        lines.append(pad("GPU", 5) + right(gpuTemp, 6) + right(gpuLoad, 6) + right("—", 9))

        if let load = telemetry.load, load.memoryTotal > 0 {
            let ram = "\(gb(load.memoryUsed))/\(gb(load.memoryTotal)) GB"
            lines.append(pad("RAM", 5) + right(ram, 12) + right("\(Int((load.memoryFraction * 100).rounded()))%", 9))
        }
        // Read directly rather than out of the load snapshot: disk usage is a
        // single reading and has no business waiting for the second poll that a
        // rate like CPU load needs.
        if let disk = SystemLoad.diskUsage() {
            let rom = "\(gb(disk.usedBytes))/\(gb(disk.totalBytes)) GB"
            lines.append(pad("ROM", 5) + right(rom, 12) + right("\(Int((disk.fraction * 100).rounded()))%", 9))
        }
        if let network = telemetry.network {
            lines.append(pad("NET", 5)
                         + right("↓" + NetworkThroughput.format(network.downloadBytes), 11)
                         + right("↑" + NetworkThroughput.format(network.uploadBytes), 11))
        }
        if let battery = telemetry.battery {
            // Time only while the system is willing to estimate it — on the
            // charger there is nothing to count down to.
            let remaining = battery.minutesRemaining.map { "\($0 / 60)h \($0 % 60)m" }
                ?? (battery.isCharging ? "charging" : "—")
            lines.append(pad("BAT", 5) + right("\(battery.percent)%", 6) + right(remaining, 15))
        }
        return lines
    }
}
