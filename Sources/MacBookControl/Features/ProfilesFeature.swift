import SwiftUI

/// User-written rules: what to set, and when.
final class ProfilesFeature: Feature {
    @Published var profiles: [Profile] {
        didSet {
            Preferences.profiles = profiles
            // The circumstances have not changed but what they should produce
            // may have, so an edit re-applies rather than waiting for the next
            // context change to notice.
            engine?.reapply()
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
        if let id = feature.selection, let profile = feature.binding(for: id) {
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

            ForEach(Array(profile.conditions.enumerated()), id: \.offset) { index, condition in
                HStack {
                    Text("• \(condition.label)").font(.subheadline)
                    Spacer()
                    Button("Remove") { profile.conditions.remove(at: index) }
                        .buttonStyle(BorderlessButtonStyle())
                }
            }
            conditionMenu

            Divider()
            Text("Then set").font(.headline)
            ForEach(Array(profile.actions.enumerated()), id: \.offset) { index, action in
                HStack {
                    Text("• \(action.label)").font(.subheadline)
                    Spacer()
                    Button("Remove") { profile.actions.remove(at: index) }
                        .buttonStyle(BorderlessButtonStyle())
                }
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
            Button("Between 22:00 and 08:00") { profile.conditions.append(.timeBetween(startMinutes: 22 * 60, endMinutes: 8 * 60)) }
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
            Button("Stop charging at 80 %") { profile.actions.append(.chargeLimit(80)) }
            Button("Charge to full") { profile.actions.append(.chargeLimit(100)) }
            Button("Keep awake") { profile.actions.append(.keepAwake(true)) }
            Button("Allow sleep") { profile.actions.append(.keepAwake(false)) }
        }
        .frame(width: 200)
    }
}
