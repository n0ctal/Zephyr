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
        window.center()
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
            MenuBarTab(telemetry: telemetry)
                .tabItem { Text("Menu Bar") }
                .tag("menubar")
        }
        .padding(12)
        .frame(minWidth: 540, minHeight: 360)
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
                feature.makeView()
                    .disabled(!feature.isEnabled)
                    .opacity(feature.isEnabled ? 1 : 0.4)
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
    @State private var temperature = Preferences.showTemperatureInMenuBar
    @State private var fan = Preferences.showFanInMenuBar
    @State private var battery = Preferences.showBatteryInMenuBar
    @State private var throttle = Preferences.showThrottleInMenuBar

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Show in the menu bar").font(.headline)
            Toggle("CPU temperature", isOn: $temperature)
                .onChange(of: temperature) { Preferences.showTemperatureInMenuBar = $0 }
            Toggle("Fan speed", isOn: $fan)
                .onChange(of: fan) { Preferences.showFanInMenuBar = $0 }
            Toggle("Battery percentage", isOn: $battery)
                .onChange(of: battery) { Preferences.showBatteryInMenuBar = $0 }
            Toggle("A mark while the CPU is capped", isOn: $throttle)
                .onChange(of: throttle) { Preferences.showThrottleInMenuBar = $0 }
            Text("The cap mark only appears while the firmware is actually holding the CPU back, so an empty menu bar means nothing is wrong.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(4)
    }
}
