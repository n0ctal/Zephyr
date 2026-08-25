import SwiftUI

/// Keeps the Mac from falling asleep.
///
/// Deliberately three switches rather than one: keeping the machine running
/// and keeping the screen lit are different wishes, and a long build wants
/// the first without the second.
final class AwakeFeature: Feature {
    private let inhibitor = SleepInhibitor()

    @Published var keepDisplayOn: Bool { didSet { Preferences.awakeKeepsDisplayOn = keepDisplayOn; reapply() } }
    @Published var throughLidClose: Bool { didSet { Preferences.awakeWhenLidClosed = throughLidClose; reapply() } }
    @Published var durationMinutes: Int { didSet { Preferences.awakeDurationMinutes = durationMinutes; reapply() } }

    init() {
        self.keepDisplayOn = Preferences.awakeKeepsDisplayOn
        self.throughLidClose = Preferences.awakeWhenLidClosed
        self.durationMinutes = Preferences.awakeDurationMinutes
        super.init(id: "awake",
                   title: "Awake",
                   summary: "Hold the Mac awake while something long is running, instead of watching the screen to keep it alive.")
    }

    override func activate() { reapply() }

    /// Asked for by a profile. Deliberately does nothing while the feature is
    /// off: a rule may decide *when* the Mac is held awake, not *whether* the
    /// user allowed it to be.
    func setEnabledByProfile(_ on: Bool) {
        guard isEnabled else { return }
        on ? reapply() : inhibitor.releaseAll()
    }
    override func deactivate() { inhibitor.releaseAll() }

    func reapply() {
        guard isEnabled else { return }
        inhibitor.apply(keepSystemAwake: true,
                        keepDisplayOn: keepDisplayOn,
                        throughLidClose: throughLidClose,
                        minutes: durationMinutes)
    }

    override func makeView() -> AnyView { AnyView(AwakeView(feature: self)) }
}

private struct AwakeView: View {
    @ObservedObject var feature: AwakeFeature

    private static let durations: [(String, Int)] = [
        ("Until I turn it off", 0), ("15 minutes", 15), ("1 hour", 60),
        ("2 hours", 120), ("5 hours", 300),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Hold awake", selection: Binding(
                get: { feature.durationMinutes },
                set: { feature.durationMinutes = $0 }
            )) {
                ForEach(Self.durations, id: \.1) { Text($0.0).tag($0.1) }
            }

            Toggle("Keep the display on too", isOn: Binding(
                get: { feature.keepDisplayOn },
                set: { feature.keepDisplayOn = $0 }
            ))
            Text("Off means the screen may sleep while whatever is running underneath keeps going.")
                .font(.caption).foregroundColor(.secondary)

            Toggle("Stay awake with the lid closed", isOn: Binding(
                get: { feature.throughLidClose },
                set: { feature.throughLidClose = $0 }
            ))
            Text(SleepInhibitor.isOnExternalPower
                 ? "The firmware only honours this while power is attached. It is attached now."
                 : "The firmware only honours this while power is attached — on battery the Mac will still sleep when you close it.")
                .font(.caption)
                .foregroundColor(SleepInhibitor.isOnExternalPower ? .secondary : .orange)
        }
    }
}
