import AppKit
import SwiftUI

/// The Settings window: one tab per feature, each gated by its own checkbox.
///
/// The window is the whole interface. The menu-bar menu deliberately stays at
/// four items, so anything that needs a control needs a tab here.
final class SettingsWindowController {
    private var window: NSWindow?

    /// Which tab to open on. Only set by the `--open-settings=<id>` dev flag;
    /// normal launches open on whatever the window remembers.
    static var initialTab: String?

    func show(registry: FeatureRegistry, telemetry: Telemetry, helperState: HelperState) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsRootView(registry: registry, telemetry: telemetry, helperState: helperState)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Zephyr"
        // Resizable because the tabs differ a lot in height: pinning one size
        // either crops the tall ones or leaves the short ones half empty.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 840, height: 700))
        window.center()
        // Remembers whatever size it is dragged to, so a preference about the
        // window is stated once rather than every launch.
        window.setFrameAutosaveName("ZephyrSettings")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
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
        _selection = State(initialValue: SettingsWindowController.initialTab
                           ?? registry.features.first?.id ?? "menubar")
    }

    var body: some View {
        VStack(spacing: 0) {
            if !helperState.isWorking { helperBanner }
            tabs
        }
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
        .padding(10)
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
        }
        .padding(12)
        // Wide enough for ten tab labels without truncation. A macOS TabView
        // clips its labels rather than scrolling them, and "Grap…" next to
        // "Batt…" is worse than a window that takes more of the screen.
        .frame(minWidth: 820, minHeight: 420, idealHeight: 520)
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
private struct MenuBarTab: View {
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
            ForEach(Array(MenuBarComposer.Item.allCases.enumerated()), id: \.element.rawValue) { _, item in
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
            Picker("Sensor", selection: bind({ Preferences.temperatureSensorKey },
                                             { Preferences.temperatureSensorKey = $0 })) {
                Text("Whatever looks like the CPU").tag("")
                ForEach(telemetry.temperatures) { reading in
                    Text("\(reading.label) — \(Int(reading.celsius)) °C").tag(reading.key)
                }
            }
        case .fan:
            Picker("Shown as", selection: bind({ Preferences.fanStyle.rawValue },
                                               { Preferences.fanStyle = .init(rawValue: $0) ?? .rpm })) {
                ForEach(MenuBarComposer.FanStyle.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
        case .battery:
            Picker("Shown as", selection: bind({ Preferences.batteryStyle.rawValue },
                                               { Preferences.batteryStyle = .init(rawValue: $0) ?? .off })) {
                ForEach(MenuBarComposer.BatteryStyle.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            if Preferences.batteryStyle == .icon || Preferences.batteryStyle == .iconAndPercent {
                Picker("Icon", selection: bind({ Preferences.batteryIcon.rawValue },
                                               { Preferences.batteryIcon = .init(rawValue: $0) ?? .iOS })) {
                    ForEach(MenuBarComposer.BatteryIcon.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
            }
        case .cpuSpeed:
            Picker("Shown as", selection: bind({ Preferences.cpuSpeedStyle.rawValue },
                                               { Preferences.cpuSpeedStyle = .init(rawValue: $0) ?? .off })) {
                ForEach(MenuBarComposer.SpeedStyle.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
        case .cpuLoad:
            Picker("Shown as", selection: bind({ Preferences.cpuLoadStyle.rawValue },
                                               { Preferences.cpuLoadStyle = .init(rawValue: $0) ?? .off })) {
                ForEach(MenuBarComposer.LoadStyle.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
        case .memory:
            Picker("Shown as", selection: bind({ Preferences.memoryStyle.rawValue },
                                               { Preferences.memoryStyle = .init(rawValue: $0) ?? .off })) {
                ForEach(MenuBarComposer.MemoryStyle.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
        case .power:
            Text("Plus while the battery is filling, minus while it is carrying the machine. The sign is the whole message.")
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
