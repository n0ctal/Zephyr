import CoreGraphics
import SwiftUI

/// Brightness past the panel's floor, and the resolutions macOS hides.
final class DisplayFeature: Feature {
    private let control = DisplayControl()

    @Published private(set) var screens: [DisplayControl.Screen] = []
    @Published var dimming: [CGDirectDisplayID: Double] = [:]
    /// Cached per display. Enumerating modes asks CoreGraphics for every
    /// variant — 210 of them on this machine before de-duplication — and a
    /// SwiftUI Picker asks its data source on every render, so computing it in
    /// the body made simply opening the tab expensive.
    @Published private(set) var modeCache: [CGDirectDisplayID: [DisplayControl.Mode]] = [:]
    /// Which display the controls below are about. Nil means the first one,
    /// which is the built-in panel on every Mac that has one.
    ///
    /// Unlike the keyboard and the pointer there is no "all of them" here, and
    /// that is not an omission: brightness and resolution are facts about one
    /// piece of glass. A single slider driving every panel would be a control
    /// that means something different on each screen it reaches.
    @Published var scope: CGDirectDisplayID?
    private var refreshTimer: Timer?


    init() {
        super.init(id: "display",
                   title: "Display",
                   summary: "Dim below the panel's own minimum, and pick from the resolutions the Displays pane declines to list.")
    }

    override var isSupported: Bool { control.isAvailable }
    override var unsupportedReason: String? {
        isSupported ? nil : "This build of macOS does not expose the brightness interfaces Zephyr needs."
    }

    override func activate() {
        control.onConfigurationChange = { [weak self] in
            self?.refresh()
            self?.objectWillChange.send()
        }
        // Kept on the feature rather than on the view: this is what notices
        // the machine has been left with no display at all, and it has to
        // notice that with the window shut.
        control.startWatchingConfiguration()
        refresh()
    }

    /// Re-enumerates the screens while the tab is open. Five seconds is quick
    /// enough that plugging a monitor in and looking shows it already listed.
    func startWatchingScreens() {
        refresh()
        guard refreshTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stopWatchingScreens() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    override func deactivate() {
        stopWatchingScreens()
        // The extra dimming is ours and goes back. Brightness and resolution
        // stay: those are ordinary system settings the user also changes with
        // the keys and the Displays pane, and silently rewinding them on the
        // way out would be the app overreaching.
        control.clearAllDimming()
        dimming.removeAll()
    }

    /// The display the tab is currently about.
    var scopedScreen: DisplayControl.Screen? {
        screens.first { $0.id == scope } ?? screens.first
    }

    func refresh() {
        let screens = control.screens()
        self.screens = screens
        // A display that was unplugged cannot stay selected, or the tab shows
        // controls for a screen that is no longer in the room.
        if let scope = scope, !screens.contains(where: { $0.id == scope }) {
            self.scope = nil
        }
        for screen in screens where modeCache[screen.id] == nil {
            modeCache[screen.id] = control.modes(for: screen.id)
        }
    }

    func setBrightness(_ value: Double, on display: CGDirectDisplayID) {
        control.setBrightness(Float(value), on: display)
        refresh()
    }

    func canChangeBrightness(_ display: CGDirectDisplayID) -> Bool {
        control.canChangeBrightness(of: display)
    }

    func setDimming(_ value: Double, on display: CGDirectDisplayID) {
        dimming[display] = value
        control.setExtraDimming(value, on: display)
    }

    var canSwitchDisplaysOff: Bool { DisplayControl.canSwitchDisplaysOff }

    func canTurnOff(_ display: CGDirectDisplayID) -> Bool {
        control.canSafelyDisable(display)
    }

    @discardableResult
    func setDisplayEnabled(_ enabled: Bool, of display: CGDirectDisplayID) -> Bool {
        let applied = control.setEnabled(enabled, of: display)
        refresh()
        return applied
    }

    func rotation(of display: CGDirectDisplayID) -> DisplayControl.Rotation {
        control.rotation(of: display)
    }

    func setRotation(_ rotation: DisplayControl.Rotation, of display: CGDirectDisplayID) {
        control.setRotation(rotation, of: display)
        screens = control.screens()
        objectWillChange.send()
    }

    func mirrorSource(of display: CGDirectDisplayID) -> CGDirectDisplayID? {
        control.mirrorSource(of: display)
    }

    func setMirroring(of display: CGDirectDisplayID, to source: CGDirectDisplayID?) {
        control.setMirroring(of: display, to: source)
        refresh()
    }

    func modes(for display: CGDirectDisplayID) -> [DisplayControl.Mode] {
        modeCache[display] ?? []
    }

    func currentMode(for display: CGDirectDisplayID) -> DisplayControl.Mode? {
        control.currentMode(for: display)
    }

    var awaitingConfirmation: CGDirectDisplayID? { control.awaitingConfirmation }

    func confirmResolution() {
        control.confirm()
        objectWillChange.send()
    }

    func revertResolution() {
        if let display = control.awaitingConfirmation { control.revert(display) }
        screens = control.screens()
        objectWillChange.send()
    }

    func apply(_ mode: DisplayControl.Mode, to display: CGDirectDisplayID) {
        control.apply(mode, to: display)
        // The mode list itself does not change with the current mode, so the
        // cache stands; only the screen summary needs re-reading.
        screens = control.screens()
    }

    override func makeView() -> AnyView { AnyView(DisplayView(feature: self)) }
}

private struct DisplayView: View {
    @ObservedObject var feature: DisplayFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // One display at a time, chosen here — the same shape as Keyboard
            // and Pointer. Stacking every screen's controls down the tab made
            // it read as though the sliders applied to all of them.
            MenuChoice(label: "These apply to",
                       selection: Binding(get: { feature.scopedScreen?.id ?? 0 },
                                          set: { feature.scope = $0 }),
                       options: feature.screens.map {
                           ($0.name + ($0.isBuiltIn ? " · built in" : ""), $0.id)
                       })
                .disabled(feature.screens.count < 2)

