import AppKit
import CoreGraphics
import Foundation

// Entry point. A hidden `--dump-smc` flag runs a one-shot CLI sensor dump
// (handy for debugging and for open-source users); otherwise the menu-bar
// app launches.
let arguments = CommandLine.arguments
let launchedAt = Date()

// Launched by launchd as the privileged root daemon.
if arguments.contains("--helper-daemon") {
    runHelperDaemon()  // never returns
}

if arguments.contains("--dump-smc") {
    runSMCDump()
    exit(0)
}

if arguments.contains("--test-helper") {
    runHelperTest()
    exit(0)
}

if arguments.contains("--test-fans") {
    runFanTest(write: arguments.contains("--write"))
    exit(0)
}

if arguments.contains("--test-gpu") {
    runGPUTest()
    exit(0)
}

if arguments.contains("--dump-icons") {
    runIconDump()
    exit(0)
}

if arguments.contains("--self-test") {
    exit(SelfTest.run())
}

if arguments.contains("--test-timing") {
    runTimingTest()
    exit(0)
}

if arguments.contains("--test-profiles") {
    runProfilesTest()
    exit(0)
}

if arguments.contains("--test-keyboard") {
    runKeyboardTest(write: arguments.contains("--write"))
    exit(0)
}

if arguments.contains("--test-scroll") {
    runScrollTest()
    exit(0)
}

if arguments.contains("--test-pointer") {
    runPointerTest(write: arguments.contains("--write"))
    exit(0)
}

// Single-instance guard: if another copy (e.g. the login item) is already
// running, exit so we don't add a second menu-bar icon. (bundleIdentifier is
// nil for the bare dev binary, so this only applies to the .app.)
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0 != NSRunningApplication.current }
    if !others.isEmpty { exit(0) }
}

// Default: launch the menu-bar app (accessory = menu-bar only, no Dock icon).
// AppController sets up its status item in init() and is retained here.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = AppController()
_ = controller
// Dev affordance: the Settings window is only reachable by clicking the status
// item, which nothing automated can do — so a broken tab would only ever be
// found by hand. This opens it at launch so the build can prove it constructs.
if let flag = arguments.first(where: { $0.hasPrefix("--open-settings") }) {
    let parts = flag.split(separator: "=", maxSplits: 1)
    SettingsWindowController.initialTab = parts.count == 2 ? String(parts[1]) : nil
    DispatchQueue.main.async {
        controller.openSettingsForTesting()
        // stdout is buffered and the harness kills this process, so the line
        // would never be flushed; stderr is unbuffered.
        FileHandle.standardError.write(Data(String(
            format: "settings window ready %.0f ms after launch\n",
            Date().timeIntervalSince(launchedAt) * 1000).utf8))
    }
}
application.run()

// MARK: - CLI dump

func runSMCDump() {
    let smc: SMC
    do {
        smc = try SMC()
    } catch {
        FileHandle.standardError.write(Data("Failed to open SMC: \(error)\n".utf8))
        exit(1)
    }

    do {
        let count = try smc.keyCount()
        print("SMC reports \(count) keys.\n")
    } catch {
        print("Could not read #KEY: \(error)")
    }

    guard let keys = try? smc.allKeys() else {
        print("Could not enumerate keys.")
        return
    }

    // Temperatures: keys beginning with "T".
    print("=== Temperatures (T*) ===")
    for key in keys.sorted() where key.hasPrefix("T") {
        guard let value = try? smc.read(key), let celsius = value.double else { continue }
        // Plausible on-die temp range; filters out unrelated T* keys.
        if celsius > 0, celsius < 130 {
            print(String(format: "  %@ [%@]  %.1f °C", key, value.type, celsius))
        }
    }

    // Fans: print every enumerated key beginning with "F".
    print("\n=== Fan keys (F*) ===")
    for key in keys.sorted() where key.hasPrefix("F") {
        guard let v = try? smc.read(key) else { continue }
        if let d = v.double {
            print(String(format: "  %@ [%@]  %.2f", key, v.type, d))
        } else {
            let hex = v.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            print("  \(key) [\(v.type)]  raw: \(hex)")
        }
    }
}

// MARK: - Fan read / write test

