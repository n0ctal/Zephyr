import AppKit
import SwiftUI

/// The Settings window: one tab per feature, each gated by its own checkbox.
///
/// The window is the whole interface. The menu-bar menu deliberately stays at
/// four items, so anything that needs a control needs a tab here.
final class SettingsWindowController {
    private var window: NSWindow?
    private var hosting: NSHostingController<AnyView>?
    private var context: (registry: FeatureRegistry, telemetry: Telemetry, helperState: HelperState)?

    /// Called by the layout picker, which sits inside the window it is about
    /// to replace. A rebuild rather than a state change because the two
    /// layouts are different view hierarchies, not two states of one.
    static var layoutDidChange: () -> Void = {}

    /// Which tab to open on. Only set by the `--open-settings=<id>` dev flag;
    /// normal launches open on whatever the window remembers.
    static var initialTab: String?

    func show(registry: FeatureRegistry, telemetry: Telemetry, helperState: HelperState) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        context = (registry, telemetry, helperState)
        let hosting = NSHostingController(rootView: makeRoot())
        self.hosting = hosting
        SettingsWindowController.layoutDidChange = { [weak self] in self?.rebuild() }
        let window = NSWindow(contentViewController: hosting)
        window.title = "Zephyr"
        // Resizable because the tabs differ a lot in height: pinning one size
        // either crops the tall ones or leaves the short ones half empty.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        // Wide enough for the eleven tab labels the classic layout carries.
        // Below this the strip truncates them, and "Grap…" beside "Batt…" is
        // worse than a window that takes more of the screen.
        window.setContentSize(NSSize(width: 960, height: 720))
        window.center()
        // Remembers whatever size it is dragged to, so a preference about the
        // window is stated once rather than every launch.
        window.setFrameAutosaveName("ZephyrSettings")
        applyChrome(to: window)
        // Applied again here: setting it during launch can be overwritten
        // before the first window exists.
        AppearanceControl.apply()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    /// For `--dump-real-window` only.
    var windowForTesting: NSWindow? { window }

    private func makeRoot() -> AnyView {
        guard let context = context else { return AnyView(EmptyView()) }
        return AnyView(SettingsRootView(registry: context.registry,
                                        telemetry: context.telemetry,
                                        helperState: context.helperState))
    }

    private func rebuild() {
        hosting?.rootView = makeRoot()
        if let window = window { applyChrome(to: window) }
    }

