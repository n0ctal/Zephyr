import CoreGraphics
import Foundation

/// What an extra mouse button should do instead of what it does.
///
/// Every action is expressed as a keystroke, because that is what macOS
/// actually listens for: switching desktops is Control-Arrow, Mission Control
/// is Control-Up, moving between browser tabs is Control-Tab. Naming them
/// rather than making people look up key codes is the whole value, and a
/// custom keystroke is there for everything not on the list.
enum ButtonAction: Codable, Equatable, Hashable {
    /// Not called `none`: that name collides with `Optional.none`, and SwiftUI
    /// then fails to match a picker's selection against its tags — the list
    /// renders with every label blank and no selection at all. Found by
    /// looking at the tab rather than by reasoning about it.
    case passThrough
    case desktopLeft
    case desktopRight
    case missionControl
    case appWindows
    case browserBack
    case browserForward
    case tabPrevious
    case tabNext
    case custom(keyCode: Int, modifiers: UInt64)

    var label: String {
        switch self {
        case .passThrough: return "Leave it alone"
        case .desktopLeft: return "Previous desktop"
        case .desktopRight: return "Next desktop"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App windows"
        case .browserBack: return "Back"
        case .browserForward: return "Forward"
        case .tabPrevious: return "Previous tab"
        case .tabNext: return "Next tab"
        case .custom: return "Custom keystroke"
        }
    }

    /// The keystroke to post, or nil to let the button through untouched.
    var keystroke: (keyCode: CGKeyCode, flags: CGEventFlags)? {
        switch self {
        case .passThrough: return nil
        case .desktopLeft: return (0x7B, .maskControl)          // Control-Left
        case .desktopRight: return (0x7C, .maskControl)         // Control-Right
        case .missionControl: return (0x7E, .maskControl)       // Control-Up
        case .appWindows: return (0x7D, .maskControl)           // Control-Down
        case .browserBack: return (0x21, .maskCommand)          // Command-[
        case .browserForward: return (0x1E, .maskCommand)       // Command-]
        case .tabPrevious: return (0x30, [.maskControl, .maskShift])   // Control-Shift-Tab
        case .tabNext: return (0x30, .maskControl)              // Control-Tab
        case .custom(let keyCode, let modifiers):
            return (CGKeyCode(keyCode), CGEventFlags(rawValue: modifiers))
        }
    }

    static let selectable: [ButtonAction] = [
        .passThrough, .desktopLeft, .desktopRight, .missionControl, .appWindows,
        .browserBack, .browserForward, .tabPrevious, .tabNext,
    ]

    /// Posts the keystroke. Down and up as a pair — a key that is never
    /// released leaves the modifier stuck for every app that reads it.
    func perform() {
        guard let stroke = keystroke,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: false)
        else { return }
        down.flags = stroke.flags
        up.flags = stroke.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// Everything one pointing device is set to do.
///
/// Per device rather than one global set, because two mice are two different
/// opinions about how a mouse should behave — the side buttons that switch
/// desktops on one may want to switch browser tabs on the other.
struct PointerProfile: Codable, Equatable {
    var reverseScroll = false
    /// A fixed distance per notch instead of the system's acceleration.
    var linearScroll = false
    var linesPerNotch = 3
    var flattenAcceleration = false
    /// 1.0 is the curve the device shipped with; 0 is none at all.
    var accelerationMultiplier = 0.0
    /// Keyed by CGEvent button number. 2 is the middle button; the side
    /// buttons on a typical mouse are 3 and 4.
    var buttons: [Int: ButtonAction] = [:]

    /// Buttons worth offering. One and two are the primary and secondary
    /// click, and rebinding those is how a mouse becomes unusable.
    static let bindableButtons = [2, 3, 4, 5, 6, 7]

    static func buttonName(_ number: Int) -> String {
        switch number {
        case 2: return "Middle button"
        case 3: return "Side button 1"
        case 4: return "Side button 2"
        default: return "Button \(number + 1)"
        }
    }
}
