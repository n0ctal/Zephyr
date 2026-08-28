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
    /// The SMC key each fan's curve follows. Empty is the CPU;
    /// `hottestSensorKey` is whichever sensor is hottest at the time.
    ///
    /// Kept per fan: on this machine one sits by the processor and the other
    /// by the graphics card, and making both chase the same number is why one
    /// of them is always either too loud or too late.
    @Published var curveSensors: [Int: String] = [:]

    func curveSensor(fan: Int) -> String {
        curveSensors[fan] ?? Preferences.curveSensorKey(fan: fan)
    }

    func setCurveSensor(_ key: String, fan: Int) {
        curveSensors[fan] = key
        Preferences.setCurveSensorKey(key, fan: fan)
        reapplyCurve()
    }
    @Published var curveMin: Double { didSet { Preferences.curveMinTemp = curveMin; reapplyCurve() } }
    @Published var curveMax: Double { didSet { Preferences.curveMaxTemp = curveMax; reapplyCurve() } }
    @Published var manualRPM: [Int: Int] { didSet { Preferences.manualFanRPM = manualRPM } }

    /// Which unit the fixed speeds are written in.
    ///
    /// A share is the honest way to drive both fans with one control, since
    /// two fans with different ranges are not doing the same work at the same
    /// revolution count. Revolutions are the honest way to drive one fan on
    /// purpose — and the number every other fan utility shows, which is reason
    /// enough to offer it rather than insist.
    @Published var speedInRPM: Bool { didSet { Preferences.fanSpeedInRPM = speedInRPM } }

    init(helper: HelperClient, telemetry: Telemetry) {
        self.helper = helper
        self.telemetry = telemetry
        self.mode = Preferences.coolingMode
        self.speedInRPM = Preferences.fanSpeedInRPM

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
            helper.setFanCurve(fan: fan.index, curve: curve, sensor: curveSensor(fan: fan.index))
        }
    }

    /// Every fan at the same share of its own range.
    ///
    /// A share rather than a speed, because the two fans in this machine do not
    /// have the same range — 1836…5616 and 1800…5200 here — so "5000 rpm on
    /// both" is not the same amount of cooling on each, while "75 %" is.
    ///
    /// Zero is each fan's own minimum, not a stop. These fans cannot be
    /// stopped: the firmware refuses a target below the minimum it reports,
    /// and a fan that could be stopped from a settings window would be the one
    /// control in this app able to cook the machine.
    func setAllFans(percent: Double) {
        for fan in telemetry.fans {
            setManual(fan: fan.index,
                      rpm: Self.targetRPM(percent: percent,
                                          min: fan.minRPM, max: fan.maxRPM))
        }
    }

    /// Pure, and separate, because it is the arithmetic that decides how fast
    /// a fan actually turns.
    static func targetRPM(percent: Double, min minRPM: Int, max maxRPM: Int) -> Int {
        let fraction = Swift.min(Swift.max(percent, 0), 100) / 100
        let span = Double(Swift.max(0, maxRPM - minRPM))
        return Int((Double(minRPM) + fraction * span).rounded())
    }

    /// Where the fans actually are, as a share of their ranges — not the last
    /// percentage typed. Read back from the targets themselves so that setting
    /// one fan by hand below moves this too, instead of leaving a slider that
    /// disagrees with the machine.
    var allFansPercent: Double {
        let fractions = telemetry.fans.compactMap { fan -> Double? in
            guard fan.maxRPM > fan.minRPM else { return nil }
            let rpm = manualRPM[fan.index] ?? fan.actualRPM
            return Double(rpm - fan.minRPM) / Double(fan.maxRPM - fan.minRPM)
        }
        guard !fractions.isEmpty else { return 0 }
        return min(max(fractions.reduce(0, +) / Double(fractions.count) * 100, 0), 100)
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
    @Environment(\.readoutInSidebar) private var readoutInSidebar

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SegmentedChoice(label: "Fans follow", selection: $feature.mode,
                            options: [("Firmware", "auto"),
                                      ("Temperature curve", "curve"),
                                      ("Fixed speed", "manual")])

            if feature.mode == "curve" {
                VStack(alignment: .leading, spacing: 6) {
                    // One row per fan, because they do not sit in the same
                    // place and should not chase the same number.
                    ForEach(telemetry.fans, id: \.index) { fan in
                        MenuChoice(label: telemetry.fans.count > 1
                                          ? "Fan \(fan.index + 1) follows" : "Follow",
                                   selection: Binding(
                                       get: { feature.curveSensor(fan: fan.index) },
                                       set: { feature.setCurveSensor($0, fan: fan.index) }),
                                   options: [("Whatever looks like the CPU", ""),
                                             ("The hottest sensor of the moment",
                                              FanCurve.hottestSensorKey)]
                                       + telemetry.temperatures.map {
                                           ("\($0.label) — \(Int($0.celsius)) °C", $0.key)
                                       })
                    }
                    ValueField(title: "Start lifting the fans at", range: 40...80, step: 1,
                               suffix: "°C", value: $feature.curveMin)
                    ValueField(title: "Reach full speed at", range: 60...100, step: 1,
                               suffix: "°C", value: $feature.curveMax)
                    Text("The curve interpolates between each fan's own minimum and maximum, so it fits whatever fans this machine has.")
                        .font(.caption).foregroundColor(.secondary)
                    Text(telemetry.fans.contains {
                            feature.curveSensor(fan: $0.index) == FanCurve.hottestSensorKey
                         }
                         ? "Following the highest of every sensor is the safest choice and the one that runs the fans most. It costs a few extra readings a second, nothing more."
                         : "The temperature is read by the part of Zephyr that runs as root, not handed to it: a control loop that stops when the app stops answering is one that leaves the fans pinned. A sensor that goes missing falls back to the CPU rather than switching the curve off.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if feature.mode == "manual" {
                SegmentedChoice(label: "Set speeds in",
                                selection: Binding(get: { feature.speedInRPM ? 1 : 0 },
                                                   set: { feature.speedInRPM = $0 == 1 }),
                                options: [("Percent", 0), ("RPM", 1)])
                if feature.speedInRPM { perFan } else { allFans }
            }

            // Only where there is no sidebar to carry it. In the sidebar
            // layouts the readings carry a THR line instead, which is where
            // anything the machine is *doing* rather than being told belongs.
            if !readoutInSidebar {
                Divider()
                ThrottleReadout(telemetry: telemetry)
            }
        }
    }

    /// One row per fan, in revolutions, each against its own range — which is
    /// the point of choosing this unit: the ranges differ, so a number that
    /// means one thing on one fan means another on the next.
    private var perFan: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(telemetry.fans, id: \.index) { fan in
                IntField(title: telemetry.fans.count > 1 ? "Fan \(fan.index + 1)" : "Fan",
                         range: fan.minRPM...max(fan.minRPM + 1, fan.maxRPM),
                         suffix: "rpm",
                         value: Binding(
                             get: { feature.manualRPM[fan.index] ?? fan.actualRPM },
                             set: { feature.setManual(fan: fan.index, rpm: $0) }))
            }
            Text("Each fan runs between the minimum and maximum its own firmware reports, and those differ. The firmware refuses anything below the minimum, so the slowest setting here is the slowest the fan can legally turn rather than a stop.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Both fans at once, in percent. The alternative above stays in revolutions,
    /// because a fan's own minimum and maximum are the only numbers that make
    /// a revolution count mean anything — and those differ per fan, which is
    /// exactly why the control that drives both of them at once is a share.
    private var allFans: some View {
        let percent = Binding(get: { feature.allFansPercent },
                              set: { feature.setAllFans(percent: $0) })
        return VStack(alignment: .leading, spacing: 8) {
            SegmentedChoice(label: "All fans",
                            selection: Binding(
                                get: { Int(percent.wrappedValue.rounded()) },
                                set: { feature.setAllFans(percent: Double($0)) }),
                            options: [("0%", 0), ("25%", 25), ("50%", 50),
                                      ("75%", 75), ("100%", 100)])
            ValueField(title: "All fans", range: 0...100, step: 1,
                       suffix: "%", value: percent)
            Text("0 % is each fan's own minimum rather than a stop: the firmware refuses a target below the minimum it reports, and a fan a settings window could stop would be the one control here able to cook the machine.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