    /// The title bar, or the absence of one.
    ///
    /// The sidebar layouts run the content to the top edge and put the name
    /// beside the window buttons themselves — a separate grey strip above a
    /// dark sidebar is a band of another application's colour across the top
    /// of this one. The classic layout keeps its title bar, because the row of
    /// tabs would otherwise start underneath those same buttons.
    private func applyChrome(to window: NSWindow) {
        // Not resizable in the sidebar layouts: nothing scrolls, so the window
        // is already exactly the size its content needs, and dragging it
        // smaller could only hide something.
        if Preferences.windowLayout.usesSidebar {
            window.styleMask.remove(.resizable)
        } else {
            window.styleMask.insert(.resizable)
        }
        // The window's own fill shows through wherever the content does not
        // reach — around the tab strip in the classic layout, and behind the
        // title bar in the others. Left as the system's grey it would frame a
        // black window in dark grey.
        window.backgroundColor = AppearanceControl.isPitchBlack
            ? .black : .windowBackgroundColor
        let sidebar = Preferences.windowLayout.usesSidebar
        window.titleVisibility = sidebar ? .hidden : .visible
        window.titlebarAppearsTransparent = sidebar
        if sidebar {
            window.styleMask.insert(.fullSizeContentView)
            // An empty toolbar in the unified style, for one reason: it makes
            // the titlebar taller, and the system centres the three window
            // buttons in whatever height that is. The buttons themselves
            // cannot be moved — they can be dragged around by hand through
            // their superview, but that resets on every resize and on every
            // trip through full screen. Making the strip they live in the
            // right height is the supported way to lower them.
            let toolbar = NSToolbar(identifier: "ZephyrTitlebar")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        } else {
            window.styleMask.remove(.fullSizeContentView)
            window.toolbar = nil
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var registry: FeatureRegistry
    @ObservedObject var telemetry: Telemetry
    let helperState: HelperState
    @State private var selection: String

    init(registry: FeatureRegistry, telemetry: Telemetry, helperState: HelperState) {
        self.registry = registry
        self.telemetry = telemetry
        self.helperState = helperState
        // The two layouts name their destinations differently — one per
        // feature, one per merged section — so a remembered tab from the other
        // one is not a valid answer here.
        let fallback = Preferences.windowLayout.usesSidebar
            ? SettingsSection.thermals.rawValue
            : (registry.features.first?.id ?? "menubar")
        _selection = State(initialValue: SettingsWindowController.initialTab ?? fallback)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !helperState.isWorking { helperBanner }
            if Preferences.windowLayout.usesSidebar {
                SidebarSettingsView(registry: registry, telemetry: telemetry,
                                    helperState: helperState,
                                    layout: Preferences.windowLayout,
                                    selection: $selection)
                    // One fixed width — wide enough for the widest row there
                    // is, Graphics — and no height at all, so the window takes
                    // the height of whichever section is open. With nothing
                    // scrolling, a fixed height would either clip the tallest
                    // section or leave the shortest half empty; this is what
                    // System Settings does with its own panes.
                    .frame(width: 960)
            } else {
                tabs
            }
        }
        // The whole stack, not just the part below the banner. Without this
        // the window's own grey shows in the strip where the title bar used to
        // be — which is the strip the window buttons sit in, so it is the one
        // place the app cannot afford to leave unpainted.
        .modifier(IgnoreTopSafeArea(on: Preferences.windowLayout.usesSidebar))
    }

    /// Above every tab, not inside one. When the helper is not answering,
    /// nothing that touches hardware works — and finding that out one greyed
    /// switch at a time is the worst way to learn it.
    private var helperBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(helperState.summary).font(.headline).foregroundColor(.orange)
            if let explanation = helperState.explanation {
                Text(explanation)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(HelperState.installCommand)
                    .font(.system(.caption, design: .monospaced))
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HelperState.installCommand, forType: .string)
                }
            }
        }
        // The top inset is inside the banner rather than above it, so its
        // colour still runs to the edge of the window: in the sidebar layouts
        // there is no title bar, and the three window buttons sit on top of
        // whatever is drawn up there.
        .padding(EdgeInsets(top: Preferences.windowLayout.usesSidebar ? 58 : 10,
                            leading: 10, bottom: 10, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            ForEach(registry.features, id: \.id) { feature in
                FeatureTab(feature: feature)
                    .tabItem { Text(feature.title) }
                    .tag(feature.id)
            }
            // Scrolled like every feature tab. Without this its content
            // stretched the TabView until the row of tabs was pushed off the
            // top of the window, and the only way back was to guess that the
            // window needed resizing.
            ScrollView { MenuBarTab(telemetry: telemetry) }
                .tabItem { Text("Menu Bar") }
                .tag("menubar")
            // After Menu Bar, and last: it is the only tab that is about the
            // app rather than about the machine.
            ScrollView {
                AppSettingsSection(helperState: helperState)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
                .tabItem { Text("Settings") }
                .tag("appsettings")
        }
        .padding(12)
        // Only reaches the margin around the tabs: the tab view paints its own
        // pane, and there is no way to tell it not to. Darkness is a sidebar
        // layout's setting first and a classic one's second.
        .background(AppearanceControl.isPitchBlack ? Color.black : Color.clear)
        // Wide enough for eleven tab labels without truncation. A macOS TabView
        // clips its labels rather than scrolling them, and "Grap…" next to
        // "Batt…" is worse than a window that takes more of the screen.
        .frame(minWidth: 880, minHeight: 420, idealHeight: 520)
    }
}

