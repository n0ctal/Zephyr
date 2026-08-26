import AppKit
import Foundation
import SwiftUI

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
    private var previewWindow: NSWindow?
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
        AppearanceControl.apply()
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

    /// Renders the prototype straight to a PNG.
    ///
    /// Screenshotting it meant guessing where the window landed and cropping
    /// by hand, which kept catching whatever else was on the screen. An
    /// offscreen render is exact and involves nobody's desktop.
    func dumpDesignPreview(to path: String) {
        // Load is a rate and needs two samples; rendering before the second one
        // lands shows dashes where the numbers will be, which is a picture of
        // the render's timing rather than of the design.
        // Wait for the rate to exist rather than for a guessed interval.
        let deadline = Date().addingTimeInterval(8)
        while telemetry.load == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        // One file per style, each showing three sections whose content differs
        // as much as the app allows — a language that holds on Thermals may
        // fall apart on Profiles, and that is exactly what needs seeing.
        let sections: [PreviewSection] = [.thermals, .input, .profiles]
        let base = URL(fileURLWithPath: path).deletingPathExtension().path
        for style in PreviewStyle.all {
            let sheetWidth: CGFloat = 900
            let paneHeight: CGFloat = 640
            let sheet = NSImage(size: NSSize(width: sheetWidth,
                                             height: paneHeight * CGFloat(sections.count)))
            sheet.lockFocus()
            for (index, section) in sections.enumerated() {
                let view = TerminalDesignView(registry: registry, telemetry: telemetry,
                                              style: style, section: section)
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(x: 0, y: 0, width: sheetWidth, height: paneHeight)
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    rep.draw(in: NSRect(x: 0,
                                        y: sheet.size.height - CGFloat(index + 1) * paneHeight,
                                        width: sheetWidth, height: paneHeight))
                }
            }
            sheet.unlockFocus()
            guard let tiff = sheet.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let slug = style.name.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "—", with: "")
            let file = "\(base)-\(slug).png"
            try? png.write(to: URL(fileURLWithPath: file))
            FileHandle.standardError.write(Data("wrote \(file)\n".utf8))
        }
    }

    /// The 2.0 prototype, behind `--preview-design`. Deliberately unreachable
    /// from the menu: it is something to look at, not something shipped.
    func openDesignPreview() {
        let hosting = NSHostingController(
            rootView: TerminalDesignView(registry: registry, telemetry: telemetry))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Zephyr — design preview"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 640))
        // A known origin, so a screenshot of it can be cropped reliably
        // instead of guessing where the window landed.
        window.setFrameOrigin(NSPoint(x: 60, y: 120))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = window
    }

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
