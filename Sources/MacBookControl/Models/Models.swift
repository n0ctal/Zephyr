import Foundation

/// A single temperature sensor reading.
struct TemperatureReading: Identifiable, Hashable {
    let key: String          // SMC key, e.g. "TC0P"
    let label: String        // Human label, e.g. "CPU"
    let celsius: Double

    var id: String { key }
}

/// A single fan's current state.
struct FanReading: Identifiable, Hashable {
    let index: Int
    let actualRPM: Int
    let minRPM: Int
    let maxRPM: Int
    let targetRPM: Int
    let isManual: Bool

    var id: Int { index }

    /// Fraction of the way between min and max (0...1), clamped.
    var loadFraction: Double {
        guard maxRPM > minRPM else { return 0 }
        let f = Double(actualRPM - minRPM) / Double(maxRPM - minRPM)
        return min(max(f, 0), 1)
    }
}

/// A temperature → fan-speed curve (the standard "sensor-based" model used by
/// Macs Fan Control and similar tools): the fan runs at its minimum RPM at or
/// below `minTemp`, ramps **linearly** to its maximum RPM at `maxTemp`, and is
/// pinned to max above that. Driven by the CPU temperature.
///
/// Defaults (55 °C → 85 °C) reach full speed well before the ~100 °C throttle
/// point, keeping the machine cooler than the firmware's lazier default curve.
struct FanCurve: Equatable {
    var minTemp: Double
    var maxTemp: Double

    static let `default` = FanCurve(minTemp: 55, maxTemp: 85)

    /// Not an SMC key: the instruction "whichever sensor is hottest right
    /// now". Marked with a character no real key contains so it cannot
    /// collide with one.
    static let hottestSensorKey = "*hottest"

    /// Target RPM for a given CPU temperature, scaled into the fan's own range.
    func targetRPM(cpuTemp: Double, fanMin: Int, fanMax: Int) -> Int {
        guard maxTemp > minTemp else { return fanMax }
        let fraction = min(max((cpuTemp - minTemp) / (maxTemp - minTemp), 0), 1)
        return fanMin + Int((Double(fanMax - fanMin) * fraction).rounded())
    }
}

/// Curated, human-readable labels for common SMC temperature keys.
/// Unknown keys fall back to the raw key string.
enum SensorLabels {
    static let temperature: [String: String] = [
        // Beside the package, not on it, and the difference is not small:
        // measured here under a sustained build, TC0P held 54 °C while the
        // hottest core read 94. Calling it "CPU" invited exactly the reading
        // it cannot give.
        "TC0P": "CPU Proximity",
        "TC0E": "CPU (TC0E)",
        "TC0F": "CPU (TC0F)",
        "TCXC": "CPU PECI",
        "TCGC": "CPU GFX",
        "TCSA": "CPU System Agent",
        // Per-core, one key per physical core: this i9 has eight and publishes
        // TC1C through TC8C. A four-core machine simply has no TC5C, and an
        // unknown key already falls back to itself, so listing all eight costs
        // nothing there. TCMX tracked the hottest of them across repeated
        // samples (0.0–0.4 °C apart), which is what the name suggests.
        "TC1C": "CPU Core 1",
        "TC2C": "CPU Core 2",
        "TC3C": "CPU Core 3",
        "TC4C": "CPU Core 4",
        "TC5C": "CPU Core 5",
        "TC6C": "CPU Core 6",
        "TC7C": "CPU Core 7",
        "TC8C": "CPU Core 8",
        "TCMX": "CPU Hottest Core",
        "TG0P": "GPU",
        "TG1P": "GPU (TG1P)",
        "TGVP": "GPU VRAM",
        "TGDD": "GPU Die",
        "Tm0P": "Mainboard",
        "TM0P": "Memory",
        "TW0P": "Airport / Wi-Fi",
        "TA0P": "Ambient",
        "TA0V": "Ambient (TA0V)",
        "TB0T": "Battery 1",
        "TB1T": "Battery 2",
        "TB2T": "Battery 3",
        "TH0a": "SSD",
        "TH0b": "SSD (TH0b)",
        "TaLC": "Left Actuator",
        "TaRC": "Right Actuator",
        "TPCD": "PCH Die",
    ]

    static func label(for key: String) -> String {
        temperature[key] ?? key
    }
}

/// How hard the system says it is currently being held back thermally.
/// Mirrors `ProcessInfo.ThermalState`, but as a type this app owns so the
/// menu can name the levels in its own words.
enum ThermalPressure: String {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:  self = .nominal
        case .fair:     self = .fair
        case .serious:  self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var label: String {
        switch self {
        case .nominal:  return "normal"
        case .fair:     return "warm"
        case .serious:  return "throttling"
        case .critical: return "critical"
        }
    }
}

