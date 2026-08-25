import CoreGraphics
import SwiftUI

/// Brightness past the panel's floor, and the resolutions macOS hides.
final class DisplayFeature: Feature {
    private let control = DisplayControl()

    @Published private(set) var screens: [DisplayControl.Screen] = []
    @Published var dimming: [CGDirectDisplayID: Double] = [:]

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
        refresh()
        guard refreshTimer == nil else { return }
        // Displays come and go. Five seconds is quick enough that plugging a
        // monitor in and opening this tab shows it already listed.
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    override func deactivate() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        // The extra dimming is ours and goes back. Brightness and resolution
        // stay: those are ordinary system settings the user also changes with
        // the keys and the Displays pane, and silently rewinding them on the
        // way out would be the app overreaching.
        control.clearAllDimming()
        dimming.removeAll()
    }

    func refresh() { screens = control.screens() }

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

    func modes(for display: CGDirectDisplayID) -> [DisplayControl.Mode] {
        control.modes(for: display)
    }

    func currentMode(for display: CGDirectDisplayID) -> DisplayControl.Mode? {
        control.currentMode(for: display)
    }

    func apply(_ mode: DisplayControl.Mode, to display: CGDirectDisplayID) {
        control.apply(mode, to: display)
        refresh()
    }

    override func makeView() -> AnyView { AnyView(DisplayView(feature: self)) }
}

private struct DisplayView: View {
    @ObservedObject var feature: DisplayFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(feature.screens) { screen in
                ScreenControls(feature: feature, screen: screen)
                Divider()
            }
            Text("External monitors that ignore this control need DDC/CI over the video cable — a separate path, and one that cannot be written honestly without a monitor to test it against.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { feature.refresh() }
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

            Picker("Resolution", selection: Binding(
                get: { feature.currentMode(for: screen.id)?.id ?? "" },
                set: { id in
                    guard let mode = feature.modes(for: screen.id).first(where: { $0.id == id }) else { return }
                    feature.apply(mode, to: screen.id)
                }
            )) {
                ForEach(feature.modes(for: screen.id)) { mode in
                    Text(mode.label).tag(mode.id)
                }
            }
            Text("A resolution set here lasts for this login session only. If one turns out to be unreadable, restarting is the way back.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
