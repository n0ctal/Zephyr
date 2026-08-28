import CoreGraphics
import Foundation

/// Exercises the shipping type rather than a sketch of it.
///
/// The part worth proving is not that a virtual display can be made — that is
/// one call — but that letting the object go removes it. If it did not, every
/// run would leave another screen behind and only a reboot would clear them.
func runVirtualDisplayTest() {
    func online() -> Int {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        return Int(count)
    }

    guard VirtualDisplay.isAvailable else {
        print("CGVirtualDisplay is not present on this macOS.")
        return
    }
    let before = online()
    print("displays before: \(before)")

    // The pool matters, and finding out why cost a wrong answer once: the
    // framework hands these objects back autoreleased, so the last release
    // does not happen when the variable is cleared but when the pool drains.
    // An application drains one every turn of the run loop; a probe that runs
    // to the end of a function without one never releases at all, and reports
    // that the display cannot be removed.
    autoreleasepool {
        var display: VirtualDisplay? = VirtualDisplay(
            .init(name: "Zephyr test", width: 1920, height: 1080,
                  refreshRate: 60, hiDPI: false))
        guard let made = display else { print("could not create one"); return }
        print("created, display id \(made.displayID.map(String.init) ?? "—")")

        // The window server takes a moment to publish it.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let during = online()
        print("displays with it up: \(during)  \(during == before + 1 ? "OK" : "NOT COUNTED")")
        display = nil
    }
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    let after = online()
    print("displays after release: \(after)  \(after == before ? "OK — it went away" : "STILL THERE")")
}
