import SwiftUI

/// User-written rules: what to set, and when.
final class ProfilesFeature: Feature {
    /// The union of what every rule needs to be decided. A profile the user
    /// has switched off asks for nothing.
    override func reloadFromPreferences() {
        let stored = Preferences.profiles
        guard stored != profiles else { return }
        // What the engine believes is active was built from the old list, and
        // the re-apply that assigning triggers would apply *that* — an edited
        // profile's previous actions, after which evaluation sees the same id
        // and decides there is nothing to do. So the belief goes first.
        engine?.forget()
        profiles = stored
        _ = engine?.evaluate(stored)
    }

    override var telemetryNeeds: Telemetry.Needs {
        profiles.filter(\.isEnabled)
            .flatMap(\.conditions)
            .reduce(Telemetry.Needs()) { $0.union($1.telemetryNeeds) }
    }

    @Published var profiles: [Profile] {
        didSet {
            Preferences.profiles = profiles
            // The circumstances have not changed but what they should produce
            // may have, so an edit re-applies rather than waiting for the next
            // context change to notice.
            engine?.reapply()
            // A rule that now samples something new changes what telemetry
            // has to keep reading.
            Feature.needsDidChange()
            evaluate()
        }
    }
    @Published private(set) var activeName: String?
    @Published var selection: UUID?

    private var engine: ProfileEngine?
    private var timer: Timer?

    init() {
        profiles = Preferences.profiles
        super.init(id: "profiles",
                   title: "Profiles",
                   summary: "Set several things at once when the circumstances call for it — docked, on battery, running something heavy.")
    }

    /// Wired after the registry exists, since the engine drives the other
    /// features and cannot be built alongside them.
    func attach(registry: FeatureRegistry, telemetry: Telemetry) {
        engine = ProfileEngine(registry: registry, telemetry: telemetry)
    }

    /// Two examples on first use. An empty Profiles tab explains nothing —
    /// seeing a rule already written is how the shape of one becomes obvious.
    /// They are safe by construction: a profile can only drive features the
    /// user has already switched on, so neither does anything on a fresh
    /// install until Power, Graphics or Battery is enabled too.
    private static let starters: [Profile] = [
        Profile(name: "On battery",
                conditions: [.onExternalPower(false)],
                actions: [.turboDisabled(true),
                          .gpuMode(GPUMode.integratedOnly.rawValue),
                          .chargeLimit(80)]),
        Profile(name: "Docked",
                conditions: [.onExternalPower(true), .externalDisplayAttached(true)],
                actions: [.turboDisabled(false),
                          .gpuMode(GPUMode.discreteOnly.rawValue),
                          .keepAwake(true)]),
    ]

    override func activate() {
        if profiles.isEmpty { profiles = Self.starters }
        guard timer == nil else { return }
        // Ten seconds: fast enough that plugging in a charger feels immediate,
        // slow enough that the sampling costs nothing measurable.
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        // Let the system line this wake-up up with others; nothing here
        // needs to land on the second.
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        evaluate()
    }

    override func deactivate() {
        timer?.invalidate()
        timer = nil
        engine?.forget()
        activeName = nil
        // What a profile already applied is left in place. Undoing it would
        // mean guessing at a state that was never recorded, and the individual
        // features each own their own "off" already.
    }

    private func evaluate() {
        guard isEnabled, let engine = engine else { return }
        engine.evaluate(profiles)
        activeName = engine.activeProfile?.name
    }

    // MARK: Editing

    func add() {
        let profile = Profile(name: "New profile",
                              conditions: [.onExternalPower(true)],
                              actions: [.turboDisabled(false)])
        profiles.append(profile)
        selection = profile.id
    }

    func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if selection == id { selection = profiles.first?.id }
        engine?.forget()
        evaluate()
    }

    func move(_ id: UUID, up: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard profiles.indices.contains(target) else { return }
        profiles.swapAt(index, target)
    }

    func binding(for id: UUID) -> Binding<Profile>? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.profiles[index] }, set: { self.profiles[index] = $0 })
    }

    override func makeView() -> AnyView { AnyView(ProfilesView(feature: self)) }
}

