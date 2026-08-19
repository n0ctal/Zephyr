import AppKit

/// Carries a "set fan N to RPM" request through a menu item.
private final class FanCommand {
    let fan: Int
    let rpm: Int
    init(fan: Int, rpm: Int) { self.fan = fan; self.rpm = rpm }
}

/// The menu-bar app: a status item whose title shows the hottest temperature,
/// with a menu for sensors, fan control, and GPU switching. All reading is
/// unprivileged; control actions go through the privileged helper.
final class AppController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let smc: SMC?
    private let sensors: SensorReader?
    private let fans: FanController?
    private let gpu = GPUController()
    private let turbo = TurboBoostController()
    private let helper = HelperClient.shared

    private var refreshTimer: Timer?
    /// Cached helper availability so we don't probe XPC on every menu open.
    private var helperVersion: String?
    private var helperRefreshInFlight = false
    /// Per-fan control modes ("auto"/"manual"/"curve") fetched from the helper
    /// (the authoritative source), so the menu is correct even after a restart.
    private var fanModes: [String] = []

    private func mode(forFan index: Int) -> String {
        index < fanModes.count ? fanModes[index] : "auto"
    }

    override init() {
        let smc = try? SMC()
        self.smc = smc
        self.sensors = smc.map { SensorReader(smc: $0) }
        self.fans = smc.map { FanController(smc: $0) }
        super.init()
        configure()
    }

    private func configure() {
        if let button = statusItem.button {
            button.title = "—"
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            // Thermometer glyph next to the temperature (template = adapts to
            // the menu-bar appearance). Available since macOS 11.
            let glyph = NSImage(systemSymbolName: "gauge", accessibilityDescription: "Zephyr")
            glyph?.isTemplate = true
            button.image = glyph
            button.imagePosition = .imageLeading
        }
        menu.delegate = self
        statusItem.menu = menu

        helperVersion = helper.version()
        updateStatusTitle()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }

        // The kext sets MSR bit 38 once at load and firmware restores the MSR
        // across sleep, so on wake Turbo is back while kextstat still says it is
        // disabled. Ask the daemon to re-apply.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.helper.reapplyTurboAfterWake()
        }
    }

    // MARK: Status-bar title

    private func updateStatusTitle() {
        guard let cpu = sensors?.cpuTemperature() else {
            statusItem.button?.title = "n/a"
            return
        }
        statusItem.button?.title = String(format: "%.0f°", cpu.celsius)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Draw from the last known state first: these two XPC round-trips block for
        // up to 5s and 2s, and doing them here froze the menu on every open.
        rebuildMenu()
        refreshHelperState()
    }

    private func refreshHelperState() {
        guard !helperRefreshInFlight else { return }
        helperRefreshInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let version = self.helper.version()
            let modes = version != nil ? self.helper.fanModes() : []
            DispatchQueue.main.async {
                self.helperRefreshInFlight = false
                let changed = version != self.helperVersion || modes != self.fanModes
                self.helperVersion = version
                self.fanModes = modes
                if changed { self.rebuildMenu() }
            }
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        buildHeader()
        menu.addItem(.separator())
        buildTemperatureSection()
        menu.addItem(.separator())
        buildFanSection()
        menu.addItem(.separator())
        buildGPUSection()
        menu.addItem(.separator())
        buildTurboBoostSection()
        menu.addItem(.separator())
        buildFooter()
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Sections

    private func buildHeader() {
        let item = NSMenuItem(title: "Zephyr", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: "Zephyr", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        menu.addItem(item)
    }

    private func buildTemperatureSection() {
        let temps = sensors?.readTemperatures() ?? []
        guard !temps.isEmpty else {
            menu.addItem(disabledItem("No sensors"))
            return
        }
        menu.addItem(disabledItem("Temperatures"))

        // Inline: CPU, GPU, and the hottest (if not already shown).
        var shownKeys = Set<String>()
        for key in ["TC0P", "TG0P"] {
            if let t = temps.first(where: { $0.key == key }) {
                menu.addItem(disabledItem(String(format: "   %@: %.0f °C", t.label, t.celsius)))
                shownKeys.insert(key)
            }
        }
        if let hottest = temps.max(by: { $0.celsius < $1.celsius }), !shownKeys.contains(hottest.key) {
            menu.addItem(disabledItem(String(format: "   Hottest (%@): %.0f °C", hottest.label, hottest.celsius)))
        }

        // Full list in a submenu.
        let allItem = NSMenuItem(title: "All sensors…", action: nil, keyEquivalent: "")
        let allMenu = NSMenu()
        for t in temps {
            allMenu.addItem(disabledItem(String(format: "%@  (%@)  %.1f °C", t.label, t.key, t.celsius)))
        }
        allItem.submenu = allMenu
        menu.addItem(allItem)
    }

    private func buildFanSection() {
        guard let fans, fans.fanCount > 0 else {
            menu.addItem(disabledItem("No controllable fans"))
            return
        }
        menu.addItem(disabledItem("Fans"))

        let controllable = (helperVersion != nil)
        for fan in fans.readFans() {
            let m = mode(forFan: fan.index)
            let state = (m == "curve") ? "smart" : m
            let title = String(format: "   Fan %d: %d rpm (%@)", fan.index + 1, fan.actualRPM, state)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = fanSubmenu(for: fan, enabled: controllable)
            menu.addItem(item)
        }

        if !controllable {
            menu.addItem(disabledItem("   (install helper to control fans)"))
        }
    }

    private func fanSubmenu(for fan: FanReading, enabled: Bool) -> NSMenu {
        let submenu = NSMenu()
        let m = mode(forFan: fan.index)
        let onCurve = (m == "curve")

        let auto = NSMenuItem(title: "Automatic (firmware)", action: #selector(fanAutoAction(_:)), keyEquivalent: "")
        auto.target = self
        auto.tag = fan.index
        auto.state = (m == "auto") ? .on : .off
        auto.isEnabled = enabled
        submenu.addItem(auto)

        let curve = NSMenuItem(title: "Smart cooling (CPU curve)", action: #selector(fanCurveAction(_:)), keyEquivalent: "")
        curve.target = self
        curve.tag = fan.index
        curve.state = onCurve ? .on : .off
        curve.isEnabled = enabled
        submenu.addItem(curve)

        submenu.addItem(.separator())

        // Fixed presets across the fan's own min/max range.
        let presets: [(String, Double)] = [
            ("Quiet (min)", 0.0), ("25%", 0.25), ("50%", 0.5),
            ("75%", 0.75), ("Max", 1.0)
        ]
        for (label, fraction) in presets {
            let rpm = fan.minRPM + Int(Double(fan.maxRPM - fan.minRPM) * fraction)
            let item = NSMenuItem(title: "\(label) — \(rpm) rpm",
                                  action: #selector(fanPresetAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = FanCommand(fan: fan.index, rpm: rpm)
            item.isEnabled = enabled
            // Mark the active fixed target (only in manual mode).
            if m == "manual" && abs(fan.targetRPM - rpm) <= 50 { item.state = .on }
            submenu.addItem(item)
        }
        return submenu
    }

    private func buildGPUSection() {
        guard gpu.isDualGPU else {
            if let name = gpu.integratedName {
                menu.addItem(disabledItem("Graphics: \(name)"))
            }
            return
        }
        let info = gpu.info()
        let activeNote: String
        if let active = info.activeName {
            activeNote = "  (active: \(info.activeIsLowPower == true ? "integrated" : "discrete"))"
            _ = active
        } else {
            activeNote = ""
        }
        menu.addItem(disabledItem("Graphics\(activeNote)"))

        let controllable = (helperVersion != nil)
        for mode in GPUMode.allCases {
            let item = NSMenuItem(title: "   \(mode.label)", action: #selector(gpuModeAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = (info.mode == mode) ? .on : .off
            item.isEnabled = controllable
            menu.addItem(item)
        }
        if !controllable {
            menu.addItem(disabledItem("   (install helper to switch GPU)"))
        }
    }

    private func buildTurboBoostSection() {
        guard turbo.isAvailable else { return }
        menu.addItem(disabledItem("Turbo Boost"))

        let controllable = (helperVersion != nil)
        let disabled = turbo.isTurboDisabled()

        let enabledItem = NSMenuItem(title: "   Enabled",
                                     action: #selector(turboAction(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.tag = 1
        enabledItem.state = disabled ? .off : .on
        enabledItem.isEnabled = controllable
        menu.addItem(enabledItem)

        let disabledIt = NSMenuItem(title: "   Disabled (cooler / quieter)",
                                    action: #selector(turboAction(_:)), keyEquivalent: "")
        disabledIt.target = self
        disabledIt.tag = 0
        disabledIt.state = disabled ? .on : .off
        disabledIt.isEnabled = controllable
        menu.addItem(disabledIt)

        if !controllable {
            menu.addItem(disabledItem("   (install helper to control Turbo Boost)"))
        }
    }

    private func buildFooter() {
        if let version = helperVersion {
            menu.addItem(disabledItem("Helper: running (v\(version))"))
        } else {
            let install = NSMenuItem(title: "Install helper…", action: #selector(showInstallInstructions), keyEquivalent: "")
            install.target = self
            menu.addItem(install)
        }

        let login = NSMenuItem(title: "Launch at login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit Zephyr", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
    }

    @objc private func fanAutoAction(_ sender: NSMenuItem) {
        helper.setFanAuto(fan: sender.tag)
    }

    @objc private func fanCurveAction(_ sender: NSMenuItem) {
        helper.setFanCurve(fan: sender.tag)
    }

    @objc private func fanPresetAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? FanCommand else { return }
        helper.setFanManual(fan: command.fan, rpm: command.rpm)
    }

    @objc private func gpuModeAction(_ sender: NSMenuItem) {
        guard let mode = GPUMode(rawValue: sender.tag) else { return }
        helper.setGPUMode(mode)
    }

    @objc private func turboAction(_ sender: NSMenuItem) {
        helper.setTurboBoostEnabled(sender.tag == 1)
    }

    @objc private func showInstallInstructions() {
        let alert = NSAlert()
        alert.messageText = "Install the privileged helper"
        alert.informativeText = """
        Fan and GPU control need a one-time root helper (like Macs Fan Control). \
        Run this in Terminal, then reopen the menu:

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
        // The installer is bundled inside the app (Contents/Resources/scripts),
        // so the command works wherever the app lives (e.g. /Applications).
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("scripts/install-helper.sh"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        // Dev fallback: scripts sit next to the bundle in the source tree.
        return Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("scripts/install-helper.sh").path
    }

    @objc private func quit() {
        // Hand fans back to firmware control so they aren't left forced with no
        // UI. The version() round-trip flushes the async setAllFansAuto first.
        helper.setAllFansAuto()
        _ = helper.version()
        NSApp.terminate(nil)
    }
}
