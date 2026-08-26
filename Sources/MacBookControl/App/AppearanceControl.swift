import AppKit

/// Light, dark, or whatever the Mac is set to.
///
/// Applied to the application rather than to one window, so a preference means
/// the same thing everywhere — including the alerts, which are not ours to
/// style individually.
///
/// Deliberately does not touch the menu-bar readout. That is drawn against the
/// menu bar's own appearance, which on macOS is not always the window's: a Mac
/// in light mode can still have a dark menu bar, and a status item painted for
/// the wrong one is invisible.
enum AppearanceControl {
    static func apply() {
        switch Preferences.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        // Darkness is dark as far as the system is concerned — the difference
        // is in our own palettes, which go to black rather than to the grey
        // macOS uses. The system controls have to keep drawing themselves for
        // a dark window either way.
        case "dark", "darkness": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil   // follow the system
        }
    }

    /// True when the pitch-black palette is chosen.
    static var isPitchBlack: Bool { Preferences.appearance == "darkness" }

    /// Whether the window is dark, asked of the setting rather than of
    /// SwiftUI's `colorScheme`.
    ///
    /// The environment value is not reliable everywhere the palettes are
    /// needed — an offscreen host has no window to take an appearance from and
    /// reports the system's, which is how a render meant to show the light
    /// theme came out entirely black. The setting is the thing that was
    /// actually chosen, so it is the thing to ask.
    static var isDark: Bool {
        switch Preferences.appearance {
        case "light": return false
        case "dark", "darkness": return true
        default:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
}