/// Extends the content under the title bar, or leaves the system's inset in
/// place for the classic layout, which still has a title bar to sit below.
private struct IgnoreTopSafeArea: ViewModifier {
    let on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.ignoresSafeArea(.container, edges: .top) } else { content }
    }
}

/// One feature's tab. The Enable row is identical everywhere on purpose:
/// the promise it makes — off means the machine is left alone — is the same
/// for all of them, so it should not look different in each.
private struct FeatureTab: View {
    @ObservedObject var feature: Feature

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if feature.isSupported {
                Toggle(isOn: Binding(
                    get: { feature.isEnabled },
                    set: { feature.setEnabled($0) }
                )) {
                    Text("Enable \(feature.title)").font(.headline)
                }
                Text(feature.summary)
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                // Scrolls rather than clips: the tabs differ a lot in height,
                // and Pointer already outgrows a window sized for Battery. A
                // clipped tab hides controls with nothing saying they exist.
                ScrollView {
                    feature.makeView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(!feature.isEnabled)
                        .opacity(feature.isEnabled ? 1 : 0.4)
                        .padding(.bottom, 8)
                }
            } else {
                Text(feature.title).font(.headline)
                Text(feature.unsupportedReason ?? "Not available on this Mac.")
                    .font(.subheadline).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(4)
    }
}

/// What the status item spells out. Not a feature: it changes nothing about
/// the machine, only what you can see without opening anything.
struct MenuBarTab: View {
    @ObservedObject var telemetry: Telemetry
    /// Bumped on every edit so the preview re-reads the preferences, which are
    /// plain statics rather than published state.
    @State private var revision = 0
    @State private var items: [MenuBarComposer.Item] = Preferences.menuBarItems

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview
            Divider()

