import SwiftUI

/// Fans and what the heat is costing you.
///
/// Fan control and the throttling readout share a tab because they are the
/// same story told twice: the fans are what you can do about it, the speed
/// cap is what happens when it is not enough.
final class CoolingFeature: Feature {
    private let helper: HelperClient
    private let telemetry: Telemetry

    /// `auto` hands the fans back to the firmware, `curve` follows CPU
    /// temperature, `manual` pins each fan to a chosen speed.
    @Published var mode: String {
        didSet {
            Preferences.coolingMode = mode
            if isEnabled { activate() }
        }
    }
    @Published var curveMin: Double { didSet { Preferences.curveMinTemp = curveMin; reapplyCurve() } }
    @Published var curveMax: Double { didSet { Preferences.curveMaxTemp = curveMax; reapplyCurve() } }
    @Published var manualRPM: [Int: Int] { didSet { Preferences.manualFanRPM = manualRPM } }

    init(helper: HelperClient, telemetry: Telemetry) {
        self.helper = helper
        self.telemetry = telemetry
        self.mode = Preferences.coolingMode
        self.curveMin = Preferences.curveMinTemp
        self.curveMax = Preferences.curveMaxTemp
        self.manualRPM = Preferences.manualFanRPM
        super.init(id: "cooling",
                   title: "Cooling",
                   summary: "Drive the fans yourself instead of leaving them to the firmware, and see when heat is capping the CPU.")
    }

    override var isSupported: Bool { !telemetry.fans.isEmpty }
    override var unsupportedReason: String? {
        isSupported ? nil : "No controllable fans were found. Fanless Macs cool passively, so there is nothing here to drive."
    }

    override func activate() {
        switch mode {
        case "manual":
            for fan in telemetry.fans {
                guard let rpm = manualRPM[fan.index] else { continue }
                helper.setFanManual(fan: fan.index, rpm: rpm)
            }
        case "curve":
            reapplyCurve()
        default:
            helper.setAllFansAuto()
        }
    }

    /// Hands every fan back to the firmware. Anything else would leave the
    /// machine pinned to a speed chosen by a process that has stopped caring.
    override func deactivate() {
        helper.setAllFansAuto()
    }

    private func reapplyCurve() {
        guard isEnabled, mode == "curve" else { return }
        let curve = FanCurve(minTemp: curveMin, maxTemp: curveMax)
        for fan in telemetry.fans { helper.setFanCurve(fan: fan.index, curve: curve) }
    }

    func setManual(fan: Int, rpm: Int) {
        manualRPM[fan] = rpm
        guard isEnabled, mode == "manual" else { return }
        helper.setFanManual(fan: fan, rpm: rpm)
    }

    override func makeView() -> AnyView { AnyView(CoolingView(feature: self, telemetry: telemetry)) }
}

private struct CoolingView: View {
    @ObservedObject var feature: CoolingFeature
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Fans follow", selection: $feature.mode) {
                Text("Firmware").tag("auto")
                Text("Temperature curve").tag("curve")
                Text("Fixed speed").tag("manual")
            }
            .pickerStyle(SegmentedPickerStyle())

            if feature.mode == "curve" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start lifting the fans at \(Int(feature.curveMin)) °C")
                        .font(.subheadline)
                    Slider(value: $feature.curveMin, in: 40...80, step: 1)
                    Text("Reach full speed at \(Int(feature.curveMax)) °C")
                        .font(.subheadline)
                    Slider(value: $feature.curveMax, in: 60...100, step: 1)
                    Text("The curve reads CPU temperature and interpolates between each fan's own minimum and maximum, so it fits whatever fans this machine has.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            if feature.mode == "manual" {
                ForEach(telemetry.fans, id: \.index) { fan in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fan \(fan.index + 1) — \(fan.actualRPM) rpm now")
                            .font(.subheadline)
                        Slider(
                            value: Binding(
                                get: { Double(feature.manualRPM[fan.index] ?? fan.actualRPM) },
                                set: { feature.setManual(fan: fan.index, rpm: Int($0)) }
                            ),
                            in: Double(fan.minRPM)...Double(fan.maxRPM),
                            step: 50
                        )
                    }
                }
            }

            Divider()
            ThrottleReadout(telemetry: telemetry)
        }
    }
}

private struct ThrottleReadout: View {
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Throttling").font(.headline)
            if let thermal = telemetry.thermal, let limit = thermal.speedLimitPercent {
                Text(limit < 100
                     ? "The firmware is holding the CPU at \(limit) % of full speed right now."
                     : "The CPU is running at full speed.")
                    .font(.subheadline)
            } else {
                Text("Reading…").font(.subheadline).foregroundColor(.secondary)
            }
            if telemetry.stats.everThrottled {
                Text("Lowest this session: \(telemetry.stats.lowestSpeedLimit) % · held back for \(telemetry.stats.throttledLabel)")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("Nothing has been capped since Zephyr started.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
}
