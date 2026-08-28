import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Rewrites scroll events on their way to the app underneath.
///
/// The point of the exercise is that macOS has one scroll-direction switch for
/// every pointing device at once. Someone who wants "natural" on the trackpad
/// and the old direction on a wheel mouse cannot say so — the system offers no
/// way to express it. Intercepting the events is the only place the two can be
/// told apart.
///
/// Mouse and trackpad are separated by `scrollWheelEventIsContinuous`: a
/// trackpad and a Magic Mouse report a continuous pixel stream, a notched
/// wheel reports discrete lines. It is a property of the event rather than a
/// guess about the device, which is why it holds for hardware nobody tested.
final class ScrollInterceptor {
    struct Options {
        var reverseMouse = false
        var reverseTrackpad = false
        /// Strip the system's scroll acceleration from wheel scrolls, so a
        /// notch always travels the same distance however fast it is spun.
        var linear = false
        /// Lines per notch when `linear` is on.
        var linesPerNotch = 3
        /// A multiplier on the scroll distance, 1.0 being untouched.
        var scale: Double = 1.0
        /// Extra mouse buttons, by CGEvent button number.
        var buttons: [Int: ButtonAction] = [:]
        /// Overrides that apply only while a given application is in front.
        var appRules: [AppScrollRule] = []

        var wantsAnything: Bool {
            reverseMouse || reverseTrackpad || linear || scale != 1.0
                || buttons.values.contains { $0 != .passThrough }
                || appRules.contains { $0.changesAnything }
        }
    }

    /// The settings in force for a given application, or the plain ones when
    /// no rule claims it.
    ///
    /// Pure, and given its own name, because the mistake it guards against is
    /// a quiet one: a rule that sets only the speed must not also reset the
    /// direction to the built-in default the user never asked for.
    static func resolve(_ base: Options, forApp bundleID: String?) -> Options {
        guard let bundleID = bundleID,
              let rule = base.appRules.first(where: { $0.bundleID == bundleID })
        else { return base }
        var resolved = base
        if let reverse = rule.reverse {
            resolved.reverseMouse = reverse
            resolved.reverseTrackpad = reverse
        }
        if let linear = rule.linear { resolved.linear = linear }
        if let lines = rule.linesPerNotch { resolved.linesPerNotch = lines }
        if let scale = rule.scale { resolved.scale = scale }
        return resolved
    }

    var options = Options()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Which application the events are going to.
    ///
    /// Cached from a notification rather than asked per event: reading the
    /// frontmost application inside the tap would put a cross-process lookup
    /// on the path of every scroll notch, at a point where taking too long
    /// gets the tap switched off by the system.
    ///
    /// It is the active application, which is where scrolling goes unless a
    /// background window is scrolled without being clicked first. That case is
    /// rare enough to name honestly and leave alone; finding the window under
    /// the pointer would cost a window-list query per event.
    private var frontmostApp: String?
    private var activation: NSObjectProtocol?

    /// Whether the tap is live. False means the events are untouched — either
    /// nothing was asked for, or macOS refused us.
    var isRunning: Bool { tap != nil }

    /// Accessibility permission, which `CGEvent.tapCreate` needs to alter
    /// events rather than merely watch them. Checked rather than assumed: the
    /// call fails silently otherwise, and a scroll switch that does nothing
    /// with no explanation is worse than one that says it is not allowed yet.
    static var isPermitted: Bool {
        AXIsProcessTrusted()
    }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.isPermitted else { return false }

        let mask = CGEventMask(
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<ScrollInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        watchActivation()
        return true
    }

