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
        /// Extra mouse buttons, by CGEvent button number.
        var buttons: [Int: ButtonAction] = [:]

        var wantsAnything: Bool {
            reverseMouse || reverseTrackpad || linear
                || buttons.values.contains { $0 != .passThrough }
        }
    }

    var options = Options()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

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
        return true
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
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
            Self.rewrite(event, options: options)
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
