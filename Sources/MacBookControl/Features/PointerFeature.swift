import SwiftUI

/// Scrolling, acceleration and extra buttons — per device.
///
/// macOS has exactly one scroll-direction setting for every pointing device at
/// once, which is fine until a trackpad and a wheel mouse are both attached:
/// the gesture that feels right on one is backwards on the other. And two mice
/// are two different opinions about what the side buttons should do.
final class PointerFeature: Feature {
    private let interceptor = ScrollInterceptor()
    private let acceleration = PointerAcceleration()
    private var deviceWatch: Timer?

    @Published var store: DeviceScopedStore<PointerProfile> {
        didSet {
            Preferences.pointerStore = store
            guard isEnabled else { return }
            reapply()
        }
    }
    @Published private(set) var devices: [PointerAcceleration.Device] = []
    /// nil means the defaults every device follows unless it has its own.
    @Published var scope: String?
    @Published private(set) var isIntercepting = false

    init() {
        store = Preferences.pointerStore
        super.init(id: "pointer",
                   title: "Pointer",
                   summary: "Give each mouse and the trackpad their own scroll direction, acceleration and button bindings.")
        // A previous run may have been killed with a curve applied, and the
        // device keeps it until something puts it back.
        if acceleration.isAvailable, acceleration.hasUnrestored, !isEnabled {
            acceleration.restore()
        }
    }

    override var isSupported: Bool { acceleration.isAvailable }
    override var unsupportedReason: String? {
        isSupported ? nil : "This build of macOS does not expose the pointer interfaces Zephyr needs."
    }

    override func activate() {
        refreshDevices()
        reapply()
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

    func requestPermission() {
        ScrollInterceptor.requestPermission()
        reapply()
    }

    var isPermitted: Bool { ScrollInterceptor.isPermitted }

    // MARK: Applying

    private func startDeviceWatch() {
        guard deviceWatch == nil else { return }
        // A mouse plugged in later arrives with the system's own settings and
        // has to be caught.
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshDevices()
            self?.reapply()
        }
        RunLoop.main.add(timer, forMode: .common)
        deviceWatch = timer
    }

    func refreshDevices() {
        devices = acceleration.devices()
        var pruned = store
        pruned.prune(keeping: Set(devices.map(\.identity)))
        if pruned != store { store = pruned }
        if let scope = scope, !devices.contains(where: { $0.identity == scope }) {
            self.scope = nil
        }
    }

    private func reapply() {
        guard isEnabled, acceleration.isAvailable else { return }

        acceleration.apply { [store] identity in
            let profile = store[identity]
            return profile.flattenAcceleration ? profile.accelerationMultiplier : nil
        }
        // Devices that stopped asking for a curve have to be put back, which
        // apply() cannot do because it only writes what it is given.
        let wantsCurve = devices.contains { store[$0.identity].flattenAcceleration }
        if !wantsCurve { acceleration.restore() }

        interceptor.options = composedOptions()
        if interceptor.options.wantsAnything {
            isIntercepting = interceptor.start()
        } else {
            interceptor.stop()
            isIntercepting = false
        }
    }

    /// Event-level settings come from the profile of the device kind that sent
    /// the event, because a CGEvent says whether it came from a continuous
    /// surface but not which device produced it.
    ///
    /// With one mouse attached this is exact. With two, both currently follow
    /// the first mouse's scroll and button settings — acceleration is genuinely
    /// per device, since that is written to each device rather than read off an
    /// event. Saying so is better than implying a precision that is not there.
    private func composedOptions() -> ScrollInterceptor.Options {
        let trackpad = devices.first { $0.isTrackpad }.map { store[$0.identity] }
        let mouse = devices.first { !$0.isTrackpad }.map { store[$0.identity] } ?? store.defaults
        var options = ScrollInterceptor.Options()
        options.reverseTrackpad = trackpad?.reverseScroll ?? false
        options.reverseMouse = mouse.reverseScroll
        options.linear = mouse.linearScroll
        options.linesPerNotch = mouse.linesPerNotch
        options.buttons = mouse.buttons
        return options
    }

    /// True when more than one mouse is attached, so the UI can say plainly
    /// that scroll and buttons are not yet told apart between them.
    var hasMultipleMice: Bool { devices.filter { !$0.isTrackpad }.count > 1 }

    // MARK: Editing the selected scope