func runFanTest(write: Bool) {
    guard let smc = try? SMC() else {
        FileHandle.standardError.write(Data("Failed to open SMC\n".utf8))
        exit(1)
    }

    let sensors = SensorReader(smc: smc)
    let fans = FanController(smc: smc)

    if let hot = sensors.hottest() {
        print("Hottest: \(hot.label) \(String(format: "%.1f", hot.celsius)) °C")
    }

    print("\nDetected \(fans.fanCount) fan(s):")
    for fan in fans.readFans() {
        print(String(format: "  Fan %d: %d RPM (min %d, max %d, target %d) — %@",
                     fan.index, fan.actualRPM, fan.minRPM, fan.maxRPM, fan.targetRPM,
                     fan.isManual ? "MANUAL" : "auto"))
    }

    guard write else {
        print("\n(read-only; pass --write to test the manual/auto round-trip)")
        return
    }

    guard let before = fans.readFan(0) else { print("No fan 0"); return }
    let target = min(before.minRPM + 1000, before.maxRPM)
    print("\n--- Holding fan 0 manual @ \(target) RPM for ~5s (re-asserting), then auto ---")

    for i in 0..<10 {
        do {
            try fans.setManual(fan: 0, rpm: target)
        } catch {
            print("Write failed: \(error)")
            try? fans.setAuto(fan: 0)
            return
        }
        usleep(500_000) // 0.5s
        if let f = fans.readFan(0) {
            print(String(format: "  [%2d] mode=%@  Ac=%d RPM  Tg=%d",
                         i, f.isManual ? "MANUAL" : "auto  ", f.actualRPM, f.targetRPM))
        }
    }

    try? fans.setAuto(fan: 0)
    usleep(500_000)
    let after = fans.readFan(0)
    print("After setAuto: mode=\(after?.isManual == false ? "auto ✅" : "MANUAL ❌"), Ac=\(after?.actualRPM ?? -1) RPM")
}

// MARK: - Helper (XPC) test

func runHelperTest() {
    let client = HelperClient.shared
    guard let version = client.version(timeout: 5) else {
        print("❌ Helper not reachable. Install it: sudo ./scripts/install-helper.sh")
        exit(1)
    }
    print("✅ Helper reachable, version \(version)")

    print("Forcing fan 0 to 2800 RPM via helper for ~4s...")
    client.setFanManual(fan: 0, rpm: 2800)

    guard let smc = try? SMC() else { return }
    let fans = FanController(smc: smc)
    for i in 0..<8 {
        usleep(500_000)
        if let f = fans.readFan(0) {
            print(String(format: "  [%d] mode=%@ Ac=%d Tg=%d",
                         i, f.isManual ? "MANUAL" : "auto", f.actualRPM, f.targetRPM))
        }
    }

    print("Restoring auto...")
    client.setAllFansAuto()
    usleep(800_000)
    if let f = fans.readFan(0) {
        print("Final: mode=\(f.isManual ? "MANUAL ❌" : "auto ✅") Ac=\(f.actualRPM)")
    }
}

// MARK: - GPU test

func runGPUTest() {
    let gpu = GPUController()
    print("Dual-GPU: \(gpu.isDualGPU)")
    print("  Integrated: \(gpu.integratedName ?? "—")")
    print("  Discrete:   \(gpu.discreteName ?? "—")")
    let info = gpu.info()
    print("  Policy (gpuswitch): \(info.mode.map { "\($0.rawValue) (\($0.label))" } ?? "unknown")")
    print("  Currently active:   \(info.activeName ?? "—")\(info.activeIsLowPower == true ? " [integrated]" : info.activeIsLowPower == false ? " [discrete]" : "")")
}


// MARK: - Pointer diagnostics

func runPointerTest(write: Bool) {
    let acceleration = PointerAcceleration()
    guard acceleration.isAvailable else {
        print("PointerAcceleration: could not resolve the IOKit symbols")
        return
    }
    print("PointerAcceleration: ready")
    print("Accessibility trusted: \(ScrollInterceptor.isPermitted)")
    let probe = ScrollInterceptor()
    print("event tap can be created: \(probe.start())")
    probe.stop()
    let devices = acceleration.devices()
    print("devices: \(devices.count)")
    for device in devices {
        print(String(format: "  %@ — %@ = %d (%.4f)", device.name, device.key, device.value, device.multiplier))
    }
    print("identity candidates:")
    for key in ["RegistryID", "LocationID", "VendorID", "ProductID", "SerialNumber", "Transport", "DeviceUsagePairs"] {
        print("  \(key): \(acceleration.probe(key) ?? "—")")
    }
    print("stored originals: \(Preferences.pointerOriginals)")
    guard write else { return }
    print("applying 0 …")
    acceleration.apply { _ in 0 }
    for device in acceleration.devices() {
        print(String(format: "  now %@ = %d", device.key, device.value))
    }
    print("stored originals: \(Preferences.pointerOriginals)")
    print("restoring …")
    acceleration.restore()
    for device in acceleration.devices() {
        print(String(format: "  back %@ = %d", device.key, device.value))
    }
}