private struct ProfilesView: View {
    @ObservedObject var feature: ProfilesFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(feature.activeName.map { "In force now: \($0)" }
                 ?? "No profile matches the current circumstances.")
                .font(.subheadline)
                .foregroundColor(feature.activeName == nil ? .secondary : .primary)

            HStack(alignment: .top, spacing: 12) {
                profileList
                Divider()
                editor
            }
            .onAppear {
                if feature.selection == nil { feature.selection = feature.profiles.first?.id }
            }
        }
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(feature.profiles) { profile in
                HStack(spacing: 4) {
                    Button(action: { feature.selection = profile.id }) {
                        Text(profile.name)
                            .fontWeight(feature.selection == profile.id ? .bold : .regular)
                            .foregroundColor(profile.isEnabled ? .primary : .secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    Spacer()
                    Button("↑") { feature.move(profile.id, up: true) }.buttonStyle(BorderlessButtonStyle())
                    Button("↓") { feature.move(profile.id, up: false) }.buttonStyle(BorderlessButtonStyle())
                }
            }
            Button("Add profile") { feature.add() }
            Text("When two match, the one higher in this list wins — so put the specific ones above the general.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 230, alignment: .leading)
    }

    @ViewBuilder private var editor: some View {
        // Nothing selected leaves half the tab blank next to a list that is
        // plainly not empty, which reads as broken rather than as a prompt.
        if let id = feature.selection ?? feature.profiles.first?.id,
           let profile = feature.binding(for: id) {
            ProfileEditor(profile: profile, onDelete: { feature.remove(id) })
        } else {
            Text("Pick a profile, or add one.").foregroundColor(.secondary)
        }
    }
}

private struct ProfileEditor: View {
    @Binding var profile: Profile
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $profile.name).frame(width: 200)
                Toggle("Active", isOn: $profile.isEnabled)
                Spacer()
                Button("Delete", action: onDelete)
            }

            Picker("Fires when", selection: $profile.requiresAll) {
                Text("all of these hold").tag(true)
                Text("any of these hold").tag(false)
            }

            ForEach(Array(profile.conditions.enumerated()), id: \.offset) { index, _ in
                ConditionRow(
                    condition: Binding(
                        get: { profile.conditions[index] },
                        set: { profile.conditions[index] = $0 }
                    ),
                    onRemove: { profile.conditions.remove(at: index) }
                )
            }
            conditionMenu

            Divider()
            Text("Then set").font(.headline)
            ForEach(Array(profile.actions.enumerated()), id: \.offset) { index, _ in
                ActionRow(
                    action: Binding(
                        get: { profile.actions[index] },
                        set: { profile.actions[index] = $0 }
                    ),
                    onRemove: { profile.actions.remove(at: index) }
                )
            }
            actionMenu

            Text("A profile only touches what it lists here, so two profiles can own different halves of the machine without fighting.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var conditionMenu: some View {
        Menu("Add condition") {
            Button("On mains power") { profile.conditions.append(.onExternalPower(true)) }
            Button("On battery") { profile.conditions.append(.onExternalPower(false)) }
            Button("Battery below 30 %") { profile.conditions.append(.batteryBelow(30)) }
            Button("External display attached") { profile.conditions.append(.externalDisplayAttached(true)) }
            Button("No external display") { profile.conditions.append(.externalDisplayAttached(false)) }
            Button("CPU above 80 °C") { profile.conditions.append(.cpuHotterThan(80)) }
            Button("CPU load above 60 %") { profile.conditions.append(.cpuLoadAbove(60)) }
            Button("Between two times") { profile.conditions.append(.timeBetween(startMinutes: 22 * 60, endMinutes: 8 * 60)) }
            Button("An app is running") { profile.conditions.append(.appRunning("Xcode")) }
            Button("On a named Wi-Fi network") { profile.conditions.append(.wifiNetwork("")) }
        }
        .frame(width: 200)
    }

    private var actionMenu: some View {
        Menu("Add setting") {
            Button("Turbo Boost off") { profile.actions.append(.turboDisabled(true)) }
            Button("Turbo Boost on") { profile.actions.append(.turboDisabled(false)) }
            Button("Fans follow the curve") { profile.actions.append(.coolingMode("curve")) }
            Button("Fans to the firmware") { profile.actions.append(.coolingMode("auto")) }
            Button("Integrated graphics only") { profile.actions.append(.gpuMode(GPUMode.integratedOnly.rawValue)) }
            Button("Discrete graphics only") { profile.actions.append(.gpuMode(GPUMode.discreteOnly.rawValue)) }
            Button("Stop charging at a level") { profile.actions.append(.chargeLimit(80)) }
            Button("Fan curve range") { profile.actions.append(.fanCurve(min: 55, max: 85)) }
            Button("Pointer acceleration") { profile.actions.append(.pointerAcceleration(0)) }
            Button("Charge to full") { profile.actions.append(.chargeLimit(100)) }
            Button("Keep awake") { profile.actions.append(.keepAwake(true)) }
            Button("Allow sleep") { profile.actions.append(.keepAwake(false)) }
        }
        .frame(width: 200)
    }
}

