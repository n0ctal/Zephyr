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

    func show(registry: FeatureRegistry, telemetry: Telemetry) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsRootView(registry: registry, telemetry: telemetry)
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
    @State private var selection: String

    init(registry: FeatureRegistry, telemetry: Telemetry) {
        self.registry = registry
        self.telemetry = telemetry
        _selection = State(initialValue: SettingsWindowController.initialTab
                           ?? registry.features.first?.id ?? "menubar")
    }

    var body: some View {
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
    /// Bumped on every edit so the preview below re-reads the preferences,
    /// which are plain statics rather than published state.
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview

            Divider()
            Group {
                Toggle("Temperature", isOn: bind(.showTemperature))
                if Preferences.showTemperatureInMenuBar {
                    Picker("Sensor", selection: bindSensor()) {
                        Text("Whatever looks like the CPU").tag("")
                        ForEach(telemetry.temperatures) { reading in
                            Text("\(reading.label) — \(Int(reading.celsius)) °C").tag(reading.key)
                        }
                    }
                    .padding(.leading, 18)
                }
                Toggle("Fan speed", isOn: bind(.showFan))
            }

            Divider()
            Picker("Battery", selection: bindBattery()) {
                ForEach(MenuBarComposer.BatteryStyle.allCases, id: \.rawValue) {
                    Text($0.label).tag($0.rawValue)
                }
            }
            if Preferences.batteryStyle == .icon || Preferences.batteryStyle == .iconAndPercent {
                Picker("Icon", selection: bindBatteryIcon()) {
                    ForEach(MenuBarComposer.BatteryIcon.allCases, id: \.rawValue) {
                        Text($0.label).tag($0.rawValue)
                    }
                }
                .padding(.leading, 18)
                Text("The bar and the ring are drawn rather than taken from the symbol set, so they fill continuously instead of stepping between five stock images.")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.leading, 18)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Power in watts, signed", isOn: bind(.showPower))
            Text("Plus while the battery is filling, minus while it is carrying the machine. The sign is the whole message.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Picker("CPU speed", selection: bindSpeed()) {
                ForEach(MenuBarComposer.SpeedStyle.allCases, id: \.rawValue) {
                    Text($0.label).tag($0.rawValue)
                }
            }
            Text("macOS on Intel does not publish the live clock, so the frequency shown is the nominal speed times the ceiling the firmware currently allows — what is permitted, not what is running.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("CPU load", selection: bindLoad()) {
                ForEach(MenuBarComposer.LoadStyle.allCases, id: \.rawValue) {
                    Text($0.label).tag($0.rawValue)
                }
            }
            Picker("Memory", selection: bindMemory()) {
                ForEach(MenuBarComposer.MemoryStyle.allCases, id: \.rawValue) {
                    Text($0.label).tag($0.rawValue)
                }
            }

            Divider()
            Toggle("A mark while the CPU is capped", isOn: bind(.showThrottle))
            Text("Only appears while the firmware is actually holding the CPU back, and is hidden when the speed is already shown — the same number twice reads as a bug.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(4)
    }

    /// Shows the actual composed result rather than describing it, so the
    /// effect of a choice is visible without hunting for the menu bar.
    private var preview: some View {
        let content = MenuBarComposer.compose(telemetry: telemetry)
        return HStack(spacing: 6) {
            Text("Now showing:").font(.caption).foregroundColor(.secondary)
            if let image = content.image {
                Image(nsImage: image)
            }
            Text(content.title).font(.system(.body, design: .monospaced))
        }
        .id(revision)
    }

    // MARK: Binding plumbing

    private enum Flag { case showTemperature, showFan, showPower, showThrottle }

    private func bind(_ flag: Flag) -> Binding<Bool> {
        Binding(
            get: {
                switch flag {
                case .showTemperature: return Preferences.showTemperatureInMenuBar
                case .showFan: return Preferences.showFanInMenuBar
                case .showPower: return Preferences.showPowerInMenuBar
                case .showThrottle: return Preferences.showThrottleInMenuBar
                }
            },
            set: { value in
                switch flag {
                case .showTemperature: Preferences.showTemperatureInMenuBar = value
                case .showFan: Preferences.showFanInMenuBar = value
                case .showPower: Preferences.showPowerInMenuBar = value
                case .showThrottle: Preferences.showThrottleInMenuBar = value
                }
                revision += 1
            }
        )
    }

    private func bindSensor() -> Binding<String> {
        Binding(get: { Preferences.temperatureSensorKey },
                set: { Preferences.temperatureSensorKey = $0; revision += 1 })
    }
    private func bindBattery() -> Binding<String> {
        Binding(get: { Preferences.batteryStyle.rawValue },
                set: { Preferences.batteryStyle = .init(rawValue: $0) ?? .off; revision += 1 })
    }
    private func bindBatteryIcon() -> Binding<String> {
        Binding(get: { Preferences.batteryIcon.rawValue },
                set: { Preferences.batteryIcon = .init(rawValue: $0) ?? .system; revision += 1 })
    }
    private func bindSpeed() -> Binding<String> {
        Binding(get: { Preferences.cpuSpeedStyle.rawValue },
                set: { Preferences.cpuSpeedStyle = .init(rawValue: $0) ?? .off; revision += 1 })
    }
    private func bindLoad() -> Binding<String> {
        Binding(get: { Preferences.cpuLoadStyle.rawValue },
                set: { Preferences.cpuLoadStyle = .init(rawValue: $0) ?? .off; revision += 1 })
    }
    private func bindMemory() -> Binding<String> {
        Binding(get: { Preferences.memoryStyle.rawValue },
                set: { Preferences.memoryStyle = .init(rawValue: $0) ?? .off; revision += 1 })
    }
}