    var profile: PointerProfile {
        get { scope.map { store[$0] } ?? store.defaults }
        set {
            if let scope = scope { store[scope] = newValue } else { store.defaults = newValue }
        }
    }

    var scopeIsCustomised: Bool { scope.map { store.isCustomised($0) } ?? false }
    var scopedDevice: PointerAcceleration.Device? {
        scope.flatMap { id in devices.first { $0.identity == id } }
    }

    /// Asked for by a profile. Deliberately does nothing while the feature is
    /// off: a rule may decide *how* the pointer behaves, not *whether* the
    /// user allowed Zephyr to touch it. Applies to the defaults, so it reaches
    /// every device that has not been given settings of its own.
    func setAccelerationByProfile(_ multiplier: Double) {
        guard isEnabled else { return }
        var updated = store
        updated.defaults.flattenAcceleration = true
        updated.defaults.accelerationMultiplier = multiplier
        store = updated
    }

    func followDefaults() {
        guard let scope = scope else { return }
        var updated = store
        updated.revertToDefaults(scope)
        store = updated
    }

    override func makeView() -> AnyView { AnyView(PointerView(feature: self)) }
}

private struct PointerView: View {
    @ObservedObject var feature: PointerFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !feature.isPermitted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Zephyr needs Accessibility permission to change scroll events and rebind buttons — without it macOS lets it watch them but not alter them.")
                        .font(.subheadline).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility settings") { feature.requestPermission() }
                }
                Divider()
            }

            HStack {
                Picker("These apply to", selection: Binding(
                    get: { feature.scope ?? "" },
                    set: { feature.scope = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Every pointing device").tag("")
                    ForEach(feature.devices, id: \.identity) { device in
                        Text(device.name + (feature.store.isCustomised(device.identity) ? " ·" : ""))
                            .tag(device.identity)
                    }
                }
                if feature.scopeIsCustomised {
                    Button("Follow the default") { feature.followDefaults() }
                }
            }

            Divider()
            scrollSection
            Divider()
            accelerationSection
            Divider()
            buttonSection
        }
        .onAppear { feature.refreshDevices() }
    }

    private var scrollSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Reverse scrolling", isOn: bind(\.reverseScroll))
            Toggle("Fixed distance per wheel notch", isOn: bind(\.linearScroll))
            if feature.profile.linearScroll {
                IntField(title: "Lines per notch", range: 1...10, suffix: "lines",
                         value: bind(\.linesPerNotch))
            }
            Text("Flattening applies to notched wheels only. A trackpad is a continuous surface, and pinning it to a step would make it feel broken.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if feature.hasMultipleMice {
                Text("More than one mouse is attached. Acceleration is written to each device separately and is exact; scroll direction and buttons are read off the event, which does not say which mouse sent it, so both currently follow the first mouse's settings.")
                    .font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accelerationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Take the acceleration out of the pointer", isOn: bind(\.flattenAcceleration))
            if feature.profile.flattenAcceleration {
                ValueField(title: "Acceleration, against the shipped curve",
                           range: 0...2, step: 0.05, suffix: "×",
                           value: bind(\.accelerationMultiplier))
                Text(feature.profile.accelerationMultiplier == 0
                     ? "Zero means the cursor tracks the hand one to one."
                     : "One is what the device shipped with.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let device = feature.scopedDevice {
                Text(String(format: "%@ — %@ at %.2f now", device.name, device.key, device.multiplier))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var buttonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Extra buttons").font(.headline)
            ForEach(PointerProfile.bindableButtons, id: \.self) { button in
                HStack {
                    Text(PointerProfile.buttonName(button))
                        .font(.subheadline).frame(width: 130, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { feature.profile.buttons[button] ?? .passThrough },
                        set: { action in
                            var profile = feature.profile
                            if action == .passThrough { profile.buttons.removeValue(forKey: button) }
                            else { profile.buttons[button] = action }
                            feature.profile = profile
                        }
                    )) {
                        ForEach(ButtonAction.selectable, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            Text("The primary and secondary click are deliberately not listed: rebinding those is how a mouse becomes unusable. A bound button is swallowed and its keystroke posted instead.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bind<T>(_ path: WritableKeyPath<PointerProfile, T>) -> Binding<T> {
        Binding(
            get: { feature.profile[keyPath: path] },
            set: { value in
                var profile = feature.profile
                profile[keyPath: path] = value
                feature.profile = profile
            }
        )
    }
}
