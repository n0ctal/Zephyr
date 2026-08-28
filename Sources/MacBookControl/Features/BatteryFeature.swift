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
    /// Above this the charger is held off. Zero is off.
    @Published var heatLimitCelsius: Int {
        didSet {
            Preferences.chargeHeatLimitCelsius = heatLimitCelsius
            if heatLimitCelsius == 0, isPaused { resumeAfterCooling() }
        }
    }

    /// True while charging is being held off because the cell is hot.
    @Published private(set) var isPaused = false

    /// The temperature the pause began at, for the sentence that explains it.
    @Published private(set) var pausedAt: Double?

    init(helper: HelperClient, telemetry: Telemetry) {
        self.helper = helper
        self.telemetry = telemetry
        self.limitPercent = Preferences.chargeLimitPercent
        self.heatLimitCelsius = Preferences.chargeHeatLimitCelsius
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
        startHeatWatch()
    }

    // MARK: Holding the charger off while the cell is hot

    /// Checked on the same rhythm as everything else, but acted on only at the
    /// edges: the ceiling is an SMC write, and writing it every two seconds
    /// because a number has not moved is not something to do to a battery
    /// controller.
    private func startHeatWatch() {
        guard heatWatch == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkHeat()
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        heatWatch = timer
        checkHeat()
    }

    /// What to do about the temperature, decided apart from doing it.
    enum HeatDecision: Equatable { case hold, resume, leaveAlone }

    /// Two degrees of hysteresis on the way down. Without it a cell sitting
    /// exactly on the limit has the ceiling rewritten every ten seconds, and
    /// the ceiling is an SMC write.
    static func heatDecision(celsius: Double?, limit: Int, isPaused: Bool) -> HeatDecision {
        guard limit > 0 else { return isPaused ? .resume : .leaveAlone }
        guard let celsius = celsius else { return .leaveAlone }
        if !isPaused, celsius >= Double(limit) { return .hold }
        if isPaused, celsius <= Double(limit) - 2 { return .resume }
        return .leaveAlone
    }

    private func checkHeat() {
        guard isEnabled else { return }
        let celsius = telemetry.battery?.celsius
        switch Self.heatDecision(celsius: celsius, limit: heatLimitCelsius, isPaused: isPaused) {
        case .hold:
            // Held off by dropping the ceiling to where the battery already
            // is: the firmware then simply stops taking charge, and the
            // machine keeps running from the adapter as it does at any
            // ceiling. Nothing discharges.
            let now = telemetry.battery?.percent ?? limitPercent
            helper.setChargeLimit(max(BatteryLimit.minimumPercent, min(limitPercent, now)))
            isPaused = true
            pausedAt = celsius
        case .resume:
            resumeAfterCooling()
        case .leaveAlone:
            break
        }
    }

    private func resumeAfterCooling() {
        isPaused = false
        pausedAt = nil
        guard isEnabled else { return }
        helper.setChargeLimit(limitPercent)
    }

    private var heatWatch: Timer?

    /// Back to charging all the way. The firmware keeps whatever it was last
    /// told, so leaving the ceiling in place after the feature is switched off
    /// would strand the battery at 80 % with nothing in the UI to explain it.
    override func deactivate() {
        heatWatch?.invalidate()
        heatWatch = nil
        isPaused = false
        pausedAt = nil
        helper.setChargeLimit(BatteryLimit.unlimited)
    }

    func setLimit(_ percent: Int) {
        limitPercent = percent
        Preferences.chargeLimitPercent = percent
        guard isEnabled else { return }
        helper.setChargeLimit(percent)
    }

    /// Battery temperature is the input, so it has to keep arriving whether
    /// or not anything is displaying it.
    override var telemetryNeeds: Telemetry.Needs {
        guard heatLimitCelsius > 0 else { return Telemetry.Needs() }
        var needs = Telemetry.Needs()
        needs.battery = true
        return needs
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

                MenuChoice(label: "Pause charging above",
                           selection: Binding(get: { feature.heatLimitCelsius },
                                              set: { feature.heatLimitCelsius = $0 }),
                           options: [("Never", 0)] + [30, 32, 35, 38, 40, 45].map {
                               ("\($0) °C", $0)
                           })
                if feature.isPaused, let at = feature.pausedAt {
                    Text(String(format: "Charging is held off: the cell reached %.0f °C.", at))
                        .font(.subheadline).foregroundColor(.orange)
                }
                Text("Heat and a high state of charge are the two things that age a lithium cell, and they arrive together — a battery filling inside a machine that is also working hard gets both at once. Above the chosen temperature the ceiling drops to wherever the charge already is, so the firmware stops taking any more; it goes back two degrees below, which stops the setting being rewritten every few seconds by a cell sitting exactly on the line.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
