import AppKit
import CoreGraphics
import Foundation

// Lives outside main.swift on purpose: globals declared there are initialised
// in source order as the top-level code runs, so a function called earlier
// than the declaration reads uninitialised memory and the process dies before
// printing anything. Everywhere else, globals are lazy.

/// Candidate fields by raw number: 87 is the one third-party tools read as a
/// sender id; the rest are printed so a correlation can be spotted rather than
/// assumed.
let scrollProbeFields: [(String, Int)] = [
    ("senderID(87)", 87), ("eventSourceUnixProcessID", 41),
    ("eventSourceUserData", 42), ("eventSourceStateID", 39),
    ("mouseEventNumber", 3), ("mouseEventButtonNumber", 4),
    ("scrollIsContinuous", 88),
]
var scrollProbeSeen = Set<String>()

/// Listens to real scroll and mouse-button events and dumps the fields that
/// might name the device. Needed because there is no documented way to ask a
/// CGEvent which mouse produced it, and per-device settings are worthless
/// without one. Requires Accessibility permission; runs read-only.
func runScrollTest() {
    guard ScrollInterceptor.isPermitted else {
        print("Accessibility permission is not granted — a tap cannot be created.")
        return
    }
    print("Move the pointer, scroll, and press any extra mouse buttons for 12 seconds…")

    let mask = CGEventMask(
        (1 << CGEventType.scrollWheel.rawValue) |
        (1 << CGEventType.otherMouseDown.rawValue) |
        (1 << CGEventType.leftMouseDown.rawValue) |
        (1 << CGEventType.rightMouseDown.rawValue))


    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: .listenOnly, eventsOfInterest: mask,
        callback: { _, type, event, _ in
            // A C function pointer cannot capture, so the state it needs is
            // file-scope rather than local.
            var parts: [String] = ["type=\(type.rawValue)"]
            for (name, raw) in scrollProbeFields {
                guard let field = CGEventField(rawValue: UInt32(raw)) else { continue }
                let value = event.getIntegerValueField(field)
                if value != 0 { parts.append("\(name)=\(value)") }
            }
            let line = parts.joined(separator: " ")
            if !scrollProbeSeen.contains(line) {
                scrollProbeSeen.insert(line)
                print("  " + line)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
    else {
        print("The tap could not be created even though permission is granted.")
        return
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    CFRunLoopRunInMode(.defaultMode, 12, false)
    print("done — \(scrollProbeSeen.count) distinct field combinations seen")
}
