import SwiftUI

/// A ceiling on the charge, and the numbers that justify one.
///
/// A lithium cell held at 100 % ages faster than one held at 80 %, which is
/// the whole argument for the feature. The ceiling is the SMC's own `BCLM`
/// key, so the firmware enforces it — Zephyr does not have to stay running.
final class BatteryFeature: Feature {
    private let helper: HelperClient
    private let telemetry: Telemetry

    @Published var limitPercent: Int

    init(helper: HelperClient, telemetry: Telemetry) {
        self.helper = helper
        self.telemetry = telemetry
        self.limitPercent = Preferences.chargeLimitPercent
        super.init(id: "battery",
                   title: "Battery",
                   summary: "Stop charging below full. A battery kept near 80 % ages markedly slower than one held at 100 %.")
    }

    override var isSupported: Bool { BatteryLimit.isSupported() }
    override var unsupportedReason: String? {
        isSupported ? nil : "This Mac's SMC does not expose a charge ceiling."
    }

    override func activate() {
        helper.setChargeLimit(limitPercent)
    }

    /// Back to charging all the way. The firmware keeps whatever it was last
    /// told, so leaving the ceiling in place after the feature is switched off
    /// would strand the battery at 80 % with nothing in the UI to explain it.
    override func deactivate() {
        helper.setChargeLimit(BatteryLimit.unlimited)
    }

    func setLimit(_ percent: Int) {
        limitPercent = percent
        Preferences.chargeLimitPercent = percent
        guard isEnabled else { return }
        helper.setChargeLimit(percent)
    }

    override func makeView() -> AnyView { AnyView(BatteryView(feature: self, telemetry: telemetry)) }
}

private struct BatteryView: View {
    @ObservedObject var feature: BatteryFeature
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                IntField(title: "Stop charging at",
                         range: BatteryLimit.minimumPercent...BatteryLimit.unlimited,
                         suffix: "%",
                         value: Binding(
                            get: { feature.limitPercent },
                            set: { feature.setLimit($0) }
                         ))
                Text("Setting a ceiling below the current charge does not discharge the battery — the machine simply runs off the adapter until the level drifts down on its own.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Divider()
            Toggle("Show where the watts are going", isOn: Binding(
                get: { Preferences.showPowerFlow },
                set: { Preferences.showPowerFlow = $0; feature.objectWillChange.send() }
            ))
            if Preferences.showPowerFlow, let draw = telemetry.battery?.power {
                PowerFlowView(draw: draw, isPluggedIn: telemetry.battery?.isPluggedIn ?? false)
            }

            Divider()
            if let battery = telemetry.battery {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(battery.percent) % · \(battery.stateLabel)").font(.headline)
                    if let health = battery.healthPercent, let cycles = battery.cycleCount {
                        Text("Health \(health) % of design capacity, \(cycles) cycles")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                    // The two capacities behind that percentage, and the
                    // temperature the cell is sitting at. A share says how far
                    // the battery has fallen; the milliamp-hours say how much
                    // charge is actually left to work with, and heat is what
                    // decides how quickly the first number falls.
                    if let full = battery.fullChargeCapacity, let design = battery.designCapacity {
                        Text("\(full) mAh of \(design) mAh when new"
                             + (battery.celsius.map { String(format: " · %.0f °C", $0) } ?? ""))
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                    if let draw = battery.power, let watts = draw.batteryWatts, abs(watts) >= 0.1 {
                        Text(String(format: watts > 0 ? "Charging at %.1f W" : "Drawing %.1f W from the battery", abs(watts)))
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                }
            } else {
                Text("No battery found.").foregroundColor(.secondary)
            }
        }
    }
}
