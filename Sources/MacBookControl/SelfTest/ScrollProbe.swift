import AppKit
import CoreGraphics
import Foundation

// Lives outside main.swift on purpose: globals declared there are initialised
// in source order as the top-level code runs, so a function called earlier
// than the declaration reads uninitialised memory and the process dies before
// printing anything. Everywhere else, globals are lazy.

/// One observed event: every field it carried that was not zero.
struct ScrollSample {
    let type: UInt32
    let isContinuous: Bool
    let fields: [Int: Int64]
}
var scrollSamples: [ScrollSample] = []

/// Fields that say nothing about the device and would drown the comparison:
/// coordinates, timestamps, the deltas themselves.
let scrollProbeIgnored: Set<Int> = [
    // Location, delta and timing move on every single event.
    1, 2, 3, 5, 6, 7, 8, 11, 12, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
    31, 32, 33, 34, 35, 36, 37, 38, 40, 43, 44, 45, 46, 47, 48, 49, 50, 51,
    52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69,
    70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86,
    93, 94, 95, 96, 97, 98, 99,
]

/// Listens to real scroll and button events and records every field each one
/// carried, then reports which fields could tell one pointing device from
/// another.
///
/// The question this exists to settle: there is no documented way to ask a
/// CGEvent which mouse produced it, and per-device scroll settings are
/// worthless without one. Guessing a field and checking it proves nothing —
/// a field that happens to differ between a trackpad and a mouse may just be
/// describing continuous versus notched scrolling. So everything is recorded
/// and compared, and the answer is whatever survives.
///
/// Requires Accessibility permission; runs read-only, altering nothing.
func runScrollTest() {
    guard ScrollInterceptor.isPermitted else {
        print("Accessibility permission is not granted — a tap cannot be created.")
        return
    }
    let seconds = CommandLine.arguments
        .first { $0.hasPrefix("--seconds=") }
        .flatMap { Double($0.dropFirst("--seconds=".count)) } ?? 12

    print("""
    Watching for \(Int(seconds)) seconds. Please, in this order:
      1. scroll with the MOUSE wheel, a few notches each way
      2. scroll on the TRACKPAD, up and down
      3. press every extra button on the mouse
    """)

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
            var fields: [Int: Int64] = [:]
            for raw in 0...99 where !scrollProbeIgnored.contains(raw) {
                guard let field = CGEventField(rawValue: UInt32(raw)) else { continue }
                let value = event.getIntegerValueField(field)
                if value != 0 { fields[raw] = value }
            }
            scrollSamples.append(ScrollSample(
                type: type.rawValue,
                isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                fields: fields))
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
    else {
        print("The tap could not be created even though permission is granted.")
        return
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    CFRunLoopRunInMode(.defaultMode, seconds, false)
    CGEvent.tapEnable(tap: tap, enable: false)

    reportScrollSamples()
}

private func reportScrollSamples() {
    let scrolls = scrollSamples.filter { $0.type == CGEventType.scrollWheel.rawValue }
    let wheel = scrolls.filter { !$0.isContinuous }
    let pad = scrolls.filter { $0.isContinuous }
    // What the interceptor would do with the same field: the mapping from
    // sender to device is the whole basis of per-device settings, so seeing it
    // resolve here is seeing it resolve there.
    var senders = Set<Int64>()
    for sample in scrollSamples { if let s = sample.fields[87] { senders.insert(s) } }
    if !senders.isEmpty {
        print("\nsenders seen, and the device each resolves to:")
        for sender in senders.sorted() {
            let unsigned = UInt64(bitPattern: sender)
            _ = PointerSenders.identity(forSender: unsigned)      // starts the lookup
            Thread.sleep(forTimeInterval: 0.4)                    // it runs off-thread
            let identity = PointerSenders.identity(forSender: unsigned) ?? "—"
            print(String(format: "  0x%llX  ->  %@", unsigned,
                         identity.isEmpty ? "not identifiable" : identity))
        }
    }

    print("\nSaw \(scrollSamples.count) events: \(wheel.count) wheel scrolls, "
          + "\(pad.count) trackpad scrolls, "
          + "\(scrollSamples.count - scrolls.count) button presses.")
    guard !wheel.isEmpty, !pad.isEmpty else {
        print("Need both a wheel scroll and a trackpad scroll to compare. "
              + "Run again and use both.")
        return
    }

    func values(_ samples: [ScrollSample], _ field: Int) -> Set<Int64> {
        Set(samples.compactMap { $0.fields[field] })
    }
    let everyField = Set(scrolls.flatMap { $0.fields.keys }).sorted()

    print("\nfield  wheel                          trackpad")
    print(String(repeating: "-", count: 72))
    for field in everyField {
        let a = values(wheel, field), b = values(pad, field)
        let mark = a.isDisjoint(with: b) && !a.isEmpty && !b.isEmpty ? "  <- differs" : ""
        print(String(format: "%5d  %-30s %@%@", field,
                     (describe(a) as NSString).utf8String!, describe(b), mark))
    }

    // A field that merely separates continuous from notched scrolling is not
    // a device identifier — it is a description of the scroll. The only way
    // to tell the two apart is whether the field also holds still across
    // every event from the same device, which a delta or a timestamp does not.
    print("""

    A field marked "differs" is only a candidate. To be a device identifier it
    must also be CONSTANT within each column — one value per device, not one
    per event. A field with many values on each side is describing the scroll,
    not the mouse.
    """)
}

private func describe(_ set: Set<Int64>) -> String {
    let sorted = set.sorted()
    if sorted.count > 4 {
        return "\(sorted.count) values \(sorted.first!)…\(sorted.last!)"
    }
    return sorted.map(String.init).joined(separator: ", ")
}
