import AppKit
import CoreWLAN
import Foundation

/// A set of settings plus the circumstances that should bring them on.
///
/// This is the reason for merging ten utilities into one process. No fan tool
/// can know an external display is attached; no battery tool can know Xcode is
/// running. "On mains, docked, compiling — discrete GPU, fans harder, do not
/// sleep" is a sentence none of them can say alone.
struct Profile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var isEnabled = true
    /// All conditions must hold, or any one of them. Two knobs would be more
    /// expressive and much harder to reason about; this covers what people
    /// actually write.
    var requiresAll = true
    var conditions: [Condition] = []
    var actions: [Action] = []
}

/// Circumstances Zephyr can actually observe. Deliberately a closed list: a
/// condition that cannot be evaluated honestly is worse than one that is
/// missing, because a profile that silently never matches looks like a bug.
enum Condition: Codable, Equatable, Hashable {
    case onExternalPower(Bool)
    case batteryBelow(Int)
    case externalDisplayAttached(Bool)
    case appRunning(String)
    case wifiNetwork(String)
    case timeBetween(startMinutes: Int, endMinutes: Int)
    case cpuHotterThan(Double)
    case cpuLoadAbove(Double)

    /// What deciding this condition costs. An exhaustive switch on purpose:
    /// adding a condition that samples something new must not compile until
    /// somebody has said what it samples, or the rule silently evaluates
    /// against a reading that stopped arriving when the window closed.
    var telemetryNeeds: Telemetry.Needs {
        var needs = Telemetry.Needs()
        switch self {
        case .onExternalPower, .appRunning, .wifiNetwork, .timeBetween:
            break   // none of these come from a reading
        case .externalDisplayAttached:
            break   // counted from CoreGraphics, not from telemetry
        case .batteryBelow:
            needs.battery = true
        case .cpuLoadAbove:
            // Heat lags the work by a minute or more, so a rule meant for
            // "while it is busy" cannot be written as a temperature and have
            // the fans arrive on time.
            needs.load = true
        case .cpuHotterThan:
            // The CPU sensor by name, not whichever one the menu bar happens
            // to show: a rule about the CPU being hot must not be decided by
            // an ambient sensor because that is what the status item is set to.
            needs.cpuSensor = true
        }
        return needs
    }

    var label: String {
        switch self {
        case .onExternalPower(let on): return on ? "On mains power" : "On battery"
        case .batteryBelow(let percent): return "Battery below \(percent) %"
        case .externalDisplayAttached(let on): return on ? "An external display is attached" : "No external display"
        case .appRunning(let name): return "\(name) is running"
        case .wifiNetwork(let ssid): return "Wi-Fi network is \(ssid)"
        case .timeBetween(let start, let end): return "Between \(Self.clock(start)) and \(Self.clock(end))"
        case .cpuHotterThan(let celsius): return String(format: "CPU above %.0f °C", celsius)
        case .cpuLoadAbove(let percent): return String(format: "CPU load above %.0f %%", percent)
        }
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

/// What a profile does when it takes hold. Each case is optional per profile:
/// a profile only touches what it lists, so two profiles can own different
/// halves of the machine without fighting.
enum Action: Codable, Equatable, Hashable {
    case coolingMode(String)
    case fanCurve(min: Double, max: Double)
    case turboDisabled(Bool)
    case gpuMode(Int)
    case chargeLimit(Int)
    case keepAwake(Bool)
    case pointerAcceleration(Double)

    var label: String {
        switch self {
        case .coolingMode(let mode): return "Fans follow \(mode)"
        case .fanCurve(let min, let max): return String(format: "Curve %.0f–%.0f °C", min, max)
        case .turboDisabled(let off): return off ? "Turbo Boost off" : "Turbo Boost on"
        case .gpuMode(let raw): return "Graphics: \(GPUMode(rawValue: raw)?.label ?? "?")"
        case .chargeLimit(let percent): return "Stop charging at \(percent) %"
        case .keepAwake(let on): return on ? "Keep awake" : "Allow sleep"
        case .pointerAcceleration(let value):
            return value == 0 ? "No pointer acceleration" : String(format: "Pointer acceleration %.2f", value)
        }
    }
}

/// Everything the conditions are judged against, sampled once per evaluation.
///
/// Gathered up front rather than queried per condition: two conditions asking
/// the same question a moment apart could disagree, and a profile that flickers
/// because of that is far harder to explain than one that is simply wrong.
struct Context {
    let onExternalPower: Bool
    let batteryPercent: Int?
    let externalDisplayCount: Int
    let runningApps: [String]
    let wifiSSID: String?
    let minutesSinceMidnight: Int
    let cpuCelsius: Double?
    /// Overall CPU busy fraction as a percentage, 0...100.
    let cpuLoadPercent: Double?

    static func sample(telemetry: Telemetry) -> Context {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Context(
            onExternalPower: SleepInhibitor.isOnExternalPower,
            batteryPercent: telemetry.battery?.percent,
            // The built-in panel is always one of them, so "external" means
            // more than one — not "any".
            externalDisplayCount: max(0, NSScreen.screens.count - 1),
            runningApps: NSWorkspace.shared.runningApplications.compactMap { $0.localizedName },
            wifiSSID: CWWiFiClient.shared().interface()?.ssid(),
            minutesSinceMidnight: (now.hour ?? 0) * 60 + (now.minute ?? 0),
            cpuCelsius: telemetry.cpuTemperature?.celsius,
            // The busy fraction the load reading already carries, as a
            // percentage so the rule reads the way the number is spoken.
            cpuLoadPercent: telemetry.load.map { $0.total * 100 }
        )
    }
}

extension Condition {
    /// Unknown answers read as false. A profile that fires because something
    /// could not be measured is worse than one that stays quiet.
    func holds(in context: Context) -> Bool {
        switch self {
        case .onExternalPower(let wanted):
            return context.onExternalPower == wanted
        case .batteryBelow(let threshold):
            guard let percent = context.batteryPercent else { return false }
            return percent < threshold
        case .externalDisplayAttached(let wanted):
            return (context.externalDisplayCount > 0) == wanted
        case .appRunning(let name):
            let needle = name.lowercased()
            return context.runningApps.contains { $0.lowercased().contains(needle) }
        case .wifiNetwork(let ssid):
            guard let current = context.wifiSSID else { return false }
            return current.caseInsensitiveCompare(ssid) == .orderedSame
        case .timeBetween(let start, let end):
            let now = context.minutesSinceMidnight
            // A window that wraps past midnight is the normal case for
            // "at night", so it is handled rather than treated as invalid.
            return start <= end ? (now >= start && now < end) : (now >= start || now < end)
        case .cpuHotterThan(let celsius):
            guard let current = context.cpuCelsius else { return false }
            return current > celsius
        case .cpuLoadAbove(let percent):
            guard let current = context.cpuLoadPercent else { return false }
            return current > percent
        }
    }
}

extension Profile {
    /// Which profile takes over. The first match wins, because order in the
    /// list is how "specific above general" is expressed without asking anyone
    /// to maintain priority numbers. Shared with the engine so a check of this
    /// is a check of what actually runs.
    static func firstMatching(_ profiles: [Profile], in context: Context) -> Profile? {
        profiles.first { $0.matches(context) }
    }

    func matches(_ context: Context) -> Bool {
        guard isEnabled, !conditions.isEmpty else { return false }
        return requiresAll
            ? conditions.allSatisfy { $0.holds(in: context) }
            : conditions.contains { $0.holds(in: context) }
    }
}