            // Above everything, and not inside a screen's own row: the change
            // waiting to be confirmed may be to a screen that has just been
            // switched off, and a prompt nobody can reach is a change that
            // always reverts.
            if feature.awaitingConfirmation != nil {
                HStack {
                    Text("Keep this change? It goes back on its own in a few seconds.")
                        .font(.caption).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Keep") { feature.confirmResolution() }
                    Button("Undo") { feature.revertResolution() }
                }
            }

            Divider()
            if let screen = feature.scopedScreen {
                ScreenControls(feature: feature, screen: screen)
            } else {
                Text("No displays are answering.")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            Divider()
            Text("While this tab is on, Zephyr also watches for the machine ending up with no active display at all — the state other display utilities leave behind when the built-in panel is switched off and the external one is then unplugged — and asks the system for its permanent arrangement back rather than leaving a restart as the only way out.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("External monitors that ignore this control need DDC/CI over the video cable — a separate path, and one that cannot be written honestly without a monitor to test it against.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Enumerating screens and their modes is not free, and nothing but
        // this tab looks at the result — so it is asked while the tab is open
        // and not otherwise. Not through `Polled`, because the reading
        // publishes straight onto the feature and that has to happen on the
        // main thread.
        .onAppear { feature.startWatchingScreens() }
        .onDisappear { feature.stopWatchingScreens() }
    }
}

private struct ScreenControls: View {
    @ObservedObject var feature: DisplayFeature
    let screen: DisplayControl.Screen

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(screen.name).font(.headline)
            Text("\(screen.width) × \(screen.height) on \(screen.pixelWidth) pixels across")
                .font(.caption).foregroundColor(.secondary)

            if let brightness = screen.brightness, feature.canChangeBrightness(screen.id) {
                Text("Brightness \(Int(brightness * 100)) %").font(.subheadline)
                Slider(value: Binding(
                    get: { Double(brightness) },
                    set: { feature.setBrightness($0, on: screen.id) }
                ), in: 0...1)
            } else {
                Text("This display does not accept a brightness command.")
                    .font(.subheadline).foregroundColor(.secondary)
            }

            let dim = feature.dimming[screen.id] ?? 1
            Text(dim >= 1 ? "No extra dimming" : "Dimmed to \(Int(dim * 100)) % beyond the panel's minimum")
                .font(.subheadline)
            Slider(value: Binding(
                get: { dim },
                set: { feature.setDimming($0, on: screen.id) }
            ), in: 0.1...1)

            if feature.canSwitchDisplaysOff {
                Toggle(isOn: Binding(
                    get: { screen.isOn },
                    set: { feature.setDisplayEnabled($0, of: screen.id) }
                )) {
                    Text("Screen on").font(.headline)
                }
                .disabled(screen.isOn && !feature.canTurnOff(screen.id))
                if !WindowArrangement.isPermitted {
                    Text("Windows will not be put back where they were: that needs the same Accessibility permission the Pointer section asks for. macOS moves every window onto whatever screen is left and returns none of them by itself.")
                        .font(.caption).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(feature.canTurnOff(screen.id) || !screen.isOn
                     ? "Switching a screen off is for this session only — a restart brings it back whatever else has happened. It also comes back by itself in a few seconds unless you confirm, and Zephyr puts the arrangement back if the machine is ever left with no screen at all."
                     : "This is the only screen the machine has. Switching it off would leave nowhere to switch it back on from, which is exactly the state other display utilities are known for.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SegmentedChoice(label: "Rotation",
                            selection: Binding(get: { feature.rotation(of: screen.id) },
                                               set: { feature.setRotation($0, of: screen.id) }),
                            options: DisplayControl.Rotation.allCases.map { ($0.label, $0) })

            // Only worth offering with something to mirror onto.
            if feature.screens.count > 1 {
                MenuChoice(label: "Mirroring",
                           selection: Binding(
                               get: { feature.mirrorSource(of: screen.id) ?? 0 },
                               set: { feature.setMirroring(of: screen.id,
                                                           to: $0 == 0 ? nil : $0) }),
                           options: [("Off — its own picture", CGDirectDisplayID(0))]
                               + feature.screens.filter { $0.id != screen.id }
                                   .map { ("Show what \($0.name) shows", $0.id) })
            }

            MenuChoice(label: "Resolution",
                       selection: Binding(
                           get: { feature.currentMode(for: screen.id)?.id ?? "" },
                           set: { id in
                               guard let mode = feature.modes(for: screen.id)
                                   .first(where: { $0.id == id }) else { return }
                               feature.apply(mode, to: screen.id)
                           }),
                       options: feature.modes(for: screen.id).map { ($0.label, $0.id) })
            Text("A resolution is put back by itself unless you confirm you can still see. A panel can be told to use a mode it cannot show, and the button that would undo it is on the screen that just went dark.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
