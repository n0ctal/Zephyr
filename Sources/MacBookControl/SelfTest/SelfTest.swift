import AppKit
import CoreGraphics
import IOKit.pwr_mgt
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
        modifierKeyRules()
        perAppScrollRules()
        effectiveFrequency()
        scrollSmoothing()
        sliderTickBudget()
        fanCurve()
        scrollRewriting()
        menuBarDrawing()
        batteryColours()
        powerLimitBounds()
        helperStates()
        displaySafety()
        menuBarCaptions()
        menuBarOrdering()
        networkFormatting()
        sectionCoverage()
        statusAlignment()
        terminalSliderMath()
        fanPercentages()
        telemetryNeeds()
        batteryHeat()
        arrangementGrid()
        driveWarnings()
        acceleratorClientKinds()
        gpuSensorChoice()
        sleepAssertionWording()

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

    private static func scrollSmoothing() {
        // The glide has to arrive, and in a sensible number of frames. An
        // exponential decay never reaches zero on its own, so without the
        // floor in `step` the timer would run until the app quit.
        let steps = ScrollSmoother.glide(distance: 120, factor: 0.25)
        expect(!steps.isEmpty, "a notch produces a glide")
        expect(steps.count < 30, "which ends within half a second at sixty frames")
        let travelled = steps.reduce(0, +)
        expect(abs(travelled - 120) < 0.001, "and travels exactly as far as the notch asked")
        // Direction survives, and so does the arrival.
        let back = ScrollSmoother.glide(distance: -120, factor: 0.25)
        expect(back.allSatisfy { $0 <= 0 }, "an upward notch glides upward throughout")
        expect(abs(back.reduce(0, +) + 120) < 0.001, "and arrives too")
        // Each step is smaller than the last, which is what makes it a glide
        // rather than a slice — up to the last one, which is the floor paying
        // out the whole remainder at once so the timer can stop.
        let body = steps.dropLast()
        let decaying = zip(body, body.dropFirst()).allSatisfy { abs($0) >= abs($1) }
        expect(decaying, "each frame moves less than the one before it")
        expect((steps.last ?? 0) < 4, "and the last frame is the small remainder")
        // A distance below a pixel goes out at once rather than never.
        expectEqual(ScrollSmoother.step(remaining: 0.4, factor: 0.25), 0.4,
                    "less than a pixel left is paid out in one frame")
        expectEqual(ScrollSmoother.step(remaining: 0, factor: 0.25), 0, "nothing stays nothing")
        // A factor of zero would be a glide that never moves; it is clamped.
        expect(ScrollSmoother.glide(distance: 100, factor: 0).count < 600,
               "even a nonsensical factor terminates")
        // Smoothing alone is reason enough to run the tap.
        var options = ScrollInterceptor.Options()
        options.smooth = true
        expect(options.wantsAnything, "smoothing on its own turns the interception on")
        // And a rule can switch it off for one application, which is the
        // exclusion list every smoothing tool ends up needing.
        options.appRules = [AppScrollRule(bundleID: "x", name: "X", reverse: nil,
                                          linear: nil, linesPerNotch: nil,
                                          scale: nil, smooth: false)]
        expect(!ScrollInterceptor.resolve(options, forApp: "x").smooth,
               "an application can opt out of the glide")
        expect(ScrollInterceptor.resolve(options, forApp: "y").smooth,
               "while everything else keeps it")
    }

    private static func effectiveFrequency() {
        typealias Counters = CPUFrequency.Counters
        let base: UInt64 = 2_300_000_000
        // Running at the base clock: as many active cycles as reference ones.
        expectEqual(CPUFrequency.hertz(from: Counters(aperf: 0, mperf: 0),
                                       to: Counters(aperf: 1000, mperf: 1000),
                                       base: base),
                    Double(base), "equal counters mean the base clock")
        // Turbo: more active cycles than reference ones.
        let boosted = CPUFrequency.hertz(from: Counters(aperf: 0, mperf: 0),
                                         to: Counters(aperf: 2000, mperf: 1000),
                                         base: base)
        expectEqual(boosted, Double(base) * 2, "twice the reference is twice the clock")
        // Idle: fewer.
        expectEqual(CPUFrequency.hertz(from: Counters(aperf: 0, mperf: 0),
                                       to: Counters(aperf: 500, mperf: 1000),
                                       base: base),
                    Double(base) / 2, "half the reference is half the clock")
        // A counter that went backwards means it was reset — a deep sleep
        // state, or a wrap — and inventing a frequency from it would put a
        // wild number on screen at exactly the moment the machine woke up.
        expect(CPUFrequency.hertz(from: Counters(aperf: 5000, mperf: 5000),
                                  to: Counters(aperf: 10, mperf: 5001),
                                  base: base) == nil,
               "a counter that went backwards is discarded, not turned into a number")
        expect(CPUFrequency.hertz(from: Counters(aperf: 0, mperf: 1000),
                                  to: Counters(aperf: 100, mperf: 1000),
                                  base: base) == nil,
               "no reference cycles is no interval, not an infinite clock")
        // Nothing on Intel triples its base clock; that is a reset, not turbo.
        expect(CPUFrequency.hertz(from: Counters(aperf: 0, mperf: 0),
                                  to: Counters(aperf: 9000, mperf: 1000),
                                  base: base) == nil,
               "an impossible ratio is rejected rather than displayed")
        expect(CPUFrequency.hertz(from: Counters(aperf: 0, mperf: 0),
                                  to: Counters(aperf: 1000, mperf: 1000),
                                  base: 0) == nil,
               "and without a base frequency there is nothing to scale by")
    }

    private static func perAppScrollRules() {
        var base = ScrollInterceptor.Options()
        base.reverseMouse = true
        base.scale = 1.0
        base.appRules = [AppScrollRule(bundleID: "com.apple.Preview", name: "Preview",
                                       reverse: nil, linear: nil,
                                       linesPerNotch: nil, scale: 2.0)]
        // The rule speaks only about speed, so the direction the device is set
        // to has to survive it. Getting this wrong is invisible until someone
        // adds a speed rule and finds their scrolling flipped.
        let inPreview = ScrollInterceptor.resolve(base, forApp: "com.apple.Preview")
        expectEqual(inPreview.scale, 2.0, "a rule applies while its app is in front")
        expectEqual(inPreview.reverseMouse, true, "and leaves untouched settings alone")
        let elsewhere = ScrollInterceptor.resolve(base, forApp: "com.apple.Safari")
        expectEqual(elsewhere.scale, 1.0, "another app keeps the plain settings")
        expectEqual(ScrollInterceptor.resolve(base, forApp: nil).scale, 1.0,
                    "and so does not knowing which app is in front")
        // A direction rule overrides both kinds of device, since it is about
        // the application rather than the hardware.
        base.appRules = [AppScrollRule(bundleID: "x", name: "X", reverse: false,
                                       linear: nil, linesPerNotch: nil, scale: nil)]
        let flipped = ScrollInterceptor.resolve(base, forApp: "x")
        expectEqual(flipped.reverseMouse, false, "a direction rule overrides the device")
        expectEqual(flipped.reverseTrackpad, false, "for the trackpad too")
        // The tap has to run for a rule alone, or per-app settings would need
        // an unrelated global switch turned on first.
        var only = ScrollInterceptor.Options()
        only.appRules = [AppScrollRule(bundleID: "x", name: "X", reverse: true,
                                       linear: nil, linesPerNotch: nil, scale: nil)]
        expect(only.wantsAnything, "a rule on its own is reason enough to intercept")
        only.appRules = [AppScrollRule(bundleID: "x", name: "X", reverse: nil,
                                       linear: nil, linesPerNotch: nil, scale: 1.0)]
        expect(!only.wantsAnything, "a rule that changes nothing is not")
        // Scaling a whole-number delta must not round a notch away entirely.
        expectEqual(ScrollInterceptor.scaled(1, by: 0.25), 1,
                    "a slowed notch still moves a line rather than none")
        expectEqual(ScrollInterceptor.scaled(-1, by: 0.25), -1, "in both directions")
        expectEqual(ScrollInterceptor.scaled(4, by: 0.5), 2, "and scales normally otherwise")
        expectEqual(ScrollInterceptor.scaled(0, by: 3), 0, "nothing scrolled stays nothing")
    }

    private static func modifierKeyRules() {
        typealias Rule = KeyInterceptor.Rule
        // ⌃C becomes Escape, giving the modifier back rather than passing it on.
        let escape = Rule(fromKey: 8, fromModifiers: [.control], toKey: 53, toModifiers: [])
        let hit = KeyInterceptor.rewrite(rules: [escape], key: 8, held: [.control])
        expectEqual(hit?.key, 53, "a rule with its modifier held fires")
        expectEqual(hit?.modifiers, [], "the modifier the rule consumed is not passed on")
        expect(KeyInterceptor.rewrite(rules: [escape], key: 8, held: []) == nil,
               "the same key without the modifier is left alone")
        // Extra modifiers do not block a match, but they do survive it: ⌃⇧C
        // must still arrive as a shifted Escape.
        let shifted = KeyInterceptor.rewrite(rules: [escape], key: 8, held: [.control, .shift])
        expectEqual(shifted?.modifiers, [.shift], "modifiers the rule did not ask for survive")
        // A rule that adds a modifier gets it even from a bare keypress.
        let adds = Rule(fromKey: 53, fromModifiers: [], toKey: 48, toModifiers: [.command])
        expectEqual(KeyInterceptor.rewrite(rules: [adds], key: 53, held: [])?.modifiers,
                    [.command], "a rule can add a modifier")
        // Two rules on one key: the one demanding more wins, whatever the order.
        let broad = Rule(fromKey: 8, fromModifiers: [.control], toKey: 1, toModifiers: [])
        let narrow = Rule(fromKey: 8, fromModifiers: [.control, .option], toKey: 2, toModifiers: [])
        expectEqual(KeyInterceptor.rewrite(rules: [broad, narrow], key: 8,
                                           held: [.control, .option])?.key,
                    2, "the more specific rule wins")
        expectEqual(KeyInterceptor.rewrite(rules: [narrow, broad], key: 8,
                                           held: [.control, .option])?.key,
                    2, "and wins regardless of the order they were added in")
        expectEqual(KeyInterceptor.rewrite(rules: [narrow, broad], key: 8,
                                           held: [.control])?.key,
                    1, "while the broader one still covers its own case")
        expect(KeyInterceptor.rewrite(rules: [], key: 8, held: [.control]) == nil,
               "no rules, no rewriting")
        // The flags round-trip, or the tap would hand the window server a
        // keystroke with modifiers it never asked for.
        expectEqual(KeyInterceptor.Modifiers.of([.maskCommand, .maskShift]),
                    [.command, .shift], "event flags read back as the modifiers they are")
        expectEqual(KeyInterceptor.Modifiers([.control, .option]).flags
                        .contains(.maskAlternate), true, "and convert back again")
        // Virtual codes, not HID usages: Escape is 53 here and 0x29 in hidutil.
        expectEqual(KeyInterceptor.virtualKeys.first { $0.name == "Escape" }?.code, 53,
                    "the rule catalogue speaks virtual key codes")
        expectEqual(Set(KeyInterceptor.virtualKeys.map(\.code)).count,
                    KeyInterceptor.virtualKeys.count, "no key code is listed twice")
    }

    private static func gpuSensorChoice() {
        func reading(_ key: String, _ celsius: Double) -> TemperatureReading {
            TemperatureReading(key: key, label: key, celsius: celsius)
        }
        // The machine this was written on publishes all four discrete keys, so
        // the order only shows itself on a machine that does not.
        let all = [reading("TG0P", 60), reading("TG1P", 56),
                   reading("TGDD", 35), reading("TCGC", 64)]
        expectEqual(Telemetry.gpuTemperature(in: all, discrete: true)?.key, "TG0P",
                    "the discrete card is read from TG0P when it is there")
        expectEqual(Telemetry.gpuTemperature(in: all, discrete: false)?.key, "TCGC",
                    "the integrated card is read from TCGC")
        // The case the preference exists for: no TG0P, a live sensor under
        // another name. Before the list this showed a dash.
        let noTG0P = all.filter { $0.key != "TG0P" }
        expectEqual(Telemetry.gpuTemperature(in: noTG0P, discrete: true)?.key, "TG1P",
                    "without TG0P the discrete card falls back to TG1P")
        let dieOnly = [reading("TGDD", 35), reading("TCGC", 64)]
        expectEqual(Telemetry.gpuTemperature(in: dieOnly, discrete: true)?.key, "TGDD",
                    "and to the die reading when that is all there is")
        // Nothing invented when the card publishes nothing: a dash is the
        // honest answer, and TCGC belongs to the integrated side.
        expect(Telemetry.gpuTemperature(in: [reading("TCGC", 64)], discrete: true) == nil,
               "the integrated sensor is not offered as the discrete one")
        expect(Telemetry.gpuTemperature(in: [], discrete: false) == nil,
               "no readings, no answer")
    }

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
        // The rule: at most sixteen marks. Past that they stop being readable
        // long before they stop being drawable, and the number beside the
        // slider is what anyone uses to hit an exact value.
        expect(ticks(0...16, 1) != nil, "sixteen steps still get their marks")
        expect(ticks(0...17, 1) == nil, "seventeen do not")
        expect(ticks(20...100, 5) != nil, "a charge ceiling, sixteen steps, keeps its marks")
        expect(ticks(0...2, 0.05) == nil, "forty steps of acceleration go continuous")
        expect(ticks(1836...5616, 1) == nil, "a fan's rpm range is nowhere near")
        expect(ticks(10...90, 1) == nil, "an eighty-step watt range goes continuous")
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

        // The battery pill keeps one width whatever number it holds. Fitting
        // it to the digits makes the whole menu bar shift sideways every time
        // the charge ticks over.
        func pill(_ percent: Int) -> NSSize {
            let status = BatteryStatus(percent: percent, isCharging: false, isPluggedIn: true,
                                       healthPercent: 82, cycleCount: 393, power: nil,
                                       minutesRemaining: nil)
            return MenuBarComposer.batteryImage(status, showingPercentage: true)?.size ?? .zero
        }
        expectEqual(pill(5).width, pill(100).width, "one digit and three take the same width")
        expectEqual(pill(99).width, pill(100).width, "and so do two")
        expect(pill(100).width > 0, "the pill has a width at all")

        // The bars hang from the top. Standing on the bottom, an idle machine
        // drew a row of specks along the lower edge that read as dirt rather
        // than as a graph. Checked by looking at the pixels, since that is the
        // only thing that can tell which way up a drawing is.
        guard let idle = MenuBarComposer.threadBars(Array(repeating: 0.02, count: 8)),
              let tiff = idle.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            expect(false, "the idle drawing can be inspected")
            return
        }
        func inkInRow(_ y: Int) -> Bool {
            (0..<bitmap.pixelsWide).contains { x in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            }
        }
        expect(inkInRow(0), "an idle bar reaches the top edge")
        expect(!inkInRow(bitmap.pixelsHigh - 1), "an idle bar does not touch the bottom edge")
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

    // MARK: Slider bounds for the power limit

    private static func powerLimitBounds() {
        // The real register on this machine: PL1 100 W, PL2 125 W, TDP 45 W,
        // and MSR_PKG_POWER_INFO reporting minimum and maximum as ZERO. Those
        // fields are optional and this i9 leaves them empty; trusting them
        // produced the range 10...0, which is not a range and killed the tab.
        let reading = PowerLimits.Reading(
            pl1Watts: 100, pl2Watts: 125, pl1Enabled: true, pl2Enabled: true,
            isLocked: false, tdpWatts: 45, minWatts: 0, maxWatts: 0, raw: 0)
        expect(reading.lowerBound < reading.upperBound, "the bounds make a usable range")
        expect(reading.upperBound >= reading.pl2Watts,
               "the slider can reach the value already set")
        expect(reading.lowerBound > 0, "the lower bound is not zero watts")

        // A part that does report its limits should be believed.
        let reported = PowerLimits.Reading(
            pl1Watts: 15, pl2Watts: 25, pl1Enabled: true, pl2Enabled: true,
            isLocked: false, tdpWatts: 15, minWatts: 8, maxWatts: 44, raw: 0)
        expectEqual(reported.lowerBound, 8, "a reported minimum is used")
        expect(reported.upperBound >= 44, "a reported maximum is respected")

        // Nothing reported at all still has to produce something usable.
        let blank = PowerLimits.Reading(
            pl1Watts: 0, pl2Watts: 0, pl1Enabled: false, pl2Enabled: false,
            isLocked: false, tdpWatts: nil, minWatts: nil, maxWatts: nil, raw: 0)
        expect(blank.lowerBound < blank.upperBound, "an empty reading still makes a range")
    }

    // MARK: Helper states

    private static func helperStates() {
        // Two failures that look identical from the app — no answer — and need
        // opposite advice. Lumping them into "install the helper" told someone
        // who installed it yesterday to install it again, while everything
        // that touches hardware sat silently broken.
        expectEqual(HelperState.from(version: "5", daemonInstalled: true),
                    .working(version: "5"), "an answer means it works")
        expectEqual(HelperState.from(version: "5", daemonInstalled: false),
                    .working(version: "5"), "an answer settles it regardless of the plist")
        expectEqual(HelperState.from(version: nil, daemonInstalled: true),
                    .notAuthorized, "installed but silent means the app was rebuilt")
        expectEqual(HelperState.from(version: nil, daemonInstalled: false),
                    .notInstalled, "no plist and no answer means it was never installed")

        expect(HelperState.working(version: "5").isWorking, "working reads as working")
        expect(!HelperState.notAuthorized.isWorking, "unauthorised does not read as working")
        expect(HelperState.working(version: "5").explanation == nil,
               "a working helper needs no explanation")
        expect(HelperState.notAuthorized.explanation?.isEmpty == false,
               "an unauthorised one does")
        expect(HelperState.notAuthorized.summary != HelperState.notInstalled.summary,
               "the two failures do not read the same")
    }

    // MARK: Display safety

    private static func displaySafety() {
        // The control that makes other display utilities dangerous. The guard
        // is checked here rather than trusted: with one display attached it
        // must refuse, and it must keep refusing however it is asked.
        // Blanking is the only "off" the interface offers, and the property
        // that makes it safe is that it changes nothing about the arrangement:
        // whatever it does, the display is still there to draw on.
        let blankControl = DisplayControl()
        if let screen = blankControl.screens().first {
            let before = blankControl.screens().count
            expect(!blankControl.isBlanked(screen.id), "nothing is blanked to begin with")
            expect(blankControl.screens().count == before,
                   "and asking does not change the arrangement")
        }

        // The rule that prevents the failure people report of other display
        // utilities: switch the built-in panel off with an external attached,
        // unplug the external, and there is nowhere left to draw the window
        // that would switch it back on. Only a restart recovers.
        let control = DisplayControl()
        let screens = control.screens()
        expect(!screens.isEmpty, "at least one display is present")

        if let only = screens.first, screens.count == 1 {
            expect(!control.canSafelyDisable(only.id),
                   "the last remaining display may never be switched off")
        }
        for screen in screens where screens.count > 1 {
            expect(control.canSafelyDisable(screen.id),
                   "with more than one display, any single one may be switched off")
        }

        // Modes must always be offered against a display that exists, and the
        // list must contain the one currently in use — a picker that cannot
        // show the current state is how a wrong choice gets made.
        if let first = screens.first {
            let modes = control.modes(for: first.id)
            expect(!modes.isEmpty, "the display offers modes")
            if let current = control.currentMode(for: first.id) {
                expect(modes.contains { $0.id == current.id },
                       "the current mode is among those offered")
            }
        }
    }

    // MARK: Menu-bar captions

    private static func menuBarCaptions() {
        // The set has to exist, holding what was in force, before anything can
        // be taken out of it. Without that, switching one caption off wrote a
        // set starting from empty and removed every caption at once — which is
        // exactly what was reported.
        let defaults = UserDefaults.standard
        let savedSet = defaults.object(forKey: "menubar.captionedItems")
        let savedFlag = defaults.object(forKey: "menubar.captions")
        defer {
            defaults.set(savedSet, forKey: "menubar.captionedItems")
            defaults.set(savedFlag, forKey: "menubar.captions")
        }

        // Upgrading from "everything captioned".
        defaults.removeObject(forKey: "menubar.captionedItems")
        defaults.set(true, forKey: "menubar.captions")
        var set = Preferences.captionedMenuBarItems
        expectEqual(set.count, MenuBarComposer.Item.allCases.count,
                    "the old all-on switch becomes every item")
        set.remove(MenuBarComposer.Item.memory.rawValue)
        Preferences.captionedMenuBarItems = set
        expect(Preferences.menuBarItemIsCaptioned(.cpuLoad),
               "taking one caption off leaves the others alone")
        expect(!Preferences.menuBarItemIsCaptioned(.memory), "and takes that one off")

        // Upgrading from "nothing captioned".
        defaults.removeObject(forKey: "menubar.captionedItems")
        defaults.set(false, forKey: "menubar.captions")
        expectEqual(Preferences.captionedMenuBarItems.count, 0,
                    "the old all-off switch becomes no items")
    }

    // MARK: Menu-bar ordering

    private static func menuBarOrdering() {
        let shown: [MenuBarComposer.Item] = [.memory, .temperature, .battery]
        let listed = MenuBarComposer.Item.listOrder(shown: shown)
        expectEqual(Array(listed.prefix(3)), shown,
                    "the list leads with what is shown, in the order it is shown")
        expectEqual(Set(listed).count, MenuBarComposer.Item.allCases.count,
                    "and still lists every field exactly once")
        expectEqual(listed.count, MenuBarComposer.Item.allCases.count,
                    "with nothing repeated")
        expect(!listed.dropFirst(3).contains(.battery),
               "a field that was moved to the front is not also left behind")
        expectEqual(MenuBarComposer.Item.listOrder(shown: []),
                    MenuBarComposer.Item.allCases,
                    "with nothing shown the list is the plain order")
    }

    // MARK: Network speed

    private static func networkFormatting() {
        expectEqual(NetworkThroughput.format(0), "0 KB/s", "silence reads as zero, not as nothing")
        expectEqual(NetworkThroughput.format(200), "0 KB/s", "a trickle rounds to zero rather than to 0.2")
        expectEqual(NetworkThroughput.format(64 * 1024), "64 KB/s", "kilobytes while it is kilobytes")
        expectEqual(NetworkThroughput.format(5 * 1024 * 1024), "5.0 MB/s", "megabytes past a thousand kilobytes")
        expectEqual(NetworkThroughput.format(2.5 * 1024 * 1024 * 1024), "2.5 GB/s", "and gigabytes past a thousand of those")
        expect(NetworkThroughput.isPlausible(125 * 1024 * 1024), "a gigabit link is a real speed")
        expect(!NetworkThroughput.isPlausible(4 * 1024 * 1024 * 1024),
               "four gigabytes a second is an interface that went away, not traffic")
        expect(NetworkThroughput.isTunnel("utun3"), "a VPN interface is a tunnel")
        expect(NetworkThroughput.isTunnel("ipsec0"), "so is an IPsec one")
        expect(!NetworkThroughput.isTunnel("en0"), "Wi-Fi is not")
        // The bytes a tunnel carries also leave over the interface underneath
        // it. Counting both doubles the reading the moment a VPN connects.
        expect(!NetworkThroughput.isTunnel("utility"),
               "and the check is a prefix on the interface name, not a substring anywhere")
    }

    // MARK: Sections

    private static func sectionCoverage() {
        let ids = SettingsSection.allCases.flatMap(\.featureIDs)
        expectEqual(Set(ids).count, ids.count,
                    "no feature is listed under two sections")
        // Must match the registry in AppController.swift. A feature missing
        // from here is unreachable in the sidebar layouts — the tab list is
        // built from the registry, the sidebar from this.
        expectEqual(Set(ids), ["cooling", "turbo", "powerlimit", "graphics", "battery", "awake",
                               "display", "keyboard", "pointer", "profiles"],
                    "every feature the app builds has a section to live in")
        expect(SettingsSection(rawValue: "profiles") == nil,
               "Profiles is no longer a section of its own")
        expect(SettingsSection.diagnostics.featureIDs.isEmpty,
               "Diagnostics owns no feature: it only reads")
        expect(SettingsSection.allCases.last == .settings,
               "Settings comes last, after Menu Bar")
        expect(!WindowLayout.classic.usesSidebar, "the classic layout keeps its tabs")
        expect(WindowLayout.quiet.usesSidebar && WindowLayout.terminal.usesSidebar,
               "the other two are sidebars")
    }

    private static func statusAlignment() {
        // The corner readout is composed as padded strings so its columns line
        // up by character count. With nothing read yet every field is a dash,
        // which is the case where a width mistake is easiest to miss.
        let lines = StatusReadout.lines(telemetry: Telemetry())
        expect(lines.count >= 2, "the readout always has a CPU and a GPU line")
        // Every line the same width, not merely the same as its neighbour:
        // that is what gives the block an equal margin on both sides.
        expect(lines.allSatisfy { $0.count == 29 },
               "every readout line is exactly 29 characters")
    }

    // MARK: Terminal slider

    private static func terminalSliderMath() {
        // A 200-point track with a 10-point knob leaves 190 of travel, and the
        // knob is grabbed at its centre.
        let knob: CGFloat = 10, travel: CGFloat = 190
        func at(_ x: CGFloat, _ range: ClosedRange<Double>, _ step: Double) -> Double {
            TerminalSlider.value(atX: x, knob: knob, travel: travel, range: range, step: step)
        }
        expectEqual(at(5, 0...100, 1), 0, "the far left is the low end")
        expectEqual(at(195, 0...100, 1), 100, "the far right is the high end")
        expectEqual(at(100, 0...100, 1), 50, "and the middle is the middle")
        expectEqual(at(-40, 0...100, 1), 0, "dragging off the left edge clamps")
        expectEqual(at(400, 0...100, 1), 100, "and so does dragging off the right")
        // Watts, where a wrong answer is written to a register.
        expectEqual(at(100, 10...110, 5), 60, "steps land on multiples of the step")
        expectEqual(at(103, 10...110, 5), 60, "a pixel either side rounds to the same step")
        expectEqual(at(195, 10...110, 7), 110,
                    "the top is reachable even when the step does not divide the range")
        expectEqual(at(189, 10...110, 7), 108,
                    "while everything short of the end still lands on the step")
        expectEqual(at(100, 45...45, 1), 45, "a range of one value has one answer")
    }

    // MARK: Fans by percentage

    private static func fanPercentages() {
        // The two fans in this machine, which do not share a range — the whole
        // reason the control that drives both at once is a share and not a
        // speed.
        func left(_ percent: Double) -> Int {
            CoolingFeature.targetRPM(percent: percent, min: 1836, max: 5616)
        }
        func right(_ percent: Double) -> Int {
            CoolingFeature.targetRPM(percent: percent, min: 1800, max: 5200)
        }
        expectEqual(left(0), 1836, "0 % is the fan's own minimum, not a stop")
        expectEqual(right(0), 1800, "which differs per fan")
        expectEqual(left(100), 5616, "100 % is its own maximum")
        expectEqual(right(100), 5200, "which also differs per fan")
        expectEqual(left(50), 3726, "and halfway is halfway along its own range")
        expectEqual(right(50), 3500, "for each of them separately")
        expectEqual(left(-20), 1836, "a percentage below zero clamps")
        expectEqual(left(150), 5616, "and one above a hundred clamps too")
        // A fan reporting the same minimum and maximum must not divide by zero.
        expectEqual(CoolingFeature.targetRPM(percent: 60, min: 2000, max: 2000), 2000,
                    "a fan with no range at all still answers its one speed")
    }

    // MARK: What is worth reading

    private static func telemetryNeeds() {
        // With the window closed, the cost of a tick is decided here.
        let temperatureOnly = Telemetry.Needs.of(menuBar: [.temperature])
        expect(temperatureOnly.oneSensor, "a temperature in the menu bar wants one sensor")
        expect(!temperatureOnly.full,
               "and not the sweep of all forty-eight, which is the whole point")
        expect(!temperatureOnly.load && !temperatureOnly.network,
               "nothing else is read for it")

        let nothing = Telemetry.Needs.of(menuBar: [])
        expect(!nothing.oneSensor && !nothing.fans && !nothing.battery
               && !nothing.load && !nothing.network,
               "an empty menu bar reads nothing but the thermal state")

        expect(Telemetry.Needs.everything.full,
               "an open window reads everything, including the expensive ones")

        let power = Telemetry.Needs.of(menuBar: [.power])
        expect(power.battery, "watts come from the battery reading")
        let throttle = Telemetry.Needs.of(menuBar: [.throttle])
        expect(!throttle.full && !throttle.load,
               "the throttle mark needs no sensors: the thermal state is read every tick anyway")
        let memory = Telemetry.Needs.of(menuBar: [.memory])
        expect(memory.load && !memory.full,
               "memory comes from the load snapshot, which need not include the GPU")

        // A rule decides on the CPU sensor by name, never on whichever one the
        // status item happens to be showing.
        expect(Condition.cpuHotterThan(80).telemetryNeeds.cpuSensor,
               "a temperature rule keeps the CPU sensor alive")
        expect(!Condition.cpuHotterThan(80).telemetryNeeds.oneSensor,
               "and not the menu bar's sensor, whatever that is set to")
        expect(Condition.batteryBelow(20).telemetryNeeds.battery,
               "a charge rule keeps the battery reading alive")
        expect(!Condition.onExternalPower(true).telemetryNeeds.battery,
               "the power source is not a reading, so it asks for nothing")

        // The union is what actually decides a tick.
        let both = Telemetry.Needs.of(menuBar: [.temperature])
            .union(Condition.cpuHotterThan(80).telemetryNeeds)
        expect(both.oneSensor && both.cpuSensor,
               "with both, the menu bar's sensor and the CPU's are asked for separately")
    }

    // MARK: Holding the charger off while the cell is hot

    private static func batteryHeat() {
        typealias Decision = BatteryFeature.HeatDecision
        func decide(_ celsius: Double?, _ limit: Int, paused: Bool) -> Decision {
            BatteryFeature.heatDecision(celsius: celsius, limit: limit, isPaused: paused)
        }
        expectEqual(decide(36, 35, paused: false), .hold, "past the limit the charger is held off")
        expectEqual(decide(35, 35, paused: false), .hold, "and exactly at it, since that is what it says")
        expectEqual(decide(34, 35, paused: false), .leaveAlone, "below it nothing happens")

        // The hysteresis: cooling to just under the limit is not enough, or
        // the ceiling is rewritten every ten seconds by a cell sitting on it.
        expectEqual(decide(34, 35, paused: true), .leaveAlone,
                    "one degree of cooling does not resume")
        expectEqual(decide(33, 35, paused: true), .resume,
                    "two degrees does")

        expectEqual(decide(nil, 35, paused: false), .leaveAlone,
                    "a battery that reports no temperature is left alone")
        expectEqual(decide(50, 0, paused: false), .leaveAlone,
                    "with the guard off, heat is not acted on")
        expectEqual(decide(50, 0, paused: true), .resume,
                    "and switching the guard off while it is holding lets go")
    }

    // MARK: The arrangement grid

    private static func arrangementGrid() {
        typealias Cell = DisplayControl.Cell
        func span(_ cells: [Cell], moving: Cell?) -> (rows: ClosedRange<Int>,
                                                      columns: ClosedRange<Int>) {
            DisplayControl.gridSpan(cells: cells, moving: moving)
        }

        // Two side by side. The grid offers the squares the moving screen can
        // reach, which is three columns and not four: a fourth would sit past
        // the screen being moved, and dropping it there would leave a gap the
        // window server immediately packs away.
        let pair = [Cell(row: 0, column: 0), Cell(row: 0, column: 1)]
        let movingRight = span(pair, moving: Cell(row: 0, column: 1))
        expectEqual(movingRight.columns, -1...1, "two in a row need three columns, not four")
        expectEqual(movingRight.rows, -1...1, "and one row above and below")
        // The other screen selected: the same width, the free square on the
        // other side, because that is where that screen can go.
        let movingLeft = span(pair, moving: Cell(row: 0, column: 0))
        expectEqual(movingLeft.columns, 0...2, "the free square follows the screen being moved")
        expectEqual(movingLeft.columns.count, movingRight.columns.count,
                    "and the grid does not change size when the selection does")

        // One screen is its own anchor and still gets somewhere to go.
        expectEqual(span([Cell(row: 0, column: 0)], moving: Cell(row: 0, column: 0)).columns,
                    -1...1, "a single screen still has a ring around it")

        // Every screen a Mac Pro can drive, in one line. All twelve must be on
        // the grid, with somewhere to move at the end being moved from.
        let twelve = (0..<12).map { Cell(row: 0, column: $0) }
        let wide = span(twelve, moving: Cell(row: 0, column: 11))
        expect(wide.columns.contains(0) && wide.columns.contains(11),
               "twelve in a row are all on the grid")
        expectEqual(wide.columns, -1...11, "with a square beyond the far end")
        expectEqual(wide.rows, -1...1, "and a row above and below")

        // The same, stacked.
        let tall = span((0..<12).map { Cell(row: $0, column: 0) },
                        moving: Cell(row: 11, column: 0))
        expectEqual(tall.rows, -1...11, "and the same standing up")

        // A screen dragged far out: it stays on the grid however far it is,
        // because losing a screen off the edge is worse than a wide grid.
        let scattered = span([Cell(row: 0, column: 0), Cell(row: 0, column: 9)],
                             moving: Cell(row: 0, column: 9))
        expect(scattered.columns.contains(0) && scattered.columns.contains(9),
               "both screens stay on the grid however far apart they are")

        // Nothing selected falls back to a ring around everything rather than
        // to an empty grid.
        expectEqual(span(pair, moving: nil).columns, -1...2,
                    "with no screen named, the ring goes around them all")

        expectEqual(span([], moving: nil).columns, 0...2,
                    "with nothing placed there is still a grid to place onto")
    }

    // MARK: Drive health

    private static func driveWarnings() {
        func reading(warning: UInt8, spare: Int = 100, threshold: Int = 10,
                     media: UInt64 = 0) -> DriveHealth.Reading {
            DriveHealth.Reading(model: "test", serial: "", capacityBytes: 0,
                                criticalWarning: warning, celsius: 34,
                                percentageUsed: 7, availableSpare: spare,
                                spareThreshold: threshold, bytesWritten: 0, bytesRead: 0,
                                powerOnHours: 0, powerCycles: 0, unsafeShutdowns: 0,
                                mediaErrors: media)
        }
        expect(reading(warning: 0).isHealthy, "no warning bits and no errors is a healthy drive")
        expect(reading(warning: 0).warnings.isEmpty, "and it has nothing to say")
        expect(!reading(warning: 0, media: 1).isHealthy,
               "a single media error is not healthy, whatever the drive claims")
        expect(!reading(warning: 0, spare: 5, threshold: 10).isHealthy,
               "nor is spare capacity under its own threshold")
        expect(reading(warning: 0, spare: 10, threshold: 10).isHealthy,
               "but exactly at the threshold is not yet past it")
        expect(reading(warning: 0, spare: 0, threshold: 0).isHealthy,
               "and a drive that does not track spare blocks is not failing")
        // Bit 1 is the temperature warning, bit 3 the read-only one.
        expectEqual(reading(warning: 0b0000_1010).warnings.count, 2,
                    "each warning bit is reported separately")
        expect(reading(warning: 0b0000_0010).warnings.first?.contains("temperature") == true,
               "and the bits are decoded in the order the specification lists them")
    }

    private static func acceleratorClientKinds() {
        // The distinction the whole reading rests on: a command queue is work,
        // a device handle is only an introduction.
        expect(AcceleratorClients.isWorkClient("AMDRadeonX6000_AMDAccelCommandQueue"),
               "a command queue is work being submitted")
        expect(AcceleratorClients.isWorkClient("AMDRadeonX6000_AMDAccel2DContext"),
               "and so is a context")
        expect(!AcceleratorClients.isWorkClient("AMDRadeonX6000_AMDAccelDevice"),
               "a device handle is not: everything that ever listed the GPUs has one")
        expect(!AcceleratorClients.isWorkClient("AMDRadeonX6000_AMDAccelSharedUserClient"),
               "nor is a shared user client")
    }

    private static func sleepAssertionWording() {
        func effect(_ kind: String) -> String {
            SleepDiagnostics.Assertion(sequence: 0, pid: 1, process: "test", kind: kind,
                                       name: "", since: nil).effect
        }
        // Spelled out on purpose: these are the strings the power-management
        // registry reports, and the SDK constants have been known to resolve
        // to something else.
        expectEqual(effect("PreventUserIdleSystemSleep"), "keeps the Mac awake",
                    "the system assertions are described by what they do")
        expectEqual(effect("NoIdleSleepAssertion"), "keeps the Mac awake",
                    "including the one an Electron application leaves behind")
        expectEqual(effect("PreventUserIdleDisplaySleep"), "keeps the display on",
                    "and the display ones separately")
        expectEqual(kIOPMAssertionTypePreventUserIdleSystemSleep as String,
                    "PreventUserIdleSystemSleep",
                    "and the SDK constant still agrees with the literal")
        expectEqual(effect("SomethingNewFromApple"), "SomethingNewFromApple",
                    "an assertion type nobody has seen before is shown as itself")
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
