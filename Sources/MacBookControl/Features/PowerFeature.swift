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
    @Published private(set) var limits: PowerLimits.Reading?
    @Published var pl1: Double = 0
    @Published var pl2: Double = 0

    init(helper: HelperClient, turbo: TurboBoostController, telemetry: Telemetry) {
        self.helper = helper
        self.turbo = turbo
        self.telemetry = telemetry
        self.turboDisabled = turbo.isTurboDisabled()
        let reading = PowerLimits.current()
        self.limits = reading
        self.pl1 = reading?.pl1Watts ?? 0
        self.pl2 = reading?.pl2Watts ?? 0
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

    func refreshLimits() {
        limits = PowerLimits.current()
        if let reading = limits {
            pl1 = reading.pl1Watts
            pl2 = reading.pl2Watts
        }
    }

    func applyLimits() {
        guard isEnabled else { return }
        PowerLimits.apply(pl1Watts: pl1, pl2Watts: pl2)
        refreshLimits()
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
            PowerLimitControls(feature: feature)

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


/// The package power limit, when the kext that exposes it is loaded.
private struct PowerLimitControls: View {
    @ObservedObject var feature: PowerFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Power limit").font(.headline)
            if let reading = feature.limits {
                if let tdp = reading.tdpWatts {
                    Text(String(format: "Rated for %.0f W, hardware accepts %.0f–%.0f W",
                                tdp, reading.minWatts ?? 0, reading.maxWatts ?? tdp))
                        .font(.caption).foregroundColor(.secondary)
                }
                if reading.isLocked {
                    Text("The firmware has locked this register — writes are ignored by the hardware until the next power cycle. Nothing in software can change that.")
                        .font(.subheadline).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: "Currently PL1 %.0f W, PL2 %.0f W", reading.pl1Watts, reading.pl2Watts))
                        .font(.subheadline)
                } else {
                    Text(String(format: "Sustained (PL1) %.0f W", feature.pl1)).font(.subheadline)
                    Slider(value: Binding(get: { feature.pl1 }, set: { feature.pl1 = $0 }),
                           in: 10...(reading.maxWatts ?? 90), step: 1,
                           onEditingChanged: { editing in if !editing { feature.applyLimits() } })
                    Text(String(format: "Burst (PL2) %.0f W", feature.pl2)).font(.subheadline)
                    Slider(value: Binding(get: { feature.pl2 }, set: { feature.pl2 = $0 }),
                           in: 10...(reading.maxWatts ?? 120), step: 1,
                           onEditingChanged: { editing in if !editing { feature.applyLimits() } })
                    Text("Lowering the sustained limit is the substitute for undervolting on this machine: the undervolt register is locked by the firmware's Plundervolt mitigation, while this one is a mechanism Intel intends to be used.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Not available: the kext that publishes these registers is not loaded. MSRs are ring 0, so there is no way to read them from an ordinary process.")
                    .font(.subheadline).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { feature.refreshLimits() }
    }
}
