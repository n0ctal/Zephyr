import SwiftUI

/// What the CPU is allowed to draw.
///
/// Turbo Boost is the blunt lever: off, the i9 stops sprinting to 4.8 GHz and
/// the machine runs perceptibly cooler and quieter at a cost in burst speed.
/// It is implemented by a kext that sets `IA32_MISC_ENABLE` bit 38, so it
/// needs SIP disabled and a one-time approval — which is why the tab explains
/// itself when the kext is missing rather than showing a switch that fails.
final class PowerFeature: Feature {
    private let helper: HelperClient
    private let turbo: TurboBoostController
    private let telemetry: Telemetry

    @Published var turboDisabled: Bool

    init(helper: HelperClient, turbo: TurboBoostController, telemetry: Telemetry) {
        self.helper = helper
        self.turbo = turbo
        self.telemetry = telemetry
        self.turboDisabled = turbo.isTurboDisabled()
        super.init(id: "power",
                   title: "Power",
                   summary: "Cap how hard the CPU is allowed to push. Less heat and less fan noise, at the cost of peak speed.")
    }

    override var isSupported: Bool { turbo.isAvailable }
    override var unsupportedReason: String? {
        isSupported ? nil : "The Turbo Boost kext is not installed. It needs System Integrity Protection disabled, which is a deliberate choice — Zephyr will not make it for you."
    }

    /// Re-asserts the stored choice. Enabling the feature must not silently
    /// change the CPU: if the user never asked for turbo off, leave it on.
    override func activate() {
        helper.setTurboBoostEnabled(!turboDisabled)
    }

    /// Turbo Boost back on. Leaving a machine derated by a feature the user
    /// switched off would be a lie about what "off" means.
    override func deactivate() {
        helper.setTurboBoostEnabled(true)
    }

    func setTurboDisabled(_ disabled: Bool) {
        turboDisabled = disabled
        guard isEnabled else { return }
        helper.setTurboBoostEnabled(!disabled)
    }

    override func makeView() -> AnyView { AnyView(PowerView(feature: self, telemetry: telemetry)) }
}

private struct PowerView: View {
    @ObservedObject var feature: PowerFeature
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Disable Turbo Boost", isOn: Binding(
                get: { feature.turboDisabled },
                set: { feature.setTurboDisabled($0) }
            ))
            Text("The firmware restores this register across sleep, so Zephyr re-applies it on every wake. Without that the setting quietly lapses overnight.")
                .font(.caption).foregroundColor(.secondary)

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Draw").font(.headline)
                if let draw = telemetry.battery?.power {
                    if let system = draw.systemWatts {
                        Text(String(format: "System %.1f W", system)).font(.subheadline)
                    }
                    if let adapter = draw.adapterWatts {
                        Text(String(format: "Adapter %.1f W", adapter)).font(.subheadline)
                    }
                } else {
                    Text("No power sensors answered.").font(.subheadline).foregroundColor(.secondary)
                }
            }
        }
    }
}