// MARK: - Keyboard diagnostics

func runKeyboardTest(write: Bool) {
    let remapper = KeyRemapper()
    guard remapper.isAvailable else {
        print("KeyRemapper: could not resolve the HID interfaces")
        return
    }
    print("keyboards: \(remapper.keyboards().map { "\($0.name) [\($0.identity)]" }.joined(separator: ", "))")
    func show(_ label: String) {
        for device in remapper.keyboards() {
            let live = remapper.liveMappings(for: device.identity)
            let text = live.isEmpty ? "none" : live.map {
                "\(KeyRemapper.name(forUsage: $0.source)) -> \(KeyRemapper.name(forUsage: $0.destination))"
            }.joined(separator: ", ")
            print("  \(label) — \(device.name): \(text)")
        }
    }
    func showFirst(_ label: String) {
        let live = remapper.liveMappings()
        let text = live.isEmpty ? "none" : live.map {
            "\(KeyRemapper.name(forUsage: $0.source)) -> \(KeyRemapper.name(forUsage: $0.destination))"
        }.joined(separator: ", ")
        print("  \(label): \(text)")
    }
    show("before")
    guard write else { return }
    var store = DeviceScopedStore<[KeyRemapper.Mapping]>(defaults: [
        KeyRemapper.Mapping(source: 0x39, destination: 0x29)
    ])
    if CommandLine.arguments.contains("--first-only"), let first = remapper.keyboards().first {
        // Proves the per-device path: only this one keyboard is remapped.
        store = DeviceScopedStore<[KeyRemapper.Mapping]>(defaults: [])
        store[first.identity] = [KeyRemapper.Mapping(source: 0x39, destination: 0x29)]
        print("  scoping the swap to \(first.name)")
    }
    remapper.apply(store)
    show("after applying Caps Lock -> Escape")
    print("  applied flag: \(Preferences.keyboardMappingApplied)")
    if CommandLine.arguments.contains("--leave") {
        print("  leaving it applied, as asked")
        return
    }
    remapper.clear()
    show("after clearing")
    print("  applied flag: \(Preferences.keyboardMappingApplied)")
}


// MARK: - Profiles diagnostics

func runProfilesTest() {
    let telemetry = Telemetry()
    telemetry.start()
    // One tick so the battery and temperature have been read at least once.
    RunLoop.current.run(until: Date().addingTimeInterval(2.5))
    let context = Context.sample(telemetry: telemetry)
    print("context now:")
    print("  on external power: \(context.onExternalPower)")
    print("  battery: \(context.batteryPercent.map { "\($0) %" } ?? "unknown")")
    if let draw = telemetry.battery?.power {
        print("    system: \(draw.systemWatts.map { String(format: "%.2f W", $0) } ?? "—")")
        print("    adapter: \(draw.adapterWatts.map { String(format: "%.2f W", $0) } ?? "—")")
        print("    battery: \(draw.batteryWatts.map { String(format: "%+.2f W", $0) } ?? "—")")
    }
    print("    on charger: \(telemetry.battery?.isPluggedIn ?? false), charging: \(telemetry.battery?.isCharging ?? false)")
    print("  external displays: \(context.externalDisplayCount)")
    print("  wi-fi: \(context.wifiSSID ?? "unknown (needs Location permission)")")
    print("  clock: \(Condition.clock(context.minutesSinceMidnight))")
    print("  cpu: \(context.cpuCelsius.map { String(format: "%.0f °C", $0) } ?? "unknown")")
    print("  apps running: \(context.runningApps.count)")

    let samples: [Condition] = [
        .onExternalPower(true), .onExternalPower(false),
        .batteryBelow(30), .externalDisplayAttached(true), .externalDisplayAttached(false),
        .cpuHotterThan(50), .cpuHotterThan(95),
        .timeBetween(startMinutes: 0, endMinutes: 24 * 60 - 1),
        .appRunning("Finder"), .appRunning("NoSuchApplication"),
    ]
    print("\nconditions against it:")
    for condition in samples {
        print("  \(condition.holds(in: context) ? "yes" : "no ") — \(condition.label)")
    }

    let profile = Profile(name: "Desk", requiresAll: true,
                          conditions: [.onExternalPower(true), .appRunning("Finder")],
                          actions: [.turboDisabled(false)])
    print("\nprofile \"\(profile.name)\" matches: \(profile.matches(context))")
}


// MARK: - Where the time goes