/// One condition, editable where it stands.
///
/// The menu that adds these can only offer a starting value — "battery below
/// 30 %" is a guess at what someone meant. Being able to change it to 50, or
/// to type which app matters, is the difference between rules that are yours
/// and rules that are a fixed list someone else chose.
private struct ConditionRow: View {
    @Binding var condition: Condition
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            editor
            Spacer()
            Button("Remove", action: onRemove).buttonStyle(BorderlessButtonStyle())
        }
    }

    @ViewBuilder private var editor: some View {
        switch condition {
        case .onExternalPower(let on):
            Text("Power is").font(.subheadline)
            MenuChoice(label: nil,
                       selection: Binding(get: { on },
                                          set: { condition = .onExternalPower($0) }),
                       options: [("mains", true), ("battery", false)])

        case .batteryBelow(let percent):
            Text("Battery below").font(.subheadline)
            CompactNumberField(range: 1...100, suffix: "%", value: Binding(
                get: { percent }, set: { condition = .batteryBelow($0) }
            ))

        case .externalDisplayAttached(let attached):
            Text("External display").font(.subheadline)
            MenuChoice(label: nil,
                       selection: Binding(get: { attached },
                                          set: { condition = .externalDisplayAttached($0) }),
                       options: [("attached", true), ("absent", false)])

        case .appRunning(let name):
            Text("App running").font(.subheadline)
            TextField("name", text: Binding(
                get: { name }, set: { condition = .appRunning($0) }
            )).frame(width: 140)

        case .wifiNetwork(let ssid):
            Text("Wi-Fi network").font(.subheadline)
            TextField("SSID", text: Binding(
                get: { ssid }, set: { condition = .wifiNetwork($0) }
            )).frame(width: 140)

        case .timeBetween(let start, let end):
            Text("Between").font(.subheadline)
            TimeField(minutes: Binding(
                get: { start }, set: { condition = .timeBetween(startMinutes: $0, endMinutes: end) }
            ))
            Text("and").font(.subheadline)
            TimeField(minutes: Binding(
                get: { end }, set: { condition = .timeBetween(startMinutes: start, endMinutes: $0) }
            ))

        case .cpuHotterThan(let celsius):
            Text("CPU above").font(.subheadline)
            CompactNumberField(range: 40...105, suffix: "°C", value: Binding(
                get: { fieldValue(celsius, 40...105) }, set: { condition = .cpuHotterThan(Double($0)) }
            ))
        case .cpuLoadAbove(let percent):
            Text("CPU load above").font(.subheadline)
            CompactNumberField(range: 5...100, suffix: "%", value: Binding(
                get: { fieldValue(percent, 5...100) }, set: { condition = .cpuLoadAbove(Double($0)) }
            ))
        }
    }
}