    private func watchActivation() {
        guard activation == nil else { return }
        frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.frontmostApp = app?.bundleIdentifier
        }
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let activation = activation {
            NSWorkspace.shared.notificationCenter.removeObserver(activation)
        }
        activation = nil
        tap = nil
        source = nil
    }

    deinit { stop() }

    // MARK: Rewriting

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long, and never re-enables it.
        // Without this the feature works until the machine is busy once, then
        // silently stops for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .scrollWheel:
            Self.rewrite(event, options: Self.resolve(options, forApp: frontmostApp))
            return Unmanaged.passUnretained(event)

        case .otherMouseDown, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard let action = options.buttons[button], action != .passThrough else {
                return Unmanaged.passUnretained(event)
            }
            // Swallowed in both directions. Letting the up through after
            // eating the down leaves apps with an unmatched release, which
            // some of them treat as a click they never saw begin.
            if type == .otherMouseDown { action.perform() }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// The transformation itself, separated from the tap so it can be checked
    /// against a constructed event without owning the input stream.
    static func rewrite(_ event: CGEvent, options: Options) {
        let isTrackpad = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        if isTrackpad ? options.reverseTrackpad : options.reverseMouse { invert(event) }
        if options.linear && !isTrackpad { flatten(event, linesPerNotch: options.linesPerNotch) }
        if options.scale != 1.0 { rescale(event, by: options.scale) }
    }

    /// Multiplies the distance travelled, leaving the direction alone.
    private static func rescale(_ event: CGEvent, by scale: Double) {
        for (line, point, fixed) in Self.axes {
            let lineDelta = event.getIntegerValueField(line)
            let pointDelta = event.getIntegerValueField(point)
            let fixedDelta = event.getDoubleValueField(fixed)
            event.setIntegerValueField(line, value: scaled(lineDelta, by: scale))
            event.setIntegerValueField(point, value: scaled(pointDelta, by: scale))
            event.setDoubleValueField(fixed, value: fixedDelta * scale)
        }
    }

    /// Scaling that cannot round a scroll away.
    ///
    /// A line delta is a whole number, so halving a one-line notch gives zero
    /// and the wheel stops working altogether — which is exactly what someone
    /// setting a slow speed would report as the feature being broken. A notch
    /// that happened keeps moving at least one line.
    static func scaled(_ delta: Int64, by scale: Double) -> Int64 {
        guard delta != 0 else { return 0 }
        let scaled = (Double(delta) * scale).rounded()
        if scaled == 0 { return delta > 0 ? 1 : -1 }
        return Int64(scaled)
    }

    /// Flips both axes. All three representations of the same delta have to
    /// move together — leaving one un-negated makes the scroll fight itself,
    /// because different apps read different fields.
    ///
    /// Every field is read before any is written. They are not independent:
    /// writing the line delta makes CoreGraphics recompute the point and
    /// fixed-point deltas from it, so negating them in sequence negates a
    /// value that has already changed underneath. Found by a check that
    /// constructed an event and looked at all three afterwards.
    private static func invert(_ event: CGEvent) {
        for (line, point, fixed) in Self.axes {
            let lineDelta = event.getIntegerValueField(line)
            let pointDelta = event.getIntegerValueField(point)
            let fixedDelta = event.getDoubleValueField(fixed)
            event.setIntegerValueField(line, value: -lineDelta)
            event.setIntegerValueField(point, value: -pointDelta)
            event.setDoubleValueField(fixed, value: -fixedDelta)
        }
    }

    /// Replaces the accelerated delta with a fixed step per notch. macOS scales
    /// a fast spin far beyond the notches actually turned, which is useful on a
    /// trackpad and unpredictable on a wheel.
    private static func flatten(_ event: CGEvent, linesPerNotch: Int) {
        for (line, point, fixed) in Self.axes {
            let delta = event.getIntegerValueField(line)
            guard delta != 0 else { continue }
            let step = Int64(linesPerNotch) * (delta < 0 ? -1 : 1)
            event.setIntegerValueField(line, value: step)
            event.setIntegerValueField(point, value: step * 10)
            event.setDoubleValueField(fixed, value: Double(step))
        }
    }

    private static let axes: [(CGEventField, CGEventField, CGEventField)] = [
        (.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1),
        (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2),
    ]
}
