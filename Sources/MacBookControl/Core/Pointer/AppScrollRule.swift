import AppKit

/// A per-application override of the scroll settings.
///
/// The case it exists for is the one every mouse utility gets asked about: a
/// wheel that should move three lines in a text editor and a whole page in a
/// document viewer, or a design tool where the inverted direction is the only
/// one that feels right. macOS has one scroll setting for the whole session,
/// so an override has to be applied where the events pass.
///
/// Every field is optional, and nil means "whatever the device already says".
/// A rule that only changes the speed leaves direction alone rather than
/// quietly re-asserting a default the user never chose.
struct AppScrollRule: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var reverse: Bool?
    var linear: Bool?
    var linesPerNotch: Int?
    /// A multiplier on the distance, 1.0 being untouched.
    var scale: Double?
    /// Whether the wheel glides here. The reason this is per application is
    /// that smoothing is wrong in a few of them — anything that maps a scroll
    /// to a zoom step, or draws its own inertia — and being able to say so is
    /// the difference between using the feature and turning it off.
    var smooth: Bool?

    var id: String { bundleID }

    var changesAnything: Bool {
        reverse != nil || linear != nil || linesPerNotch != nil || smooth != nil
            || (scale.map { $0 != 1.0 } ?? false)
    }

    /// A one-line account of what the rule does, for the row that lists it.
    var summary: String {
        var parts: [String] = []
        if let reverse = reverse { parts.append(reverse ? "reversed" : "normal direction") }
        if let scale = scale, scale != 1.0 { parts.append(String(format: "%.2g× speed", scale)) }
        if let smooth = smooth { parts.append(smooth ? "smoothed" : "not smoothed") }
        if let linear = linear, linear { parts.append("fixed step") }
        if let lines = linesPerNotch, linear == true { parts.append("\(lines) lines") }
        return parts.isEmpty ? "no change" : parts.joined(separator: ", ")
    }
}

/// The applications worth offering in the picker: the ones with a menu bar and
/// a bundle identifier, which is everything a scroll rule could apply to.
enum RunnableApps {
    static func running() -> [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                return (name, id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Installed applications, for choosing one that is not running. Read from
    /// the folders rather than Launch Services, which needs a query object and
    /// a run loop turn to answer.
    static func installed() -> [(name: String, bundleID: String)] {
        let folders = ["/Applications", "/System/Applications",
                       NSHomeDirectory() + "/Applications"]
        var found: [String: String] = [:]
        for folder in folders {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for entry in contents where entry.hasSuffix(".app") {
                let path = folder + "/" + entry
                guard let bundle = Bundle(path: path),
                      let id = bundle.bundleIdentifier else { continue }
                found[id] = String(entry.dropLast(4))
            }
        }
        return found.map { (name: $0.value, bundleID: $0.key) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