/// One setting a profile applies, editable in place for the same reason.
private struct ActionRow: View {
    @Binding var action: Action
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            editor
            Spacer()
            Button("Remove", action: onRemove).buttonStyle(BorderlessButtonStyle())
        }
    }

    @ViewBuilder private var editor: some View {
        switch action {
        case .coolingMode(let mode):
            Text("Fans follow").font(.subheadline)
            MenuChoice(label: nil,
                       selection: Binding(get: { mode }, set: { action = .coolingMode($0) }),
                       options: [("firmware", "auto"), ("curve", "curve"), ("fixed", "manual")])

        case .fanCurve(let low, let high):
            Text("Curve").font(.subheadline)
            CompactNumberField(range: 40...80, suffix: "°C", value: Binding(
                get: { fieldValue(low, 40...80) }, set: { action = .fanCurve(min: Double($0), max: high) }
            ))
            Text("to").font(.subheadline)
            CompactNumberField(range: 60...105, suffix: "°C", value: Binding(
                get: { fieldValue(high, 60...105) }, set: { action = .fanCurve(min: low, max: Double($0)) }
            ))

        case .turboDisabled(let off):
            Text("Turbo Boost").font(.subheadline)
            MenuChoice(label: nil,
                       selection: Binding(get: { off }, set: { action = .turboDisabled($0) }),
                       options: [("off", true), ("on", false)])

        case .gpuMode(let raw):
            Text("Graphics").font(.subheadline)
            MenuChoice(label: nil,
                       selection: Binding(get: { raw }, set: { action = .gpuMode($0) }),
                       options: GPUMode.allCases.map { ($0.label, $0.rawValue) })

        case .chargeLimit(let percent):
            Text("Stop charging at").font(.subheadline)
            CompactNumberField(range: 20...100, suffix: "%", value: Binding(
                get: { percent }, set: { action = .chargeLimit($0) }
            ))

        case .keepAwake(let on):
            Text("Sleep").font(.subheadline)
            MenuChoice(label: nil,
                       selection: Binding(get: { on }, set: { action = .keepAwake($0) }),
                       options: [("prevented", true), ("allowed", false)])

        case .pointerAcceleration(let value):
            Text("Pointer acceleration").font(.subheadline)
            CompactNumberField(range: 0...200, suffix: "%", value: Binding(
                get: { fieldValue(value * 100, 0...200) }, set: { action = .pointerAcceleration(Double($0) / 100) }
            ))
        }
    }
}

/// Minutes since midnight, typed as a clock. Two number boxes would be
/// technically equivalent and nobody thinks of half past ten as 630.
private struct TimeField: View {
    @Binding var minutes: Int
    @State private var text = ""

    var body: some View {
        TextField("HH:MM", text: $text, onCommit: commit)
            .frame(width: 62)
            .multilineTextAlignment(.center)
            .onAppear { text = Condition.clock(minutes) }
            .onChange(of: minutes) { text = Condition.clock($0) }
    }

    private func commit() {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else {
            text = Condition.clock(minutes)   // unparseable: put back what it was
            return
        }
        minutes = hour * 60 + minute
    }
}

/// A stored figure as a field can show it.
///
/// Profiles are decoded out of the preferences file, and `Int(_:)` traps
/// rather than saturating — on a value that is not a number as much as on one
/// past its range. A view body is a poor place to find that out. The field's
/// own range is the natural bound and is right there at every call.
/// Infinity clamps to the end it is nearest, as any other large figure does.
/// Only NaN takes the short way out, because every comparison with it is false
/// and `min`/`max` would carry it through.
func fieldValue(_ value: Double, _ range: ClosedRange<Int>) -> Int {
    guard !value.isNaN else { return range.lowerBound }
    return Int(Swift.min(Swift.max(value.rounded(), Double(range.lowerBound)),
                         Double(range.upperBound)))
}
