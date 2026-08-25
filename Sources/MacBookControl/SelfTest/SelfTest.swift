import AppKit
import CoreGraphics
import Foundation

/// Regression checks that run without Xcode.
///
/// XCTest ships with Xcode, not with the Command Line Tools this project
/// builds under, so the usual test target cannot even compile here. These are
/// the same assertions in a form `swift build` can produce: `--self-test`
/// runs them and exits non-zero on the first failure, which is what a CI step
/// or a pre-commit check needs from a test suite.
enum SelfTest {
    private static var failures: [String] = []
    private static var checks = 0

    private static func expect(_ condition: Bool, _ what: String,
                               file: StaticString = #file, line: UInt = #line) {
        checks += 1
        guard !condition else { return }
        failures.append("\(what)  (\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line))")
    }

    private static func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ what: String,
                                                  file: StaticString = #file, line: UInt = #line) {
        checks += 1
        guard lhs != rhs else { return }
        failures.append("\(what): expected \(rhs), got \(lhs)  (\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line))")
    }

    static func run() -> Int32 {
        failures = []
        checks = 0
        profileConditions()
        profileMatching()
        profileEncoding()
        powerLimitPacking()
        keyMappingWireFormat()
        sliderTickBudget()
        fanCurve()
        scrollRewriting()
        menuBarDrawing()
        batteryColours()

        if failures.isEmpty {
            print("self-test: \(checks) checks passed")
            return 0
        }
        print("self-test: \(failures.count) of \(checks) checks FAILED")
        failures.forEach { print("  \($0)") }
        return 1
    }

    private static func context(
        power: Bool = true, battery: Int? = 50, displays: Int = 0,
        apps: [String] = [], wifi: String? = nil, minutes: Int = 12 * 60,
        cpu: Double? = 50
    ) -> Context {
        Context(onExternalPower: power, batteryPercent: battery,
                externalDisplayCount: displays, runningApps: apps,
                wifiSSID: wifi, minutesSinceMidnight: minutes, cpuCelsius: cpu)
    }

    // MARK: Conditions

    private static func profileConditions() {
        let workday = Condition.timeBetween(startMinutes: 9 * 60, endMinutes: 17 * 60)
        expect(workday.holds(in: context(minutes: 12 * 60)), "midday is inside 09:00–17:00")
        expect(!workday.holds(in: context(minutes: 8 * 60)), "08:00 is outside 09:00–17:00")
        expect(workday.holds(in: context(minutes: 9 * 60)), "the start of a window is included")
        expect(!workday.holds(in: context(minutes: 17 * 60)), "the end of a window is not")

        // "At night" is the ordinary case and it wraps past midnight. A naive
        // start <= now < end would make this window match nothing at all.
        let night = Condition.timeBetween(startMinutes: 22 * 60, endMinutes: 8 * 60)
        expect(night.holds(in: context(minutes: 23 * 60)), "23:00 is inside a window that wraps")
        expect(night.holds(in: context(minutes: 2 * 60)), "02:00 is inside a window that wraps")
        expect(!night.holds(in: context(minutes: 12 * 60)), "midday is outside a night window")

        // A profile firing because something could not be measured is worse
        // than one that stays quiet, so every unknown reads as false.
        expect(!Condition.batteryBelow(30).holds(in: context(battery: nil)), "unknown battery does not satisfy")
        expect(!Condition.cpuHotterThan(50).holds(in: context(cpu: nil)), "unknown temperature does not satisfy")
        expect(!Condition.wifiNetwork("home").holds(in: context(wifi: nil)), "unknown network does not satisfy")

        expect(Condition.batteryBelow(30).holds(in: context(battery: 29)), "29 is below 30")
        expect(!Condition.batteryBelow(30).holds(in: context(battery: 30)), "30 is not below 30")

        expect(Condition.externalDisplayAttached(true).holds(in: context(displays: 1)), "one extra screen counts as external")
        expect(Condition.externalDisplayAttached(false).holds(in: context(displays: 0)), "no extra screen counts as none")

        let running = context(apps: ["Xcode", "Finder"])
        expect(Condition.appRunning("xcode").holds(in: running), "app match ignores case")
        expect(Condition.appRunning("Find").holds(in: running), "app match is a substring")
        expect(!Condition.appRunning("Safari").holds(in: running), "an app that is not running does not match")

        expect(Condition.wifiNetwork("Home").holds(in: context(wifi: "HOME")), "SSID comparison ignores case")
    }

    private static func profileMatching() {
        let both: [Condition] = [.onExternalPower(true), .batteryBelow(30)]
        let onMainsFull = context(power: true, battery: 90)
        expect(!Profile(name: "all", requiresAll: true, conditions: both).matches(onMainsFull),
               "requiresAll needs every condition")
        expect(Profile(name: "any", requiresAll: false, conditions: both).matches(onMainsFull),
               "any needs only one condition")

        // Without this an empty profile matches everything and takes over the
        // machine the moment it is created.
        expect(!Profile(name: "empty", conditions: []).matches(onMainsFull),
               "a profile with no conditions never matches")

        var disabled = Profile(name: "off", conditions: [.onExternalPower(true)])
        disabled.isEnabled = false
        expect(!disabled.matches(onMainsFull), "an inactive profile never matches")

        // Order in the list is how "specific above general" is expressed, so
        // the first match must be the one that wins.
        let specific = Profile(name: "docked",
                               conditions: [.onExternalPower(true), .externalDisplayAttached(true)])
        let general = Profile(name: "on mains", conditions: [.onExternalPower(true)])
        let docked = context(power: true, displays: 1)
        // Through the same function the engine uses, so this cannot pass while
        // the engine picks differently.
        expectEqual(Profile.firstMatching([specific, general], in: docked)?.name, "docked",
                    "the earlier profile wins")
        expectEqual(Profile.firstMatching([general, specific], in: docked)?.name, "on mains",
                    "order decides, not specificity")
        expect(Profile.firstMatching([], in: docked) == nil, "no profiles means nothing applies")
    }

    private static func profileEncoding() {
        // Profiles live as JSON in user defaults, and an enum with associated
        // values is exactly the shape that breaks quietly when it changes.
        let original = Profile(
            name: "Quiet", isEnabled: true, requiresAll: false,
            conditions: [.timeBetween(startMinutes: 22 * 60, endMinutes: 8 * 60),
                         .appRunning("Xcode"), .cpuHotterThan(82.5)],
            actions: [.turboDisabled(true), .fanCurve(min: 50, max: 80),
                      .chargeLimit(80), .pointerAcceleration(0)]
        )
        guard let data = try? JSONEncoder().encode([original]),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data) else {
            expect(false, "profiles encode and decode")
            return
        }
        expectEqual(decoded.first, original, "a profile survives a JSON round trip")
    }

    // MARK: Power limits

    private static func powerLimitPacking() {
        // Field layout of MSR_PKG_POWER_LIMIT from the Intel SDM: PL1 in bits
        // 14:0, its enable at 15, PL2 in 46:32, its enable at 47, lock at 63.
        // A power unit of 3 means eighths of a watt.
        let unit: UInt64 = 3
        let steps = Double(1 << unit)

        // A register carrying a time window (bits 23:17) and a clamp bit that
        // belong to the firmware. A composer that rebuilt the value instead of
        // editing it would lose them.
        let existing: UInt64 = (0x11 << 17) | (1 << 16) | (UInt64(20 * 8) << 32) | UInt64(15 * 8)

        guard let packed = PowerLimits.compose(current: existing, unit: unit,
                                               pl1Watts: 45, pl2Watts: 60) else {
            expect(false, "an unlocked register composes a value")
            return
        }
        expectEqual(Double(packed & 0x7FFF) / steps, 45.0, "PL1 lands in bits 14:0")
        expectEqual(Double((packed >> 32) & 0x7FFF) / steps, 60.0, "PL2 lands in bits 46:32")
        expect(packed & (1 << 15) != 0, "PL1 is marked enabled")
        expect(packed & (1 << 47) != 0, "PL2 is marked enabled")
        expect(packed & (1 << 63) == 0, "the lock bit is never set")
        expectEqual((packed >> 17) & 0x7F, 0x11, "the firmware's time window is preserved")
        expect(packed & (1 << 16) != 0, "the firmware's clamp bit is preserved")

        // Locked by the firmware: the hardware ignores the write, so composing
        // a value at all would produce a UI that lies about what happened.
        expect(PowerLimits.compose(current: existing | (1 << 63), unit: unit,
                                   pl1Watts: 45, pl2Watts: 60) == nil,
               "a locked register composes nothing")
    }

    // MARK: Keyboard

    private static func keyMappingWireFormat() {
        // The property expects the HID usage with the keyboard page in the
        // high word; the catalogue stores the bare usage so the table stays
        // readable against the spec.
        let capsLock = KeyRemapper.catalogue.first { $0.name == "Caps Lock" }
        expectEqual(capsLock?.usage, 0x39, "Caps Lock is usage 0x39")
        expectEqual(capsLock?.wireValue, 0x700000039, "the keyboard page is in the high word")
        // The same function the mapping written to the hardware goes through,
        // so this cannot pass while the live path writes to the wrong page.
        expectEqual(KeyRemapper.wireValue(forUsage: 0x39), 0x700000039,
                    "the value written to the device carries the keyboard page")
        expectEqual(KeyRemapper.wireValue(forUsage: 0xE0), 0x7000000E0,
                    "modifiers use the same page")
        expectEqual(KeyRemapper.name(forUsage: 0x29), "Escape", "usages resolve back to names")
        expectEqual(KeyRemapper.catalogue.filter { $0.name == "F1" }.first?.usage, 0x3A,
                    "F1 is usage 0x3A")
        expectEqual(KeyRemapper.catalogue.filter { $0.name == "F12" }.first?.usage, 0x45,
                    "F12 is usage 0x45")
        let usages = Set(KeyRemapper.catalogue.map(\.usage))
        expectEqual(usages.count, KeyRemapper.catalogue.count, "no usage appears twice in the catalogue")
    }

    // MARK: Sliders

    private static func sliderTickBudget() {
        // A stepped Slider draws one tick per step; a step of 1 across a fan's
        // rpm range is nearly four thousand of them, and macOS spent seventeen
        // seconds drawing that. Wide ranges must fall back to continuous.
        let ticks = ValueField.tickStep
        expect(ticks(1836...5616, 1) == nil, "a fan's rpm range gets a continuous slider")
        expect(ticks(20...100, 5) != nil, "a charge ceiling keeps its ticks")
        expect(ticks(0...2, 0.05) != nil, "acceleration keeps its ticks")
        expect(ticks(10...90, 1) == nil, "an 80-step watt range goes continuous")
    }

    // MARK: Scroll rewriting

    private static func scrollRewriting() {
        // Built rather than captured: the transformation is what is under
        // test, not the tap that delivers events to it.
        func scrollEvent(lines: Int64, continuous: Bool) -> CGEvent? {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                      wheelCount: 1, wheel1: Int32(lines), wheel2: 0, wheel3: 0)
            else { return nil }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
            return event
        }

        guard let mouse = scrollEvent(lines: 3, continuous: false),
              let trackpad = scrollEvent(lines: 3, continuous: true) else {
            expect(false, "scroll events can be constructed")
            return
        }

        // A mouse and a trackpad must be able to disagree — that is the entire
        // point of the tab, and macOS offers one switch for both.
        var options = ScrollInterceptor.Options()
        options.reverseMouse = true
        options.reverseTrackpad = false
        ScrollInterceptor.rewrite(mouse, options: options)
        ScrollInterceptor.rewrite(trackpad, options: options)
        expectEqual(mouse.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3,
                    "a mouse scroll is inverted")
        expectEqual(trackpad.getIntegerValueField(.scrollWheelEventDeltaAxis1), 3,
                    "a trackpad scroll is left alone by the mouse setting")

        // All three representations of the same delta have to move together;
        // leaving one un-negated makes the scroll fight itself, because
        // different apps read different fields.
        guard let signs = scrollEvent(lines: 5, continuous: false) else { return }
        signs.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 50)
        signs.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 5)
        var invert = ScrollInterceptor.Options()
        invert.reverseMouse = true
        ScrollInterceptor.rewrite(signs, options: invert)
        expectEqual(signs.getIntegerValueField(.scrollWheelEventDeltaAxis1), -5, "line delta flips")
        expectEqual(signs.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -50, "point delta flips")
        expectEqual(signs.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -5, "fixed-point delta flips")

        // Flattening applies to notched wheels only. A trackpad is a
        // continuous surface and pinning it to a step would feel broken.
        guard let fast = scrollEvent(lines: 12, continuous: false),
              let surface = scrollEvent(lines: 12, continuous: true) else { return }
        var linear = ScrollInterceptor.Options()
        linear.linear = true
        linear.linesPerNotch = 3
        ScrollInterceptor.rewrite(fast, options: linear)
        ScrollInterceptor.rewrite(surface, options: linear)
        expectEqual(fast.getIntegerValueField(.scrollWheelEventDeltaAxis1), 3,
                    "a fast wheel spin is flattened to the chosen step")
        expectEqual(surface.getIntegerValueField(.scrollWheelEventDeltaAxis1), 12,
                    "a trackpad is never flattened")

        guard let backwards = scrollEvent(lines: -12, continuous: false) else { return }
        ScrollInterceptor.rewrite(backwards, options: linear)
        expectEqual(backwards.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3,
                    "flattening keeps the direction")
    }

    // MARK: Menu bar drawing

    private static func menuBarDrawing() {
        // A status item carries one image. Dropping the thread bars because a
        // battery icon was already there made an explicit choice silently do
        // nothing — which is exactly how it was reported.
        guard let bars = MenuBarComposer.threadBars([0.1, 0.9, 0.5, 0.2]) else {
            expect(false, "thread bars can be drawn")
            return
        }
        expect(bars.size.width > 0 && bars.size.height > 0, "the bars have a size")

        let icon = NSImage(size: NSSize(width: 24, height: 12))
        let joined = MenuBarComposer.join(icon, bars)
        expect(joined.size.width >= icon.size.width + bars.size.width,
               "joining puts both drawings side by side")
        expect(joined.size.height >= max(icon.size.height, bars.size.height),
               "joining keeps the taller of the two")
        expectEqual(MenuBarComposer.join(nil, bars).size.width, bars.size.width,
                    "with nothing to join to, the bars stand alone")

        // Sixteen threads is what this machine has; the drawing must scale to
        // whatever it is given rather than assuming a count.
        guard let wide = MenuBarComposer.threadBars(Array(repeating: 0.5, count: 16)) else { return }
        expect(wide.size.width > bars.size.width, "more threads means a wider drawing")
        expect(MenuBarComposer.threadBars([]) == nil, "no threads draws nothing")
    }

    // MARK: Battery colours

    private static func batteryColours() {
        typealias Role = MenuBarComposer.FillRole
        func role(_ percent: Int, charging: Bool = false,
                  plugged: Bool = false, lowPower: Bool = false) -> Role {
            MenuBarComposer.fillRole(percent: percent, isCharging: charging,
                                     isPluggedIn: plugged, lowPower: lowPower)
        }

        expectEqual(role(60, charging: true, plugged: true), .charging, "charging is green")
        // Charging outranks Low Power Mode, as on the phone: a battery that is
        // filling is green even in Low Power Mode.
        expectEqual(role(60, charging: true, plugged: true, lowPower: true), .charging,
                    "charging outranks low power")
        expectEqual(role(60, lowPower: true), .lowPower, "low power is yellow at any level")
        expectEqual(role(15, lowPower: true), .lowPower, "low power outranks nearly empty")
        expectEqual(role(15), .critical, "nearly empty on battery is red")
        expectEqual(role(20), .critical, "twenty percent still counts as nearly empty")
        expectEqual(role(21), .neutral, "one percent more does not")
        // Plugged in but not charging is a full battery sitting on a charger,
        // and that is not an alarming state.
        expectEqual(role(15, plugged: true), .neutral, "nearly empty on the charger is not red")
        expectEqual(role(80), .neutral, "an ordinary level takes the system colour")
        expect(Role.neutral.colour == nil, "the neutral role stays a template image")
        expect(Role.charging.colour != nil, "a coloured role carries its own paint")
    }

    // MARK: Fan curve

    private static func fanCurve() {
        let curve = FanCurve(minTemp: 55, maxTemp: 85)
        expectEqual(curve.targetRPM(cpuTemp: 40, fanMin: 2000, fanMax: 6000), 2000,
                    "below the low threshold the fan idles")
        expectEqual(curve.targetRPM(cpuTemp: 95, fanMin: 2000, fanMax: 6000), 6000,
                    "above the high threshold the fan is flat out")
        expectEqual(curve.targetRPM(cpuTemp: 70, fanMin: 2000, fanMax: 6000), 4000,
                    "halfway between thresholds is halfway between speeds")
    }
}