func runTimingTest() {
    func time(_ label: String, _ body: () -> Void) {
        let start = Date()
        body()
        print(String(format: "  %6.0f ms  %@", Date().timeIntervalSince(start) * 1000, label))
    }
    print("one-off cost of each thing the settings window touches:")
    let smc = try? SMC()
    if let smc = smc {
        let sensors = SensorReader(smc: smc)
        let fans = FanController(smc: smc)
        time("SensorReader.readTemperatures") { _ = sensors.readTemperatures() }
        time("FanController.readFans") { _ = fans.readFans() }
    }
    let battery = BatteryReader()
    time("BatteryReader.read") { _ = battery.read() }
    let thermal = ThermalMonitor()
    time("ThermalMonitor.read") { _ = thermal.read() }
    let gpu = GPUController()
    time("GPUController.info (runs pmset)") { _ = gpu.info() }
    let turbo = TurboBoostController()
    time("TurboBoost.isTurboDisabled (runs kextstat)") { _ = turbo.isTurboDisabled() }
    let display = DisplayControl()
    time("DisplayControl.screens") { _ = display.screens() }
    time("DisplayControl.modes for main display") { _ = display.modes(for: CGMainDisplayID()) }
    let remapper = KeyRemapper()
    time("KeyRemapper.keyboards") { _ = remapper.keyboards() }
    let pointer = PointerAcceleration()
    time("PointerAcceleration.devices") { _ = pointer.devices() }
    let helper = HelperClient()
    time("HelperClient.version (XPC round trip)") { _ = helper.version() }
    time("PowerLimits.current (sysctl)") { _ = PowerLimits.current() }
}


// MARK: - What identifies the device that sent an event


// MARK: - Icon rendering, to a file rather than the menu bar

/// Renders the battery at the states that matter and writes them out, so the
/// drawing can be looked at without putting it in the menu bar and taking a
/// picture of somebody's screen.
func runIconDump() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zephyr-icons")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // Roles are forced rather than taken from the machine's current state:
    // this Mac is in Low Power Mode, which would paint every row yellow and
    // hide whether the other three colours are right at all.
    let cases: [(String, Int, Bool, Bool, MenuBarComposer.FillRole?)] = [
        ("100 neutral", 100, false, true, .neutral),
        ("75 neutral", 75, false, false, .neutral),
        ("50 neutral", 50, false, false, .neutral),
        ("20 critical", 20, false, false, .critical),
        ("5 critical", 5, false, false, .critical),
        ("60 low power", 60, false, false, .lowPower),
        ("60 charging", 60, true, true, .charging),
    ]
    for (name, percent, charging, plugged, role) in cases {
        MenuBarComposer.forcedFillRole = role
        let status = BatteryStatus(percent: percent, isCharging: charging, isPluggedIn: plugged,
                                   healthPercent: 82, cycleCount: 393, power: nil)
        for withNumber in [false, true] {
            guard let image = MenuBarComposer.batteryImage(status, showingPercentage: withNumber),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let file = directory.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "-"))\(withNumber ? "-pct" : "").png")
            try? png.write(to: file)
        }
    }
    // One sheet, on a dark ground like the menu bar, so template images are
    // visible at all: on their own they are an alpha mask and read as blank.
    let scale: CGFloat = 4
    let rowHeight: CGFloat = 26
    let sheetSize = NSSize(width: 420, height: rowHeight * CGFloat(cases.count) + 12)
    let sheet = NSImage(size: sheetSize)
    sheet.lockFocus()
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    NSRect(origin: .zero, size: sheetSize).fill()

    for (index, entry) in cases.enumerated() {
        let (name, percent, charging, plugged, role) = entry
        MenuBarComposer.forcedFillRole = role
        let status = BatteryStatus(percent: percent, isCharging: charging, isPluggedIn: plugged,
                                   healthPercent: 82, cycleCount: 393, power: nil)
        let y = sheetSize.height - CGFloat(index + 1) * rowHeight
        (name as NSString).draw(at: NSPoint(x: 8, y: y + 6), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.black,
        ])
        var x: CGFloat = 110
        for withNumber in [false, true] {
            guard let icon = MenuBarComposer.batteryImage(status, showingPercentage: withNumber) else { continue }
            // Template images are masks; paint them white as the menu bar would.
            // Drawn as-is. A template image renders as its black mask, which
            // is visible on a light ground — trying to repaint it here was
            // what turned the whole sheet into white blocks.
            let target = NSRect(x: x, y: y + 4, width: icon.size.width * 1.6, height: icon.size.height * 1.6)
            icon.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
            x += target.width + 24
        }
    }
    MenuBarComposer.forcedFillRole = nil
    sheet.unlockFocus()
    if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: directory.appendingPathComponent("sheet.png"))
    }
    _ = scale
    print(directory.path)
}