/// Firmware-imposed CPU limits. `speedLimitPercent` below 100 means the SMC is
/// actively capping clocks — the thing that makes a machine feel slow while
/// every temperature still looks survivable.
struct ThermalStatus {
    let speedLimitPercent: Int?
    let schedulerLimitPercent: Int?
    let availableCPUs: Int?
    let pressure: ThermalPressure

    /// True when the firmware is holding the CPU below its full speed.
    var isThrottling: Bool { (speedLimitPercent ?? 100) < 100 }
}

/// Where the watts are going, as the SMC reports them.
struct PowerDraw {
    let systemWatts: Double?
    let adapterWatts: Double?
    /// Positive while the battery is being charged, negative while it carries
    /// the machine. Near zero on a full battery sitting on the charger.
    let batteryWatts: Double?
}

/// Battery state as the menu shows it.
struct BatteryStatus {
    let percent: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    /// Full-charge capacity as a share of the design capacity, when readable.
    let healthPercent: Int?
    let cycleCount: Int?
    /// The two capacities behind `healthPercent`, in mAh — what the battery
    /// holds now and what it was built to hold. A percentage says how far it
    /// has fallen; these say how much charge is actually left to work with,
    /// which is the number coconutBattery is opened for.
    ///
    /// These three carry defaults so that the fixtures which build a battery
    /// to test the drawing need not name them. That is the only reason they
    /// are `var`: nothing mutates a reading.
    var fullChargeCapacity: Int?
    var designCapacity: Int?
    /// Battery temperature. A cell that runs warm ages faster than one that
    /// does not, and this is the only place on the machine that reports it.
    var celsius: Double?
    let power: PowerDraw?
    /// Minutes until empty, when the system is willing to estimate. It answers
    /// 65535 — "do not know" — whenever the machine is on the charger or the
    /// reading has not settled, and that is reported as nil rather than as a
    /// wildly wrong number.
    let minutesRemaining: Int?

    var stateLabel: String {
        if isCharging { return "charging" }
        return isPluggedIn ? "on charger" : "on battery"
    }
}

/// What the throttling monitor has seen since the app started.
///
/// A single reading only answers "is it capped right now". The interesting
/// question on a laptop is whether it *has been* capped while you were doing
/// something else, so the lowest cap and the time spent below full speed are
/// accumulated here.
struct ThermalStats {
    private(set) var lowestSpeedLimit = 100
    private(set) var samples = 0

    /// Kept fractional. The window can be polled twice a second, and rounding
    /// each increment to a whole number made every one of them zero — the
    /// panel then said the machine had been held back, for 0 s.
    private var throttledAccumulated: TimeInterval = 0
    var throttledSeconds: Int { Int(throttledAccumulated.rounded()) }

    /// When the last sample was taken, so a sample can be credited with the
    /// time it actually stands for rather than with the time it was supposed
    /// to stand for.
    private var lastRecordedAt: Date?

    /// `now` is a parameter so the arithmetic can be checked against a clock
    /// that does not move on its own.
    /// `longestGap` is how far apart two readings can legitimately fall. It
    /// defaults to the interval, but every repeating timer here is given slack
    /// as a fraction of its period, so the real answer is larger — and capping
    /// at the bare interval threw away that fraction of every gap, which is a
    /// systematic undercount of the figure this type exists to keep honest.
    mutating func record(_ status: ThermalStatus, interval: TimeInterval,
                         longestGap: TimeInterval? = nil, at now: Date = Date()) {
        samples += 1
        // Ticks arrive on the interval, but a window opening reads out of turn
        // — and crediting every reading with a whole interval let a few
        // seconds of opening and closing a window claim minutes of "held back
        // for". Capped at the interval the other way round, so the first
        // sample after a night asleep does not claim the night.
        let elapsed = lastRecordedAt.map { now.timeIntervalSince($0) } ?? interval
        lastRecordedAt = now
        guard let limit = status.speedLimitPercent else { return }
        lowestSpeedLimit = min(lowestSpeedLimit, limit)
        if limit < 100 { throttledAccumulated += min(max(elapsed, 0), longestGap ?? interval) }
    }

    var everThrottled: Bool { lowestSpeedLimit < 100 }

    var throttledLabel: String {
        if throttledSeconds < 60 { return "\(throttledSeconds) s" }
        return "\(throttledSeconds / 60) min"
    }
}
