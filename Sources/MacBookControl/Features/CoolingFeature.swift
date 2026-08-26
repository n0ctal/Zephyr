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
    /// The SMC key the curve follows. Empty is the CPU; `hottestSensorKey`
    /// is whichever sensor is hottest at the time.
    @Published var curveSensor: String {
        didSet { Preferences.curveSensorKey = curveSensor; reapplyCurve() }
    }
    @Published var curveMin: Double { didSet { Preferences.curveMinTemp = curveMin; reapplyCurve() } }
    @Published var curveMax: Double { didSet { Preferences.curveMaxTemp = curveMax; reapplyCurve() } }
    @Published var manualRPM: [Int: Int] { didSet { Preferences.manualFanRPM = manualRPM } }

    init(helper: HelperClient, telemetry: Telemetry) {
        self.helper = helper
        self.telemetry = telemetry
        self.mode = Preferences.coolingMode
        self.curveSensor = Preferences.curveSensorKey
        self.curveMin = Preferences.curveMinTemp
        self.curveMax = Preferences.curveMaxTemp
        self.manualRPM = Preferences.manualFanRPM
        super.init(id: "cooling",
                   title: "Cooling",
                   summary: "Drive the fans yourself instead of leaving them to the firmware, and see when heat is capping the CPU.")
    }

    /// Latched on the first sighting. Fan presence is a fact about the
    /// machine, not a reading: letting a momentarily empty poll answer this
    /// would make the whole tab vanish behind "no fans found" and stay there,
    /// since nothing re-asks.
    private lazy var hasFans: Bool = !telemetry.fans.isEmpty

    override var isSupported: Bool {
        if !hasFans && !telemetry.fans.isEmpty { hasFans = true }
        return hasFans
    }
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
        for fan in telemetry.fans {
            helper.setFanCurve(fan: fan.index, curve: curve, sensor: curveSensor)
        }
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
            SegmentedChoice(label: "Fans follow", selection: $feature.mode,
                            options: [("Firmware", "auto"),
                                      ("Temperature curve", "curve"),
                                      ("Fixed speed", "manual")])

            if feature.mode == "curve" {
                VStack(alignment: .leading, spacing: 6) {
                    MenuChoice(label: "Follow", selection: $feature.curveSensor,
                               options: [("Whatever looks like the CPU", ""),
                                         ("The hottest sensor of the moment",
                                          FanCurve.hottestSensorKey)]
                                   + telemetry.temperatures.map {
                                       ("\($0.label) — \(Int($0.celsius)) °C", $0.key)
                                   })
                    ValueField(title: "Start lifting the fans at", range: 40...80, step: 1,
                               suffix: "°C", value: $feature.curveMin)
                    ValueField(title: "Reach full speed at", range: 60...100, step: 1,
                               suffix: "°C", value: $feature.curveMax)
                    Text("The curve interpolates between each fan's own minimum and maximum, so it fits whatever fans this machine has.")
                        .font(.caption).foregroundColor(.secondary)
                    Text(feature.curveSensor == FanCurve.hottestSensorKey
                         ? "Reading every sensor and following the highest — the safest choice, and the one that runs the fans most. It costs a few extra readings a second, nothing more."
                         : "The temperature is read by the part of Zephyr that runs as root, not handed to it: a control loop that stops when the app stops answering is one that leaves the fans pinned. A sensor that goes missing falls back to the CPU rather than switching the curve off.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if feature.mode == "manual" {
                ForEach(telemetry.fans, id: \.index) { fan in
                    IntField(title: "Fan \(fan.index + 1) — \(fan.actualRPM) rpm now",
                             range: fan.minRPM...fan.maxRPM,
                             suffix: "rpm",
                             value: Binding(
                                get: { feature.manualRPM[fan.index] ?? fan.actualRPM },
                                set: { feature.setManual(fan: fan.index, rpm: $0) }
                             ))
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
