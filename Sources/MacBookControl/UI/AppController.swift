import AppKit
import Foundation

/// The menu-bar presence: a title that reports, and a menu that does not.
///
/// The menu is deliberately four items. Every control lives in Settings, so
/// there is exactly one place to look for one, instead of some things being
/// reachable from the menu and others only from the window.
final class AppController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let helper = HelperClient()
    private let telemetry = Telemetry()
    private let gpu = GPUController()
    private let turbo = TurboBoostController()
    private let settingsWindow = SettingsWindowController()
    private let registry: FeatureRegistry

    private var refreshTimer: Timer?
    private var helperVersion: String?

    override init() {
        let telemetry = self.telemetry
        let helper = self.helper
        let buildStart = Date()
        let profiles = ProfilesFeature()
        registry = FeatureRegistry(features: [
            CoolingFeature(helper: helper, telemetry: telemetry),
            PowerFeature(helper: helper, turbo: turbo, telemetry: telemetry),
            GraphicsFeature(helper: helper, gpu: gpu),
            BatteryFeature(helper: helper, telemetry: telemetry),
            DisplayFeature(),
            KeyboardFeature(),
            PointerFeature(),
            AwakeFeature(),
            profiles,
        ])
        // The engine drives the other features, so it cannot be built
        // alongside them — it needs the finished registry.
        profiles.attach(registry: registry, telemetry: telemetry)
        if ProcessInfo.processInfo.arguments.contains("--time-phases") {
            FileHandle.standardError.write(Data(String(
                format: "  %6.0f ms  building all features\n",
                Date().timeIntervalSince(buildStart) * 1000).utf8))
        }
        super.init()
        configure()
    }

    /// Temporary instrumentation, on stderr so it survives being killed.
    private func phase(_ label: String, _ start: Date) -> Date {
        if ProcessInfo.processInfo.arguments.contains("--time-phases") {
            FileHandle.standardError.write(Data(String(
                format: "  %6.0f ms  %@\n", Date().timeIntervalSince(start) * 1000, label).utf8))
        }
        return Date()
    }

    private func configure() {
        var t = Date()
        Preferences.migrateLegacyKeys()
        statusItem.button?.title = "…"
        menu.delegate = self
        statusItem.menu = menu

        t = phase("status item + menu", t)
        telemetry.start()
        t = phase("telemetry.start", t)
        helperVersion = helper.version()
        t = phase("helper.version", t)
        // Features come up only after telemetry has read once: `isSupported`
        // asks the hardware, and a feature that checks before the first poll
        // would see an empty fan list and disable itself.
        registry.applyStoredState()
        t = phase("applyStoredState", t)

        updateStatusTitle()
        t = phase("updateStatusTitle", t)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Telemetry.interval, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Firmware restores both registers across sleep while the app still
            // believes they are set, so the settings lapse silently overnight.
            self?.helper.reapplyTurboAfterWake()
            self?.helper.reapplyChargeLimitAfterWake()
            // The cached kext state can only be stale after a wake, so this is
            // the one place it is worth re-reading.
            (self?.registry.feature(id: "power") as? PowerFeature)?.refreshTurboState()
        }
    }

    // MARK: Status title

    private func updateStatusTitle() {
        var parts: [String] = []
        if Preferences.showTemperatureInMenuBar, let cpu = telemetry.cpuTemperature {
            parts.append(String(format: "%.0f°", cpu.celsius))
        }
        if Preferences.showFanInMenuBar, let fastest = telemetry.fans.map(\.actualRPM).max() {
            parts.append("\(fastest) rpm")
        }
        if Preferences.showBatteryInMenuBar, let battery = telemetry.battery {
            parts.append("\(battery.percent) %")
        }
        if Preferences.showThrottleInMenuBar,
           let thermal = telemetry.thermal, thermal.isThrottling,
           let limit = thermal.speedLimitPercent {
            parts.append("↓\(limit) %")
        }
        statusItem.button?.title = parts.isEmpty ? "Zephyr" : parts.joined(separator: "  ")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        helperVersion = helper.version()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(helperItem())

        let login = item("Launch at login", #selector(toggleLaunchAtLogin))
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(item("Quit Zephyr", #selector(quit), key: "q"))
    }

    /// Reports the helper, and offers to install it when it is missing. The
    /// row is the same row either way so its position never moves.
    private func helperItem() -> NSMenuItem {
        guard let version = helperVersion else {
            return item("Install helper…", #selector(showInstallInstructions))
        }
        let row = NSMenuItem(title: "Helper \(version) running", action: nil, keyEquivalent: "")
        row.isEnabled = false
        return row
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
        row.target = self
        return row
    }

    // MARK: Actions

    /// See the `--open-settings` flag in main.swift.
    func openSettingsForTesting() { openSettings() }

    @objc private func openSettings() {
        settingsWindow.show(registry: registry, telemetry: telemetry)
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
    }

    @objc private func showInstallInstructions() {
        let alert = NSAlert()
        alert.messageText = "Zephyr needs its helper"
        alert.informativeText = """
        Fans, GPU switching, Turbo Boost and the charge ceiling all write to \
        hardware, which needs root. Run this once in Terminal, then reopen the menu:

        sudo \(installScriptPath())
        """
        alert.addButton(withTitle: "Copy command")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("sudo \(installScriptPath())", forType: .string)
        }
    }

    private func installScriptPath() -> String {
        // Bundled inside the app, so the command works wherever it lives.
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("scripts/install-helper.sh"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        return Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("scripts/install-helper.sh").path
    }

    @objc private func quit() {
        // Every feature hands the hardware back before we go. Fans pinned by a
        // process that no longer exists is the one failure that can cook the
        // machine, so this is not merely tidy.
        registry.deactivateAll()
        _ = helper.version()   // flushes the async writes above
        NSApp.terminate(nil)
    }
}
