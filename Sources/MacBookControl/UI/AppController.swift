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
        // Before the registry, not with the other migrations in configure():
        // a feature reads its own enabled state as it is constructed, so a
        // migration that runs afterwards is a migration that runs too late.
        Preferences.migratePowerSplit()
        let telemetry = self.telemetry
        let helper = self.helper
        let buildStart = Date()
        let profiles = ProfilesFeature()
        registry = FeatureRegistry(features: [
            CoolingFeature(helper: helper, telemetry: telemetry),
            TurboBoostFeature(helper: helper, turbo: turbo),
            PowerLimitFeature(helper: helper, telemetry: telemetry),
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
        // And telemetry asks the registry what to keep reading while the
        // window is shut, rather than knowing which features exist.
        telemetry.featureNeeds = { [weak registry] in
            registry?.features.filter(\.isEnabled)
                .reduce(Telemetry.Needs()) { $0.union($1.telemetryNeeds) } ?? Telemetry.Needs()
        }
        Feature.needsDidChange = { [weak telemetry] in telemetry?.invalidateNeeds() }
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

    /// The menu bar redraws on its own schedule, separate from the window's.
    ///
    /// Rebuilt rather than reconfigured because a Timer's interval cannot be
    /// changed after it is scheduled.
    func startStatusTimer() {
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Preferences.menuBarPollSeconds,
                                         repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }
        // A fifth of the period, like every other repeating timer here. This
        // one is the most frequent and it never stops, so without it the
        // machine was still woken on the dot twice a second and the slack
        // given to the telemetry timer only coalesced onto this one — which is
        // to say it bought nothing at the settings everybody runs.
        timer.tolerance = Preferences.menuBarPollSeconds * Telemetry.timerToleranceFraction
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func configure() {
        SettingsWindowController.pollingDidChange = { [weak self] in
            self?.telemetry.retune()
            self?.startStatusTimer()
        }
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
        startStatusTimer()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Firmware restores both registers across sleep while the app still
            // believes they are set, so the settings lapse silently overnight.
            self?.helper.reapplyTurboAfterWake()
            self?.helper.reapplyChargeLimitAfterWake()
            // The cached kext state can only be stale after a wake, so this is
            // the one place it is worth re-reading.
            let turbo = self?.registry.feature(id: "turbo") as? TurboBoostFeature
            turbo?.refreshTurboState()
            let limits = self?.registry.feature(id: "powerlimit") as? PowerLimitFeature
            limits?.reapplyStoredLimits()
        }
    }

    /// Waits until the readings a picture needs actually exist.
    ///
    /// Load is a rate and needs two samples; rendering before the second one
    /// lands shows dashes where the numbers will be, which is a picture of the
    /// render's timing rather than of the design. And since telemetry only
    /// reads what something is displaying, this has to say that something is —
    /// otherwise the load reading never arrives at all and the wait becomes a
    /// silent eight-second pause.
    private func waitForReadings(upTo seconds: TimeInterval) {
        telemetry.isWindowOpen = true
        let deadline = Date().addingTimeInterval(seconds)
        while telemetry.load == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    // MARK: Status title

    /// The signature of the line currently on screen, so an identical one is
    /// not drawn over itself.
    private var lastLineDrawn: String?

    private func updateStatusTitle() {
        // The menu bar has its own appearance, which is not always the app's —
        // and the whole line is drawn by us now, so its colour has to be
        // chosen rather than left to the system.
        let dark = statusItem.button.map {
            $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        } ?? true
        let content = MenuBarComposer.compose(telemetry: telemetry, darkMenuBar: dark)
        // Handing the button a fresh image marks the status item for redraw
        // whether or not a single pixel differs, and this runs twice a second
        // for as long as the app is open. Most of those ticks change nothing:
        // a temperature that has not moved, a battery that ticks once every
        // few minutes. The signature says what the line was drawn from, so an
        // unchanged one is left entirely alone.
        guard content.signature != lastLineDrawn else { return }
        lastLineDrawn = content.signature
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

        // Two items. The helper's state and the login item both live in the
        // window's own Settings section now, and a control in two places is a
        // question about which one is authoritative the first time they
        // disagree. What is left is the way in and the way out.
        menu.addItem(item("Options…", #selector(openSettings), key: ","))
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
        waitForReadings(upTo: 8)
        // One file per style, each showing three sections whose content differs
        // as much as the app allows — a language that holds on Thermals may
        // fall apart on Profiles, and that is exactly what needs seeing.
        // The shipping window is deliberately not rendered here. SwiftUI
        // resolves its colours against the running application's appearance,
        // and an offscreen host does not carry one — the result comes out
        // white on white however the appearance is set, on the view or on the
        // app. It needs no rendering anyway: "classic" is the window that is
        // already installed, and looking at it directly is more truthful than
        // any copy of it.
        let sections: [SettingsSection] = [.thermals, .input, .settings]
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
                hosting.appearance = NSAppearance(named: style.monospaced || style.name == "Dark glass"
                                                  ? .darkAqua : .aqua)
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

    /// Renders the shipping window in each layout, offscreen.
    ///
    /// The alternative is opening it and taking a picture of the screen, which
    /// means guessing where the window landed, cropping by hand, and catching
    /// whatever else happened to be open. This involves nobody's desktop.
    func dumpWindowLayouts(to path: String, dark: Bool, pitch: Bool = false) {
        waitForReadings(upTo: 8)
        let base = URL(fileURLWithPath: path).deletingPathExtension().path
        let remembered = Preferences.windowLayout
        defer { Preferences.windowLayout = remembered }
        // The whole application's appearance, not just the host view's. A
        // TabView is an AppKit control underneath and resolves its colours
        // against NSApp — setting it on the host alone left the classic sheet
        // white on white while the two hand-coloured layouts came out fine.
        let rememberedAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = rememberedAppearance }
        let rememberedSetting = Preferences.appearance
        Preferences.appearance = pitch ? "darkness" : (dark ? "dark" : "light")
        defer { Preferences.appearance = rememberedSetting }

        for layout in WindowLayout.allCases {
            Preferences.windowLayout = layout
            // Two panes per layout: a section that is all hardware controls,
            // and the one that is about the app. A frame that holds one and
            // breaks the other is the usual way a layout goes wrong.
            let panes: [String] = layout.usesSidebar
                ? [SettingsSection.thermals.rawValue,
                   SettingsSection.menuBar.rawValue,
                   SettingsSection.settings.rawValue]
                : ["cooling", "menubar", "appsettings"]
            let width: CGFloat = 940
            let paneHeight: CGFloat = 620
            let sheet = NSImage(size: NSSize(width: width, height: paneHeight * CGFloat(panes.count)))
            sheet.lockFocus()
            for (index, pane) in panes.enumerated() {
                SettingsWindowController.initialTab = pane
                let view = SettingsRootView(registry: registry, telemetry: telemetry,
                                            helperState: helperState)
                let hosting = NSHostingView(rootView: view)
                // An offscreen host carries no appearance of its own, and
                // SwiftUI resolves every system colour against one — without
                // this the whole sheet comes out white on white.
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: paneHeight)
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    rep.draw(in: NSRect(x: 0,
                                        y: sheet.size.height - CGFloat(index + 1) * paneHeight,
                                        width: width, height: paneHeight))
                }
            }
            sheet.unlockFocus()
            SettingsWindowController.initialTab = nil
            guard let tiff = sheet.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let shade = pitch ? "darkness" : (dark ? "dark" : "light")
            let file = "\(base)-\(layout.rawValue)-\(shade).png"
            try? png.write(to: URL(fileURLWithPath: file))
            FileHandle.standardError.write(Data("wrote \(file)\n".utf8))
        }
    }

    /// Photographs the settings window as the window server draws it —
    /// titlebar, window buttons and all — without putting it on the screen.
    ///
    /// The offscreen render used everywhere else builds the view hierarchy by
    /// hand and therefore has no window chrome at all, which is exactly the
    /// part that needed checking. This opens the real window at a position
    /// nobody can see and asks its frame view to draw itself into a bitmap. It
    /// is entirely local: no screen recording, and nothing else on the desktop
    /// is in the picture.
    func dumpRealWindow(to path: String, layout: WindowLayout, strip: CGFloat = 170) {
        Preferences.windowLayout = layout
        waitForReadings(upTo: 6)
        // Shown as it looks when the helper is answering, which is the normal
        // case. The warning banner is worth checking too, but it is not what
        // this picture is for: it covers the strip being inspected.
        settingsWindow.show(registry: registry, telemetry: telemetry,
                            helperState: .working(version: "dev"), alwaysVisible: true)
        guard let window = settingsWindow.windowForTesting else { return }
        // Only a place. The window sizes itself from the view it holds, and
        // forcing a size here would photograph a window nobody will ever see.
        window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        // Draw once before waiting. A window parked off every screen is never
        // asked to display itself, and SwiftUI holds `onAppear` until it is —
        // so the readings attached to a section's appearance never started and
        // every capture came back saying "Reading…".
        window.displayIfNeeded()
        window.contentView?.display()
        // Then long enough for SwiftUI's own pass and for the readings taken
        // off the main thread to come back.
        RunLoop.current.run(until: Date().addingTimeInterval(3.5))
        // Only the top of the window. A SwiftUI hosting controller reports a
        // preferred size and the window obligingly grows to it, so the frame
        // view here is thousands of points tall — and the part worth looking
        // at is the strip with the buttons and the name in it.
        guard let frame = window.contentView?.superview else { return }
        let region = NSRect(x: 0, y: max(0, frame.bounds.height - strip),
                            width: frame.bounds.width, height: min(strip, frame.bounds.height))
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: region) else { return }
        frame.cacheDisplay(in: region, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("wrote \(path)\n".utf8))
    }

    /// Prints how tall each section wants to be at a given width.
    ///
    /// Worth having as a flag rather than a guess: with the sidebar layouts no
    /// longer scrolling, a section taller than the window is content nobody
    /// can reach. This is the measurement that says whether that has happened.
    func measureSections(width: CGFloat) {
        waitForReadings(upTo: 6)
        let remembered = Preferences.windowLayout
        let rememberedItems = Preferences.menuBarItems
        defer {
            Preferences.windowLayout = remembered
            Preferences.menuBarItems = rememberedItems
        }
        Preferences.windowLayout = .terminal
        // The worst case, not the current one: every menu-bar field switched
        // on shows every field's options as well, and that is the tallest the
        // section can ever be.
        Preferences.menuBarItems = MenuBarComposer.Item.allCases
        for section in SettingsSection.allCases {
            // The sidebar view itself, not the window's root: the root pins an
            // ideal height, and a view asked how tall it would like to be will
            // answer with whatever it has been told to be.
            let view = SidebarSettingsView(registry: registry, telemetry: telemetry,
                                           helperState: .working(version: "dev"),
                                           layout: .terminal,
                                           selection: .constant(section.rawValue))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: 100)
            hosting.layoutSubtreeIfNeeded()
            let height = hosting.fittingSize.height
            print(String(format: "%-14@ %6.0f pt", section.title as NSString, height))
        }
        SettingsWindowController.initialTab = nil
    }

    /// The 2.0 prototype, behind `--preview-design`. Deliberately unreachable
    /// from the menu: it is something to look at, not something shipped.
    func openDesignPreview() {
        // The prototype shows live readings like everything else, and
        // telemetry only reads what something is displaying.
        waitForReadings(upTo: 6)
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
