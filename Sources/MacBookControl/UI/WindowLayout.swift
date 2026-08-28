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

    /// `pitch` is the Darkness setting: the same dark palette taken all the
    /// way to black. Kept as a flag on top of `dark` rather than a third
    /// appearance, because to the system it *is* dark — only these colours
    /// change.
    static func of(_ layout: WindowLayout, dark: Bool, pitch: Bool = false) -> LayoutPalette {
        if pitch, dark || layout == .terminal { return blackened(layout) }
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

extension LayoutPalette {
    /// Black, with the panel lifted by the smallest amount that still reads as
    /// a separate surface. Flat black on flat black would lose the sidebar
    /// entirely, so the rule does the separating instead of the fill.
    static func blackened(_ layout: WindowLayout) -> LayoutPalette {
        let accent: Color = layout == .terminal
            ? Color(red: 0.49, green: 0.83, blue: 0.56)
            : (layout == .quiet ? Color(red: 0.65, green: 0.68, blue: 0.90)
                                : Color(NSColor.controlAccentColor))
        return LayoutPalette(ground: .black,
                             panel: Color(white: 0.027),
                             text: Color(white: 0.92),
                             dim: Color(white: 0.52),
                             accent: accent,
                             rule: Color(white: 1).opacity(0.16))
    }
}

/// The sections a sidebar shows, after merging the ten tabs by meaning.
///
/// A sidebar can hold ten rows perfectly well — the merge is not about room.
/// It is that Cooling and Power are one subject, and so are Keyboard and
/// Pointer, and a list that says so is quicker to search than one that makes
/// you remember which tab the fan curve was under.
enum SettingsSection: String, CaseIterable, Identifiable {
    case thermals, graphics, batterySleep, display, input, diagnostics, menuBar, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thermals: return "Thermals"
        case .graphics: return "Graphics"
        case .batterySleep: return "Battery & Sleep"
        case .display: return "Display"
        case .input: return "Input"
        case .diagnostics: return "Diagnostics"
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
        case .thermals: return ["cooling", "turbo", "powerlimit"]
        case .graphics: return ["graphics"]
        case .batterySleep: return ["battery", "awake"]
        case .display: return ["display"]
        case .input: return ["keyboard", "pointer"]
        // Nothing to switch: this section only reads.
        case .diagnostics: return []
        case .menuBar: return []
        // Rules that apply settings by themselves belong with the settings.
        case .settings: return ["profiles"]
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

    private var palette: LayoutPalette {
        // `scheme` is observed but not consulted: it is what makes SwiftUI
        // redraw this view when the Mac flips between light and dark, while
        // the answer itself comes from the setting.
        _ = scheme
        return .of(layout, dark: AppearanceControl.isDark,
                   pitch: AppearanceControl.isPitchBlack)
    }
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
        // Told to fill the window. Without this the row is only as wide as
        // what is in it and SwiftUI centres the remainder — so the sidebar
        // slid sideways whenever a section's content happened to be narrower,
        // and again whenever a reading in the corner gained a digit.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(palette.ground)
        .modifier(MonospacedThroughout(on: layout.monospaced))
        // Read by every control underneath, including the ones inside the
        // feature views this file knows nothing about.
        .environment(\.terminalStyling, layout.monospaced)
        .environment(\.readoutInSidebar, true)
        .environment(\.terminalPalette, palette)
        .modifier(TerminalControlStyles(on: layout.monospaced, palette: palette))
        // Without this the window's safe area keeps the whole hierarchy below
        // the title bar — which is why removing the title bar left a bare grey
        // strip where it used to be instead of the sidebar reaching the top.
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Beside the close/minimise/zoom buttons rather than under them.
            // The window's own title bar is gone in this layout, so the name
            // has to be put back by hand — and the only place it can go is the
            // strip those three buttons already occupy.
            // Room for the three window buttons and nothing else. The name
            // used to sit here and was a constant argument about whether it
            // lined up with the section title opposite: two labels of
            // different sizes and colours on one line look wrong even when
            // their baselines agree exactly. It says its piece at the foot of
            // Settings now, where it has nothing to line up with.
            Color.clear.frame(height: Self.titlebarHeight)

            ForEach(SettingsSection.allCases) { section in
                row(section)
            }
            Spacer(minLength: 12)
            statusBlock
        }
        .frame(width: 228, alignment: .leading)
        .background(palette.panel)
    }

    /// How far in the three window buttons reach. Measured rather than
    /// guessed would be better, but they are drawn by the system into a
    /// titlebar view that does not exist to ask while the content is being
    /// laid out — and this number has not changed in a decade of macOS.
    ///
    /// The three buttons start 20 points in and end 72 points in; the name
    /// begins one full margin after that, so the space to their right matches
    /// the space to their left.
    private static let trafficLightWidth: CGFloat = 92

    /// The height of a unified titlebar. Not a guess about a drawing: it is
    /// the size AppKit gives that style, and the buttons are centred in it.
    private static let titlebarHeight: CGFloat = 52

    /// Where the section's name starts: centred in the same band the window
    /// buttons are centred in, so it sits level with them.
    ///
    /// Computed from the font rather than nudged by eye, which is what made
    /// this the third round of moving a title up and down.
    private var titleTopInset: CGFloat {
        let title: NSFont = layout.monospaced
            ? .monospacedSystemFont(ofSize: 19, weight: .medium)
            : .systemFont(ofSize: 19, weight: .medium)
        return max(0, (Self.titlebarHeight - (title.ascender - title.descender)) / 2)
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
        // The rule runs the full width of the sidebar and the readings are
        // inset by the same amount on all four sides. Before, the rule was
        // inset with the text and the gap below the last line was whatever the
        // sidebar's own padding happened to be, which is why the block looked
        // hung rather than placed.
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(palette.rule).frame(height: 1)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(StatusReadout.lines(telemetry: telemetry), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(palette.text)
                        // One line each, always. Twenty-nine characters at
                        // this size is within a hair of the sidebar's width,
                        // and a hair was enough to fold every other row onto
                        // two lines.
                        .lineLimit(1)
                }
            }
            // Centred rather than padded. Every line is the same number of
            // characters, so centring the block puts exactly the same gap on
            // both sides — which a fixed inset cannot do, since it would have
            // to know the width of a character to match the slack left over
            // on the right.
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 14)
        }
    }

    // MARK: Content

    private var content: some View {
        // A scroll view that mostly does not scroll. The window is one fixed
        // size and every section but Input fits inside it — and macOS only
        // draws a scrollbar when there is somewhere to scroll to, so the ones
        // that fit show none. `--measure-sections` says which is which.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(section.title)
                    .font(font(19, .medium))
                    .foregroundColor(palette.text)

                switch section {
                case .diagnostics:
                    DiagnosticsSection(telemetry: telemetry)
                case .menuBar:
                    MenuBarTab(telemetry: telemetry)
                case .settings:
                    ForEach(section.featureIDs, id: \.self) { id in
                        if let feature = registry.feature(id: id) {
                            FeatureBlock(feature: feature, showsTitle: true)
                        }
                    }
                    AppSettingsSection(helperState: helperState)
                default:
                    ForEach(section.featureIDs, id: \.self) { id in
                        if let feature = registry.feature(id: id) {
                            FeatureBlock(feature: feature,
                                         showsTitle: section.featureIDs.count > 1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: titleTopInset, leading: 24, bottom: 24, trailing: 24))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Sets every font in the hierarchy monospaced, including the ones the views
/// underneath choose for themselves.
///
/// A plain `.font()` would not do: it is only a default, and every `.caption`
/// and `.headline` already stated inside the feature views overrides it. This
/// changes the design of whatever font each of them picked and leaves the size
/// and weight alone, which is the only way to reach controls this file does
/// not own.
/// Applies the bracket switch and the bracket button to the whole hierarchy,
/// or leaves the system's own alone. Separate from the environment flag
/// because a style cannot be chosen conditionally inside one modifier chain.
struct TerminalControlStyles: ViewModifier {
    let on: Bool
    let palette: LayoutPalette

    @ViewBuilder func body(content: Content) -> some View {
        if on {
            content
                .toggleStyle(BracketToggleStyle(palette: palette))
                .buttonStyle(BracketButtonStyle(palette: palette))
        } else {
            content
        }
    }
}

struct MonospacedThroughout: ViewModifier {
    let on: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if on, #available(macOS 14.0, *) {
            content.fontDesign(.monospaced)
        } else {
            content
        }
    }
}

/// One feature, with its own switch — the same block whether it is alone in a
/// tab or stacked with another in a section.
struct FeatureBlock: View {
    @ObservedObject var feature: Feature
    @Environment(\.terminalStyling) private var terminal
    @Environment(\.terminalPalette) private var palette
    /// Shown when a section holds more than one, because "Enable Cooling"
    /// above "Enable Power" is otherwise the only thing saying where one ends.
    var showsTitle: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if feature.isSupported {
                if terminal {
                    // The block's name is the switch. Two rows saying the same
                    // thing — a heading, then "Enable <that heading>" directly
                    // under it — is one row too many when the heading is right
                    // there to be switched.
                    Toggle(isOn: Binding(get: { feature.isEnabled },
                                         set: { feature.setEnabled($0) })) {
                        SectionHeading(text: feature.title.uppercased())
                    }
                } else {
                    if showsTitle {
                        SectionHeading(text: feature.title.uppercased())
                    }
                    Toggle(isOn: Binding(get: { feature.isEnabled },
                                         set: { feature.setEnabled($0) })) {
                        Text("Enable \(feature.title)").font(.headline)
                    }
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
            SegmentedChoice(label: "Layout",
                            selection: Binding(
                                get: { Preferences.windowLayout },
                                set: { Preferences.windowLayout = $0
                                       SettingsWindowController.layoutDidChange() }),
                            options: WindowLayout.allCases.map { ($0.title, $0) })
            Text(Preferences.windowLayout.explanation)
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The controls themselves stay the system's in every layout. A slider drawn by hand looks nearly right and then behaves differently from every other slider on the Mac, which is a worse trade than it sounds.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Reading the machine").font(.headline)
            ValueField(title: "In this window, every", range: 0.5...10, step: 0.5,
                       suffix: "s",
                       value: Binding(get: { Preferences.windowPollSeconds },
                                      set: { Preferences.windowPollSeconds = $0
                                             SettingsWindowController.pollingDidChange() }))
            ValueField(title: "In the menu bar, every", range: 1...60, step: 1,
                       suffix: "s",
                       value: Binding(get: { Preferences.menuBarPollSeconds },
                                      set: { Preferences.menuBarPollSeconds = $0
                                             SettingsWindowController.pollingDidChange() }))
            Text("One sweep serves both, taken at whichever rate wants it sooner — reading the same sensors twice on two schedules would cost twice as much to learn the same numbers. What the second setting buys is the case worth saving: with this window shut, the machine is read at the menu bar's rate and no faster.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("A sweep of this machine's sensors takes about 45 ms. Half a second between them is comfortable; it is offered because a fan curve being tuned is worth watching closely, not because anything here needs it.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            SegmentedChoice(label: "Appearance",
                            selection: Binding(
                                get: { Preferences.appearance },
                                set: { Preferences.appearance = $0
                                       AppearanceControl.apply()
                                       // A rebuild, not a redraw: the palettes
                                       // and the window's own fill are both
                                       // read once, when the window is built.
                                       SettingsWindowController.layoutDidChange()
                                       revision += 1 }),
                            options: [("Light", "light"), ("System", "system"),
                                      ("Dark", "dark"), ("Darkness", "darkness")])
            Text("System follows whatever the Mac is set to. Darkness is Dark taken to actual black, which on this panel is a pixel that is off rather than a dark grey one. The menu-bar readout is not affected by any of them: it always follows the menu bar's own appearance, which is not always the window's.")
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

            Divider()
            // The version comes from the bundle, not from a constant here: a
            // number written twice is a number that will disagree with itself
            // one release from now.
            Text("Zephyr by n0ctal · v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
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
        // Every line is exactly `width` characters, so the block has the same
        // margin on the right as on the left. Left to their natural lengths
        // they stopped short of the edge by a different amount each.
        lines.append(pad("CPU", 5) + right(cpuTemp, 7) + right(cpuLoad, 7) + right(cpuGHz, 10))
        // Whether the firmware is holding the CPU back, as a line rather than
        // a paragraph of its own. It belongs with the readings for the same
        // reason they do: it is something the machine is doing, not something
        // to set, and it is worth seeing from whichever section is open.
        if let thermal = telemetry.thermal, let limit = thermal.speedLimitPercent {
            // The last column is the speed the firmware is allowing, which is
            // the number Hot shows — not load, which is already on the CPU
            // line above. It was a dash whenever nothing had been capped yet,
            // which said nothing at all and was the most common case.
            var detail = "\(limit) %"
            if telemetry.stats.everThrottled {
                detail += " · low \(telemetry.stats.lowestSpeedLimit) %"
            }
            lines.append(pad("THR", 5)
                         + right(thermal.isThrottling ? "Yes" : "No", 7)
                         + right(detail, 17))
        } else {
            lines.append(pad("THR", 5) + right("—", 7) + right("—", 17))
        }


        // GPU has no frequency here: the accelerator does not publish one on
        // this hardware, and a dash is more honest than a number from elsewhere.
        // The card that is doing the work, not always the discrete one. With
        // the discrete card asleep its board sensor still reports a plausible
        // number — it tracks the machine's general heat — so showing it would
        // be a reading that looks right and describes nothing.
        let gpuKey = telemetry.load?.gpuIsDiscrete == false ? "TCGC" : "TG0P"
        let gpuTemp = telemetry.temperatures.first { $0.key == gpuKey }
            .map { String(format: "%.0f°C", $0.celsius) } ?? "—"
        let gpuLoad = telemetry.load?.gpuFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        lines.append(pad("GPU", 5) + right(gpuTemp, 7) + right(gpuLoad, 7) + right("—", 10))

        if let load = telemetry.load, load.memoryTotal > 0 {
            let ram = "\(gb(load.memoryUsed))/\(gb(load.memoryTotal)) GB"
            lines.append(pad("RAM", 5) + right(ram, 13) + right("\(Int((load.memoryFraction * 100).rounded()))%", 11))
        }
        // Read directly rather than out of the load snapshot: disk usage is a
        // single reading and has no business waiting for the second poll that a
        // rate like CPU load needs.
        if let disk = SystemLoad.diskUsage() {
            let rom = "\(gb(disk.usedBytes))/\(gb(disk.totalBytes)) GB"
            lines.append(pad("ROM", 5) + right(rom, 13) + right("\(Int((disk.fraction * 100).rounded()))%", 11))
        }
        if let network = telemetry.network {
            lines.append(pad("NET", 5)
                         + right("↓" + NetworkThroughput.format(network.downloadBytes), 12)
                         + right("↑" + NetworkThroughput.format(network.uploadBytes), 12))
        }
        // What the machine is drawing and what the charger is supplying, one
        // line split down the middle. Two figures that only mean something
        // next to each other: the difference between them is the battery.
        if let draw = telemetry.battery?.power {
            let system = draw.systemWatts.map { String(format: "%.1f W", $0) } ?? "—"
            let adapter = draw.adapterWatts.map { String(format: "%.1f W", $0) } ?? "—"
            lines.append(pad("PWR", 5) + right(system, 9) + pad("  ADP", 6) + right(adapter, 9))
        }

        if let battery = telemetry.battery {
            // Time only while the system is willing to estimate it — on the
            // charger there is nothing to count down to.
            let remaining = battery.minutesRemaining.map { "\($0 / 60)h \($0 % 60)m" }
                ?? (battery.isCharging ? "charging" : "—")
            lines.append(pad("BAT", 5) + right("\(battery.percent)%", 7) + right(remaining, 17))
        }
        return lines
    }
}
