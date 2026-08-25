import SwiftUI

/// Scrolling, told apart by device.
///
/// macOS has exactly one scroll-direction setting for every pointing device at
/// once, which is fine until a trackpad and a wheel mouse are both attached:
/// the gesture that feels right on one is backwards on the other. This is the
/// only place the two can be given different answers.
final class PointerFeature: Feature {
    private let interceptor = ScrollInterceptor()
    private let acceleration = PointerAcceleration()
    /// Re-applies the curve so a mouse plugged in later does not keep the
    /// system's own acceleration while the tab claims it is off.
    private var deviceWatch: Timer?

    @Published var reverseMouse: Bool { didSet { Preferences.reverseMouseScroll = reverseMouse; reapply() } }
    @Published var reverseTrackpad: Bool { didSet { Preferences.reverseTrackpadScroll = reverseTrackpad; reapply() } }
    @Published var linear: Bool { didSet { Preferences.linearScrolling = linear; reapply() } }
    @Published var linesPerNotch: Int { didSet { Preferences.scrollLinesPerNotch = linesPerNotch; reapply() } }
    @Published var flattenAcceleration: Bool {
        didSet { Preferences.flattenPointerAcceleration = flattenAcceleration; reapplyAcceleration() }
    }
    @Published var accelerationMultiplier: Double {
        didSet { Preferences.pointerAccelerationMultiplier = accelerationMultiplier; reapplyAcceleration() }
    }
    /// Refreshed on every apply so the tab can say why nothing is happening.
    @Published private(set) var isIntercepting = false
    @Published private(set) var devices: [PointerAcceleration.Device] = []

    init() {
        reverseMouse = Preferences.reverseMouseScroll
        reverseTrackpad = Preferences.reverseTrackpadScroll
        linear = Preferences.linearScrolling
        linesPerNotch = Preferences.scrollLinesPerNotch
        flattenAcceleration = Preferences.flattenPointerAcceleration
        accelerationMultiplier = Preferences.pointerAccelerationMultiplier
        super.init(id: "pointer",
                   title: "Pointer",
                   summary: "Give the mouse and the trackpad different scroll directions, and take the acceleration out of a wheel.")
        // A previous run may have been killed mid-flight, leaving devices on a
        // curve we chose. Put them back before doing anything else, so the
        // machine never carries a setting from a session that ended badly.
        if acceleration.isAvailable, acceleration.hasUnrestored,
           !(isEnabled && flattenAcceleration) {
            acceleration.restore()
        }
    }

    override var isSupported: Bool { acceleration.isAvailable }
    override var unsupportedReason: String? {
        isSupported ? nil : "This build of macOS does not expose the pointer interfaces Zephyr needs."
    }

    override func activate() {
        reapply()
        reapplyAcceleration()
        startDeviceWatch()
    }

    override func deactivate() {
        interceptor.stop()
        isIntercepting = false
        deviceWatch?.invalidate()
        deviceWatch = nil
        // Hand the shipped curve back. Leaving a device on a value we chose
        // after the feature is off would be a pointer that behaves oddly with
        // nothing in the UI admitting responsibility.
        acceleration.restore()
    }

    private func startDeviceWatch() {
        guard deviceWatch == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshDevices()
            self?.reapplyAcceleration()
        }
        RunLoop.main.add(timer, forMode: .common)
        deviceWatch = timer
        refreshDevices()
    }

    func refreshDevices() { devices = acceleration.devices() }

    private func reapplyAcceleration() {
        guard isEnabled, acceleration.isAvailable else { return }
        if flattenAcceleration {
            acceleration.apply(multiplier: accelerationMultiplier)
        } else {
            acceleration.restore()
        }
        refreshDevices()
    }

    func requestPermission() {
        ScrollInterceptor.requestPermission()
        reapply()
    }

    var isPermitted: Bool { ScrollInterceptor.isPermitted }

    private func reapply() {
        guard isEnabled else { return }
        interceptor.options = ScrollInterceptor.Options(
            reverseMouse: reverseMouse,
            reverseTrackpad: reverseTrackpad,
            linear: linear,
            linesPerNotch: linesPerNotch
        )
        // Nothing asked for means nothing intercepted: an idle tap in the event
        // stream costs every scroll a round trip through this process for no
        // reason, so it is torn down rather than left running empty.
        if reverseMouse || reverseTrackpad || linear {
            isIntercepting = interceptor.start()
        } else {
            interceptor.stop()
            isIntercepting = false
        }
    }

    override func makeView() -> AnyView { AnyView(PointerView(feature: self)) }
}

private struct PointerView: View {
    @ObservedObject var feature: PointerFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !feature.isPermitted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Zephyr needs Accessibility permission to change scroll events — without it macOS lets it watch them but not alter them.")
                        .font(.subheadline).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility settings") { feature.requestPermission() }
                }
                Divider()
            }

            Toggle("Reverse scrolling on a mouse", isOn: Binding(
                get: { feature.reverseMouse }, set: { feature.reverseMouse = $0 }))
            Toggle("Reverse scrolling on the trackpad", isOn: Binding(
                get: { feature.reverseTrackpad }, set: { feature.reverseTrackpad = $0 }))
            Text("These are separate on purpose. macOS offers one switch for every device at once, which is the whole reason this tab exists.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Toggle("Fixed distance per wheel notch", isOn: Binding(
                get: { feature.linear }, set: { feature.linear = $0 }))
            if feature.linear {
                Stepper("\(feature.linesPerNotch) lines per notch", value: Binding(
                    get: { feature.linesPerNotch }, set: { feature.linesPerNotch = $0 }
                ), in: 1...10)
            }
            Text("Applies to notched wheels only. A trackpad is a continuous surface, and flattening it would make it feel broken.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Toggle("Take the acceleration out of the pointer", isOn: Binding(
                get: { feature.flattenAcceleration }, set: { feature.flattenAcceleration = $0 }))
            if feature.flattenAcceleration {
                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.accelerationMultiplier == 0
                         ? "The cursor tracks the hand one to one."
                         : String(format: "Acceleration at %.2f of the shipped curve.", feature.accelerationMultiplier))
                        .font(.subheadline)
                    Slider(value: Binding(
                        get: { feature.accelerationMultiplier },
                        set: { feature.accelerationMultiplier = $0 }
                    ), in: 0...2, step: 0.05)
                }
                ForEach(feature.devices, id: \.name) { device in
                    Text(String(format: "%@ — %@ at %.2f", device.name, device.key, device.multiplier))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Text("Needs no permission: each device names its own acceleration key and Zephyr writes to that one. The value is put back when this is switched off.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if feature.isEnabled && !feature.isIntercepting && feature.isPermitted {
                Text("Nothing is being changed right now — none of the options above are on.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
}
