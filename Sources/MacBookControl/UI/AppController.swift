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
    private var helperState: HelperState = .notInstalled

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
        helperState = HelperState.current(helper)
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
            let power = self?.registry.feature(id: "power") as? PowerFeature
            power?.refreshTurboState()
            power?.reapplyStoredLimits()
        }
    }

    // MARK: Status title

    private func updateStatusTitle() {
        // The menu bar has its own appearance, which is not always the app's —
        // and the whole line is drawn by us now, so its colour has to be
        // chosen rather than left to the system.
        let dark = statusItem.button.map {
            $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        } ?? true
        let content = MenuBarComposer.compose(telemetry: telemetry, darkMenuBar: dark)
        statusItem.button?.image = content.image
        statusItem.button?.imagePosition = content.image == nil ? .noImage
            : (content.title.isEmpty ? .imageOnly : .imageLeading)
        statusItem.button?.title = content.title
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        helperState = HelperState.current(helper)
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
        switch helperState {
        case .working:
            let row = NSMenuItem(title: helperState.summary, action: nil, keyEquivalent: "")
            row.isEnabled = false
            return row
        case .notAuthorized:
            // Named differently from "install" on purpose: the fix is the same
            // command, but "install" reads as "you have not done this yet" to
            // somebody who did it yesterday.
            return item("Re-authorise helper…", #selector(showInstallInstructions))
        case .notInstalled:
            return item("Install helper…", #selector(showInstallInstructions))
        }
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
        helperState = HelperState.current(helper)
        settingsWindow.show(registry: registry, telemetry: telemetry, helperState: helperState)
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
    }

    @objc private func showInstallInstructions() {
        let alert = NSAlert()
        alert.messageText = helperState.summary
        alert.informativeText = """
        \(helperState.explanation ?? "")

        \(HelperState.installCommand)
        """
        alert.addButton(withTitle: "Copy command")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(HelperState.installCommand, forType: .string)
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
