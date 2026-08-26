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
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil   // follow the system
        }
    }
}
