import AppKit
import CoreGraphics

/// Rules of the form "hold these, press that, get this".
///
/// The swaps in `KeyRemapper` go through hidutil, which is the right place for
/// them: the mapping lives below the window server, so it holds on the login
/// screen and inside password fields, and it can be told apart per keyboard.
/// What it cannot do is notice a modifier — hidutil maps one usage to another
/// and nothing else. That is the line Karabiner crosses, and this is the
/// smallest honest crossing of it.
///
/// The cost is stated rather than hidden: a rule here is global to every
/// keyboard, because a `CGEvent` does not say which one produced it, and it
/// stops working the moment this application does — including on the login
/// screen, where nothing of ours is running.
final class KeyInterceptor {

    /// The modifiers a rule requires, as the subset that must be held.
    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)

        var flags: CGEventFlags {
            var flags: CGEventFlags = []
            if contains(.command) { flags.insert(.maskCommand) }
            if contains(.option) { flags.insert(.maskAlternate) }
            if contains(.control) { flags.insert(.maskControl) }
            if contains(.shift) { flags.insert(.maskShift) }
            return flags
        }

        static func of(_ flags: CGEventFlags) -> Modifiers {
            var modifiers: Modifiers = []
            if flags.contains(.maskCommand) { modifiers.insert(.command) }
            if flags.contains(.maskAlternate) { modifiers.insert(.option) }
            if flags.contains(.maskControl) { modifiers.insert(.control) }
            if flags.contains(.maskShift) { modifiers.insert(.shift) }
            return modifiers
        }

        var label: String {
            var parts: [String] = []
            if contains(.control) { parts.append("⌃") }
            if contains(.option) { parts.append("⌥") }
            if contains(.shift) { parts.append("⇧") }
            if contains(.command) { parts.append("⌘") }
            return parts.joined()
        }
    }

    struct Rule: Codable, Equatable, Identifiable {
        var fromKey: Int
        var fromModifiers: Modifiers
        var toKey: Int
        var toModifiers: Modifiers
        var id: String { "\(fromKey)/\(fromModifiers.rawValue)" }
    }

    var rules: [Rule] = []

    /// Marks the events this posts, so the tap ignores what it produced
    /// itself. Without it a rule that swaps two keys feeds itself forever.
    private static let signature: Int64 = 0x5A455048   // "ZEPH"

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard !rules.isEmpty else { stop(); return false }
        guard tap == nil else { return true }

        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue)
                               | (1 << CGEventType.keyUp.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context = context else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(context)
                    .takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; putting it back is
        // the whole recovery, and without this the keyboard silently stops
        // obeying its rules until the app is restarted.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.signature else {
            return Unmanaged.passUnretained(event)
        }

        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let held = Modifiers.of(event.flags)
        guard let rewrite = Self.rewrite(rules: rules, key: key, held: held) else {
            return Unmanaged.passUnretained(event)
        }

        // Rewritten in place rather than posted anew: a posted event arrives
        // after the one it replaces has already been swallowed, which is what
        // makes rules feel late, and it loses the auto-repeat state.
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(rewrite.key))
        event.flags = rewrite.modifiers.flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.signature)
        return Unmanaged.passUnretained(event)
    }

    /// What a keystroke becomes, or nil if no rule claims it.
    ///
    /// Pure, and separate from the tap, because this is the part that can be
    /// wrong in a way no amount of pressing keys would reveal quickly — a rule
    /// that eats a modifier it should have passed on is invisible until the
    /// day it matters.
    static func rewrite(rules: [Rule], key: Int, held: Modifiers)
        -> (key: Int, modifiers: Modifiers)? {
        // Most specific first, so ⌃⌥C beats ⌃C rather than losing to whichever
        // the list happens to hold earlier.
        let claimed = rules
            .filter { $0.fromKey == key && held.isSuperset(of: $0.fromModifiers) }
            .max { $0.fromModifiers.rawValue.nonzeroBitCount
                 < $1.fromModifiers.rawValue.nonzeroBitCount }
        guard let rule = claimed else { return nil }
        // The modifiers the rule asked for, and none of the ones it consumed.
        let kept = held.subtracting(rule.fromModifiers).union(rule.toModifiers)
        return (rule.toKey, kept)
    }

    deinit { stop() }
}

extension KeyInterceptor {
    /// The keys a rule can name, by their virtual key code.
    ///
    /// Virtual codes rather than the HID usages the hidutil table uses: an
    /// event carries the virtual code, and converting between the two on every
    /// keystroke to reuse one list would be work done a hundred times a minute
    /// to save writing a second one.
    static let virtualKeys: [(name: String, code: Int)] = [
        ("Escape", 53), ("Tab", 48), ("Caps Lock", 57), ("Return", 36), ("Space", 49),
        ("Delete", 51), ("Forward Delete", 117),
        ("Left", 123), ("Right", 124), ("Down", 125), ("Up", 126),
        ("Home", 115), ("End", 119), ("Page Up", 116), ("Page Down", 121),
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5),
        ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45),
        ("O", 31), ("P", 35), ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32),
        ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6),
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23),
        ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29),
        ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97),
        ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111),
    ]
}