            Text("Four percentages in a row say nothing about which is which — but a temperature needs no label, and every one costs width. So it is per field, below.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Shown, in this order").font(.headline)
            // Listed in the order they appear in the menu bar, with whatever
            // is switched off underneath. The list used to be in a fixed enum
            // order, so moving a field to the end left its row sitting where
            // it had always been — the number changed and nothing else did,
            // which reads as the arrows not working.
            ForEach(MenuBarComposer.Item.listOrder(shown: items), id: \.rawValue) { item in
                itemRow(item)
            }
            Spacer(minLength: 8)
        }
        .padding(4)
    }

    /// Shows the composed result rather than describing it, so the effect of a
    /// choice is visible without hunting for the menu bar. Drawn against this
    /// window's appearance, which is what it will be seen against here.
    private var preview: some View {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let content = MenuBarComposer.compose(telemetry: telemetry, darkMenuBar: dark)
        return HStack(spacing: 6) {
            Text("Now showing:").font(.caption).foregroundColor(.secondary)
            if let image = content.image { Image(nsImage: image) }
            if !content.title.isEmpty {
                Text(content.title).font(.system(.body, design: .monospaced))
            }
        }
        .id(revision)
    }

    @ViewBuilder private func itemRow(_ item: MenuBarComposer.Item) -> some View {
        let index = items.firstIndex(of: item)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(item.title, isOn: Binding(
                    get: { index != nil },
                    set: { on in
                        if on { items.append(item) } else { items.removeAll { $0 == item } }
                        commit()
                    }
                ))
                Spacer()
                if let index = index {
                    if !item.caption.isEmpty {
                        Toggle("Label", isOn: Binding(
                            get: { Preferences.menuBarItemIsCaptioned(item) },
                            set: { on in
                                var set = Preferences.captionedMenuBarItems
                                if on { set.insert(item.rawValue) } else { set.remove(item.rawValue) }
                                Preferences.captionedMenuBarItems = set
                                revision += 1
                            }
                        ))
                        .font(.caption)
                    }
                    Text("\(index + 1)").font(.caption).foregroundColor(.secondary)
                    Button("↑") { move(item, by: -1) }.buttonStyle(BorderlessButtonStyle())
                    Button("↓") { move(item, by: 1) }.buttonStyle(BorderlessButtonStyle())
                }
            }
            if index != nil { options(for: item).padding(.leading, 18) }
        }
    }

    @ViewBuilder private func options(for item: MenuBarComposer.Item) -> some View {
        switch item {
        case .temperature:
            MenuChoice(label: "Sensor",
                       selection: bind({ Preferences.temperatureSensorKey },
                                       { Preferences.temperatureSensorKey = $0 }),
                       options: [("Whatever looks like the CPU", "")]
                           + telemetry.temperatures.map {
                               ("\($0.label) — \(Int($0.celsius)) °C", $0.key)
                           })
        case .fan:
            MenuChoice(label: "Shown as",
                       selection: bind({ Preferences.fanStyle.rawValue },
                                       { Preferences.fanStyle = .init(rawValue: $0) ?? .rpm }),
                       options: MenuBarComposer.FanStyle.allCases.map { ($0.label, $0.rawValue) })
        case .battery:
            MenuChoice(label: "Shown as",
                       selection: bind({ Preferences.batteryStyle.rawValue },
                                       { Preferences.batteryStyle = .init(rawValue: $0) ?? .off }),
                       options: MenuBarComposer.BatteryStyle.allCases.map { ($0.label, $0.rawValue) })
            if Preferences.batteryStyle == .icon || Preferences.batteryStyle == .iconAndPercent {
                MenuChoice(label: "Icon",
                           selection: bind({ Preferences.batteryIcon.rawValue },
                                           { Preferences.batteryIcon = .init(rawValue: $0) ?? .iOS }),
                           options: MenuBarComposer.BatteryIcon.allCases.map { ($0.label, $0.rawValue) })
            }
        case .cpuSpeed:
            MenuChoice(label: "Shown as",
                       selection: bind({ Preferences.cpuSpeedStyle.rawValue },
                                       { Preferences.cpuSpeedStyle = .init(rawValue: $0) ?? .off }),
                       options: MenuBarComposer.SpeedStyle.allCases.map { ($0.label, $0.rawValue) })
        case .cpuLoad:
            MenuChoice(label: "Shown as",
                       selection: bind({ Preferences.cpuLoadStyle.rawValue },
                                       { Preferences.cpuLoadStyle = .init(rawValue: $0) ?? .off }),
                       options: MenuBarComposer.LoadStyle.allCases.map { ($0.label, $0.rawValue) })
        case .memory:
            MenuChoice(label: "Shown as",
                       selection: bind({ Preferences.memoryStyle.rawValue },
                                       { Preferences.memoryStyle = .init(rawValue: $0) ?? .off }),
                       options: MenuBarComposer.MemoryStyle.allCases.map { ($0.label, $0.rawValue) })
        case .power:
            MenuChoice(label: "Shown as",
                       selection: bind({ Preferences.powerStyle.rawValue },
                                       { Preferences.powerStyle = .init(rawValue: $0) ?? .battery }),
                       options: MenuBarComposer.PowerStyle.allCases.map { ($0.label, $0.rawValue) })
            Text("Battery flow is signed: plus while it fills, minus while it carries the machine — and 0.0 W for a full battery on a charger, which is the true answer rather than nothing at all.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .network:
            MenuChoice(label: "Shown as",
                       selection: bind({ Preferences.networkStyle.rawValue },
                                       { Preferences.networkStyle = .init(rawValue: $0) ?? .both }),
                       options: MenuBarComposer.NetworkStyle.allCases.map { ($0.label, $0.rawValue) })
            Text("Everything that is up, added together, minus loopback and VPN tunnels — a tunnel carries the same bytes as the Wi-Fi underneath it, and counting both would double the reading the moment a VPN connects.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .throttle:
            Text("Only appears while the firmware is actually holding the CPU back.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Plumbing

    private func move(_ item: MenuBarComposer.Item, by offset: Int) {
        guard let index = items.firstIndex(of: item) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
        commit()
    }

    private func commit() {
        Preferences.menuBarItems = items
        revision += 1
    }

    private func bind(_ get: @escaping () -> String,
                      _ set: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: get, set: { set($0); revision += 1 })
    }
}
