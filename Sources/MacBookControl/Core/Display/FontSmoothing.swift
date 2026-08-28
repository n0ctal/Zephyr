import Foundation

/// The stroke thickening macOS applies to text, which System Settings stopped
/// exposing in Big Sur.
///
/// Apple removed subpixel antialiasing in Mojave; what is left under this name
/// fattens glyph strokes a little. On a Retina panel the difference is barely
/// there. On an external monitor at ordinary pixel density it is the
/// difference between text that looks slightly blurred and bold and text that
/// looks crisp, which is why people go looking for the setting and find only
/// a `defaults` command.
///
/// Stored per host, under the global domain — the same place
/// `defaults -currentHost write -g AppleFontSmoothing` writes to. No
/// privileges are involved: it is the user's own preference.
enum FontSmoothing {
    /// What the level means. The numbers are Apple's and their exact effect is
    /// undocumented; only 0 has a stated meaning, which is off.
    enum Level: Int, CaseIterable {
        case off = 0, light = 1, medium = 2, strong = 3

        var label: String {
            switch self {
            case .off: return "Off — thinnest text"
            case .light: return "Light"
            case .medium: return "Medium"
            case .strong: return "Strong"
            }
        }
    }

    private static let key = "AppleFontSmoothing" as CFString

    /// The level in force, or nil when nothing is set and macOS uses its own.
    static var current: Level? {
        guard let value = CFPreferencesCopyValue(
            key, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
        else { return nil }
        return Level(rawValue: value)
    }

    /// Writes a level, or removes the setting so macOS decides again.
    @discardableResult
    static func set(_ level: Level?) -> Bool {
        // Written before the change so a level chosen twice does not record
        // our own value as the thing to put back.
        if Preferences.fontSmoothingOriginal == nil {
            // Nothing there is itself a state worth restoring to, and it is
            // the common one — so it needs a value of its own rather than nil,
            // which already means "we have not touched this".
            Preferences.fontSmoothingOriginal = current?.rawValue ?? absent
        }
        CFPreferencesSetValue(key, level.map { $0.rawValue as CFNumber },
                              kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    }

    /// Puts back whatever was there before this application first wrote.
    static func restore() {
        guard let original = Preferences.fontSmoothingOriginal else { return }
        CFPreferencesSetValue(key,
                              original == absent ? nil : (original as CFNumber),
                              kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        Preferences.fontSmoothingOriginal = nil
    }

    static var hasUnrestored: Bool { Preferences.fontSmoothingOriginal != nil }

    /// Stands in for "the key was not set". Any value outside 0...3 would do;
    /// this one cannot be confused with a level.
    static let absent = -1
}
