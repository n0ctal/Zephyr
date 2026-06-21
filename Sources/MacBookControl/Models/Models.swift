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
        "TC0P": "CPU",
        "TC0E": "CPU (TC0E)",
        "TC0F": "CPU (TC0F)",
        "TCXC": "CPU PECI",
        "TCGC": "CPU GFX",
        "TCSA": "CPU System Agent",
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
