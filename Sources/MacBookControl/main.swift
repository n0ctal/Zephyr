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

if arguments.contains("--test-network") {
    runNetworkTest()
    exit(0)
}

if arguments.contains("--test-virtual-display") {
    runVirtualDisplayTest()
    exit(0)
}

if arguments.contains("--test-windows") {
    runWindowTest()
    exit(0)
}

if arguments.contains("--test-diagnostics") {
    runDiagnosticsTest()
    exit(0)
}

if arguments.contains("--test-gpu") {
    runGPUTest()
    exit(0)
}

if arguments.contains("--test-power-limit") {
    runPowerLimitTest(write: arguments.contains("--write"))
    exit(0)
}

if arguments.contains("--dump-icons") {
    runIconDump()
    exit(0)
}

if arguments.contains("--self-test") {
    exit(SelfTest.run())
}

if arguments.contains("--test-telemetry-race") {
    runTelemetryRaceTest()
    exit(0)
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

// The settings window runs as a process of its own — see AppController's note
// on `statusItem` for what a window costs the process that opens one — so this
// copy is a second instance on purpose and the guard below must let it through.
let isSettingsProcess = arguments.contains("--settings-window")
// Before anything is built: features read this as they come up.
ProcessRole.isSettingsWindow = isSettingsProcess

// Single-instance guard: if another copy (e.g. the login item) is already
// running, exit so we don't add a second menu-bar icon. (bundleIdentifier is
// nil for the bare dev binary, so this only applies to the .app.)
if !isSettingsProcess, let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0 != NSRunningApplication.current }
    if !others.isEmpty { exit(0) }
}

// Default: launch the menu-bar app (accessory = menu-bar only, no Dock icon).
// AppController sets up its status item in init() and is retained here.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = AppController(showsStatusItem: !isSettingsProcess)
_ = controller

// Nothing but the window, and nothing after it. Quitting is the point: the
// rendering stack cannot be unloaded, so the only way to give its memory back
// is for the process holding it to end.
if isSettingsProcess {
    SettingsWindowController.didClose = { exit(0) }
    DispatchQueue.main.async { controller.showSettingsWindow() }
}
// Dev affordance: the Settings window is only reachable by clicking the status
// item, which nothing automated can do — so a broken tab would only ever be
// found by hand. This opens it at launch so the build can prove it constructs.
if let index = arguments.firstIndex(of: "--dump-preview"), index + 1 < arguments.count {
    let path = arguments[index + 1]
    DispatchQueue.main.async {
        controller.dumpDesignPreview(to: path)
        exit(0)
    }
}

if let index = arguments.firstIndex(of: "--dump-window"), index + 1 < arguments.count {
    let path = arguments[index + 1]
    DispatchQueue.main.async {
        controller.dumpWindowLayouts(to: path,
                                     dark: arguments.contains("--dark")
                                         || arguments.contains("--darkness"),
                                     pitch: arguments.contains("--darkness"))
        exit(0)
    }
}

// Reproduces what closing a popover used to do to the settings process.
if arguments.contains("--test-settings-lifetime") {
    var closed = 0
    SettingsWindowController.didClose = { closed += 1 }
    DispatchQueue.main.async {
        controller.showSettingsWindow()
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        // Something else AppKit put up: a popover, a menu, the panel that
        // comes with adding a virtual screen. Closing it must mean nothing.
        let stranger = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 100, height: 100),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        stranger.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        stranger.close()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print(closed == 0
              ? "  ok: another window closing is not the settings window closing"
              : "  FAILED: the settings window reported itself closed \(closed) times")

        controller.closeSettingsWindowForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print(closed == 1
              ? "  ok: and closing the settings window does report it, once"
              : "  FAILED: closing the settings window reported \(closed) times")
        exit(closed == 1 ? 0 : 1)
    }
}

if arguments.contains("--test-window-memory") {
    SettingsWindowController.releasesOnClose = !arguments.contains("--keep-window")
    print("what the settings window costs, and what closing it gives back"
          + (arguments.contains("--keep-window") ? " (holding it)" : " (releasing it)") + ":")
    DispatchQueue.main.async {
        controller.reportWindowMemory()
        exit(0)
    }
}

if let index = arguments.firstIndex(of: "--dump-real-window"), index + 1 < arguments.count {
    let path = arguments[index + 1]
    let layout = arguments.first { $0.hasPrefix("--layout=") }
        .flatMap { WindowLayout(rawValue: String($0.dropFirst("--layout=".count))) }
        ?? .terminal
    let strip = arguments.first { $0.hasPrefix("--strip=") }
        .flatMap { Double(String($0.dropFirst("--strip=".count))) }
        .map { CGFloat($0) } ?? 170
    DispatchQueue.main.async {
        controller.dumpRealWindow(to: path, layout: layout, strip: strip)
        exit(0)
    }
}

if arguments.contains("--measure-sections") {
    let width = arguments.first { $0.hasPrefix("--width=") }
        .flatMap { Double(String($0.dropFirst("--width=".count))) }.map { CGFloat($0) } ?? 960
    DispatchQueue.main.async {
        controller.measureSections(width: width)
        exit(0)
    }
}

if arguments.contains("--preview-design") {
    DispatchQueue.main.async {
        controller.openDesignPreview()
        FileHandle.standardError.write(Data("design preview open\n".utf8))
    }
}

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
    var dormant: [(String, String, Double)] = []
    for key in keys.sorted() where key.hasPrefix("T") {
        guard let value = try? smc.read(key), let celsius = value.double else { continue }
        // Plausible on-die temp range; filters out unrelated T* keys.
        if celsius > 0, celsius < 130 {
            print(String(format: "  %@ [%@]  %.1f °C", key, value.type, celsius))
        } else {
            dormant.append((key, value.type, celsius))
        }
    }

    // The ones outside that range, listed rather than hidden. A sensor whose
    // part is powered down reads zero, and someone asking "why is there no
    // GPU temperature" needs to see that the key exists and is asleep, not an
    // empty space where it would have been.
    print("\n=== Temperatures asleep or out of range ===")
    if dormant.isEmpty {
        print("  (none)")
    } else {
        for (key, type, celsius) in dormant {
            print(String(format: "  %@ [%@]  %.1f", key, type, celsius))
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

/// Proves the throughput reader against the machine's real interfaces.
///
/// A rate cannot be checked by a unit test — the arithmetic can, and is, but
/// whether the counters are the right ones and move at all is a question only
/// the hardware answers.
func runNetworkTest() {
    let reader = NetworkThroughput()
    print("first read (nothing to subtract from): \(reader.read() == nil ? "nil, as it should be" : "a number, which is wrong")")
    for _ in 0..<4 {
        Thread.sleep(forTimeInterval: 2)
        guard let now = reader.read() else { print("  no reading"); continue }
        print(String(format: "  ↓ %-10s ↑ %-10s  (%.0f / %.0f bytes per second)",
                     (NetworkThroughput.format(now.downloadBytes) as NSString).utf8String!,
                     (NetworkThroughput.format(now.uploadBytes) as NSString).utf8String!,
                     now.downloadBytes, now.uploadBytes))
    }
}

/// Proves that the window arrangement can be read at all.
///
/// It is the accessibility interface, so the answer is either "several dozen
/// windows" or "no permission" — and which one it is cannot be guessed from
/// the code.
func runWindowTest() {
    guard WindowArrangement.isPermitted else {
        print("no Accessibility permission — windows cannot be read or moved")
        return
    }
    let placements = WindowArrangement.capture()
    print("windows visible: \(placements.count)")
    for placement in placements.prefix(8) {
        print(String(format: "   pid %d  %@  %.0f,%.0f %.0f×%.0f",
                     placement.pid,
                     (placement.title.isEmpty ? "(untitled)" : placement.title) as NSString,
                     placement.frame.origin.x, placement.frame.origin.y,
                     placement.frame.width, placement.frame.height))
    }
    // Restoring what was just captured moves nothing: every window already
    // sits where it belongs, which is also the check that the write path
    // matches the read path.
    print("moved by a restore of the current arrangement: \(WindowArrangement.restore(placements))")
}

/// Proves the read-only diagnostics against the real machine.
///
/// Each of these is a registry read with no privileges behind it, so the only
/// way any of them can fail is a machine that does not publish the data — and
/// that is exactly what this says.
func runDiagnosticsTest() {
    if let drive = DriveHealth.read() {
        print("drive: \(drive.model), wear \(drive.percentageUsed) %, "
              + "written \(drive.bytesWritten / 1_000_000_000_000) TB, "
              + "\(drive.powerOnHours) h, \(drive.unsafeShutdowns) unsafe shutdowns, "
              + "\(drive.mediaErrors) media errors, healthy: \(drive.isHealthy)")
    } else {
        print("drive: no health page")
    }
    let assertions = SleepDiagnostics.assertions()
    print("sleep: \(assertions.count) blocking assertion(s)")
    for assertion in assertions.prefix(5) {
        print("   \(assertion.process) — \(assertion.effect) — \(assertion.name)")
    }
    let record = SleepDiagnostics.powerRecord()
    print("wake: \(record.wakeReason ?? "—") / \(record.wakeType ?? "—")")
    print("slept because: \(record.sleepReason ?? "—")")
    print("last shutdown: \(record.shutdownDescription ?? "—")")
    // A rate needs two samples, so this one is asked twice.
    _ = ProcessLoad.shared.read()
    Thread.sleep(forTimeInterval: 1.5)
    if let busiest = ProcessLoad.shared.read(top: 4) {
        print("busiest by cpu:    "
              + busiest.byCPU.map { String(format: "%@ %.0f%%", $0.name, $0.cpu) }
                  .joined(separator: ", "))
        print("busiest by memory: "
              + busiest.byMemory.map { "\($0.name) \($0.memoryBytes / 1_048_576) MB" }
                  .joined(separator: ", "))
    }
    let holders = AcceleratorClients.discreteHolders()
    print("discrete card held by \(holders.count): "
          + holders.prefix(6).map(\.name).joined(separator: ", "))
}

func runGPUTest() {
    let gpu = GPUController()
    print("Dual-GPU: \(gpu.isDualGPU)")
    print("  Integrated: \(gpu.integratedName ?? "—")")
    print("  Discrete:   \(gpu.discreteName ?? "—")")
    // Asking for the active card as well. Without this the line below can
    // never be filled, and the probe printed a dash where its most useful
    // answer goes. It is read through CGDirectDisplayCopyCurrentMetalDevice,
    // which reports the card driving the display rather than creating a
    // system-default device — the latter answers "AMD" on this machine and
    // wakes it to do so.
    let info = gpu.info(includeActive: true)
    print("  Policy (gpuswitch): \(info.mode.map { "\($0.rawValue) (\($0.label))" } ?? "unknown")")
    print("  Currently active:   \(info.activeName ?? "—")\(info.activeIsLowPower == true ? " [integrated]" : info.activeIsLowPower == false ? " [discrete]" : "")")
    // And who is keeping the discrete card awake, which is the question the
    // policy alone cannot answer: on this machine the policy reads "integrated
    // only" while four processes hold a command queue on the other card.
    let holders = AcceleratorClients.discreteHolders()
    print("  Discrete held by:   " + (holders.isEmpty
        ? "nobody"
        : holders.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")))
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
    // Which half came up empty, when it does: what matched, and what each
    // match publishes. Without this the count above is a dead end.
    let matched = acceleration.matchedServices()
    print("matched services: \(matched.count)")
    for service in matched {
        print("  \(service.name) — curve \(service.curve ?? "(none published)")"
              + " = \(service.value.map(String.init) ?? "unreadable")"
              + " (raw: \(service.raw ?? "absent"))")
    }
    for device in devices {
        print(String(format: "  %@ — %@ = %d (%.4f)", device.name, device.key, device.value, device.multiplier))
        // The identity is what every per-device setting is filed under, so it
        // is the thing to compare when checking that some other view of the
        // same hardware agrees about which device it is.
        print("      identity: \(device.identity)")
    }
    print("identity candidates:")
    for key in ["RegistryID", "LocationID", "VendorID", "ProductID", "SerialNumber", "Transport", "DeviceUsagePairs"] {
        print("  \(key): \(acceleration.probe(key) ?? "—")")
    }
    // The other place a curve can live: on the event driver rather than the
    // service. A device missing from the list above may still be here.
    let registry = acceleration.registryCurves()
    print("curves in the registry: \(registry.count)")
    for row in registry {
        print(String(format: "  %@ — %@ = %d (%.4f)", row.entry, row.key,
                     row.value, Double(row.value) / 65536))
    }
    print("stored originals: \(Preferences.pointerOriginals)")
    guard write else { return }
    // Does a write reach a service at all? `accepted` alone cannot say — the
    // call returns true for a value the device already had, which is
    // indistinguishable from doing nothing. So write a different one and look
    // in the registry, then put it back. A thousand out of 65536 is under two
    // percent, which the hand cannot feel and the registry states plainly.
    func curveValues(_ key: String) -> Set<Int> {
        Set(acceleration.registryCurves().filter { $0.key == key }.map(\.value))
    }
    if let key = matched.first?.curve, let original = curveValues(key).first {
        print("write test on \(key): registry holds \(curveValues(key).sorted())")
        let accepted = acceleration.probeWrite(original + 1000).map(\.accepted)
        print("  wrote \(original + 1000), accepted=\(accepted)")
        let during = curveValues(key).sorted()
        print("  registry now \(during)")
        _ = acceleration.probeWrite(original)
        print("  restored to \(original); registry now \(curveValues(key).sorted())")
        print(during.contains(original + 1000)
              ? "  VERDICT: the write lands — the trackpad can be driven this way"
              : "  VERDICT: accepted but ignored — the write does not reach the device")
    }
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
    // As if a window were open, so everything is read. With it shut, telemetry
    // reads only what the menu bar and the enabled profiles ask for — and this
    // probe has neither, which left the CPU load unknown and the condition
    // that depends on it untestable here.
    telemetry.isWindowOpen = true
    // Two ticks: the load and the network speed are rates, and the first
    // reading of a rate has nothing to subtract from.
    RunLoop.current.run(until: Date().addingTimeInterval(4.5))
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
    // Which sensor, not only which number: two of this machine's CPU keys read
    // twenty degrees apart, so a temperature on its own says very little.
    let cpuReading = telemetry.cpuTemperature
    print("  cpu: \(context.cpuCelsius.map { String(format: "%.1f °C", $0) } ?? "unknown")"
          + (cpuReading.map { " (\($0.key) — \($0.label))" } ?? ""))
    print("  cpu load: \(context.cpuLoadPercent.map { String(format: "%.0f %%", $0) } ?? "unknown")")
    print("  cpu clock: \(telemetry.load?.cpuHertz.map { String(format: "%.2f GHz", $0 / 1e9) } ?? "unknown")")
    if let load = telemetry.load {
        print(String(format: "  memory: %.2f of %.2f GB used",
                     Double(load.memoryUsed) / 1e9, Double(load.memoryTotal) / 1e9))
        if let disk = load.disk {
            print(String(format: "  disk: %.1f of %.1f GB used",
                         Double(disk.usedBytes) / 1e9, Double(disk.totalBytes) / 1e9))
        }
    }
    print("  apps running: \(context.runningApps.count)")

    let samples: [Condition] = [
        .onExternalPower(true), .onExternalPower(false),
        .batteryBelow(30), .externalDisplayAttached(true), .externalDisplayAttached(false),
        .cpuHotterThan(50), .cpuHotterThan(95),
        .cpuLoadAbove(20), .cpuLoadAbove(90),
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

/// Drives the two paths that read the hardware into each other on purpose.
///
/// A window opening calls retune() on the main thread, which reads everything
/// there and then; a tick is meanwhile reading the same devices on the
/// telemetry queue. Build with `-Xswiftc -sanitize=thread` and run this: a
/// clean run means the reads are serialised, and anything else means they are
/// not. It is here rather than in the self-test because it proves nothing
/// without the sanitizer.
func runTelemetryRaceTest() {
    let telemetry = Telemetry()
    telemetry.start()
    let deadline = Date().addingTimeInterval(4)
    var rounds = 0
    while Date() < deadline {
        telemetry.isWindowOpen = true    // dispatches a read onto the queue
        telemetry.stop()
        telemetry.start()                // and reads again, here, on this thread
        telemetry.isWindowOpen = false
        rounds += 1
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    telemetry.stop()
    print("telemetry race probe: \(rounds) rounds; the verdict is the sanitizer's")
}

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
        // What every tick after the first one costs: the SMC is asked each
        // key's size and type once and remembers the answers.
        time("SensorReader.readTemperatures (again)") { _ = sensors.readTemperatures() }
        time("FanController.readFans") { _ = fans.readFans() }
        time("FanController.readFans (again)") { _ = fans.readFans() }
    }
    let battery = BatteryReader(smc: smc)
    time("BatteryReader.read") { _ = battery.read() }
    // The same reading with and without a connection of its own. Opening one
    // per reading is what this used to do, twice a second, for ever.
    if let smc = smc {
        func mean(_ reader: BatteryReader, inDetail: Bool = true) -> Double {
            _ = reader.read(inDetail: inDetail)   // warm
            var total: TimeInterval = 0
            for _ in 0 ..< 50 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = reader.read(inDetail: inDetail)
                total += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            }
            return total / 50 * 1000
        }
        print(String(format: "  %6.2f ms  BatteryReader.read in detail, shared connection (mean of 50)",
                     mean(BatteryReader(smc: smc))))
        // What a menu bar with a battery icon in it actually asks for, once a
        // second, for as long as the app is open.
        print(String(format: "  %6.2f ms  BatteryReader.read, charge only (mean of 50)",
                     mean(BatteryReader(smc: smc), inDetail: false)))
        print(String(format: "  %6.2f ms  BatteryReader.read in detail, opening its own (mean of 50)",
                     mean(BatteryReader())))
    }
    // Asked from a view body, so SwiftUI pays it again on every redraw — and
    // a redraw happens on every telemetry tick while the window is open.
    do {
        _ = BatteryLimit.isSupported()
        var total: TimeInterval = 0
        for _ in 0 ..< 20 {
            let start = Date()
            _ = BatteryLimit.isSupported()
            total += Date().timeIntervalSince(start)
        }
        print(String(format: "  %6.2f ms  BatteryLimit.isSupported (mean of 20, answers %@)",
                     total / 20 * 1000, BatteryLimit.isSupported() ? "yes" : "no"))
    }
    let thermal = ThermalMonitor()
    // A mean rather than a single go: this one is never skipped, so it is paid
    // on every tick whatever the window is doing.
    do {
        _ = thermal.read()   // warm
        var total: TimeInterval = 0
        for _ in 0 ..< 20 {
            let start = Date()
            _ = thermal.read()
            total += Date().timeIntervalSince(start)
        }
        print(String(format: "  %6.1f ms  ThermalMonitor.read (mean of 20)", total / 20 * 1000))
    }
    let gpu = GPUController()
    time("GPUController.info (plist; pmset only as fallback)") { _ = gpu.info() }
    let turbo = TurboBoostController()
    time("TurboBoost.isTurboDisabled (runs kextstat)") { _ = turbo.isTurboDisabled() }
    let display = DisplayControl()
    time("DisplayControl.screens") { _ = display.screens() }
    // The Display tab re-enumerates every five seconds on the main thread, so
    // what a repeat costs is the figure that matters, not the first one.
    do {
        var total: TimeInterval = 0
        for _ in 0 ..< 10 {
            let start = Date()
            _ = display.screens()
            total += Date().timeIntervalSince(start)
        }
        print(String(format: "  %6.1f ms  DisplayControl.screens (mean of 10 more)", total / 10 * 1000))
    }
    time("DisplayControl.modes for main display") { _ = display.modes(for: CGMainDisplayID()) }
    let remapper = KeyRemapper()
    time("KeyRemapper.keyboards") { _ = remapper.keyboards() }
    let pointer = PointerAcceleration()
    time("PointerAcceleration.devices") { _ = pointer.devices() }
    let helper = HelperClient()
    time("HelperClient.version (XPC round trip)") { _ = helper.version() }
    time("PowerLimits.current (sysctl)") { _ = PowerLimits.current() }

    // The other half of a tick. Reading the machine is only part of what
    // happens every two seconds; the menu bar is redrawn as one image, and an
    // idle cost that is not in this list is a cost nobody will find.
    print("\nand what the menu bar costs, per tick:")
    let telemetry = Telemetry()
    telemetry.start()
    // Warm: the first draw pays for fonts and colour spaces, which happens
    // once at launch and would otherwise be reported as the per-tick price.
    _ = MenuBarComposer.compose(telemetry: telemetry, darkMenuBar: true)

    /// Microseconds, because the interesting half is now well under a
    /// millisecond and a figure that reads "0.0 ms" hides whether the work
    /// went away or merely got smaller.
    func micros(_ runs: Int, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<runs { body() }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(runs) / 1000
    }
    let runs = 200
    let planning = micros(runs) { _ = MenuBarComposer.plan(telemetry: telemetry, darkMenuBar: true) }
    let plan = MenuBarComposer.plan(telemetry: telemetry, darkMenuBar: true)
    let drawing = micros(runs) { _ = MenuBarComposer.draw(plan) }
    telemetry.stop()
    // The two are not halves of one number: planning happens on every tick and
    // drawing only when the plan says the line has changed, which on an idle
    // machine is a small fraction of them.
    print(String(format: "  %6.1f us  MenuBarComposer.plan  (every tick, mean of %d)", planning, runs))
    print(String(format: "  %6.1f us  MenuBarComposer.draw  (only when it changed)", drawing))
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
        ("100 on mains", 100, false, true, .neutral),
        ("75 on battery", 75, false, false, .neutral),
        // The pair the bolt exists for: the same charge and the same colour,
        // differing only in whether the charger is in.
        ("80 on battery", 80, false, false, .neutral),
        ("80 on mains, full", 80, false, true, .neutral),
        ("50 neutral", 50, false, false, .neutral),
        ("20 critical", 20, false, false, .critical),
        ("5 critical", 5, false, false, .critical),
        ("60 low power", 60, false, false, .lowPower),
        ("60 charging", 60, true, true, .charging),
    ]
    for (name, percent, charging, plugged, role) in cases {
        MenuBarComposer.forcedFillRole = role
        let status = BatteryStatus(percent: percent, isCharging: charging, isPluggedIn: plugged,
                                   healthPercent: 82, cycleCount: 393,
                                   power: nil, minutesRemaining: nil)
        for withNumber in [false, true] {
            guard let image = MenuBarComposer.batteryImage(status, showingPercentage: withNumber,
                                                          darkMenuBar: false),
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
    let sheetSize = NSSize(width: 620, height: rowHeight * CGFloat(cases.count + 6) + 40)
    let sheet = NSImage(size: sheetSize)
    sheet.lockFocus()
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    NSRect(origin: .zero, size: sheetSize).fill()

    for (index, entry) in cases.enumerated() {
        let (name, percent, charging, plugged, role) = entry
        MenuBarComposer.forcedFillRole = role
        let status = BatteryStatus(percent: percent, isCharging: charging, isPluggedIn: plugged,
                                   healthPercent: 82, cycleCount: 393,
                                   power: nil, minutesRemaining: nil)
        let y = sheetSize.height - CGFloat(index + 1) * rowHeight
        (name as NSString).draw(at: NSPoint(x: 8, y: y + 6), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.black,
        ])
        var x: CGFloat = 110
        for withNumber in [false, true] {
            guard let icon = MenuBarComposer.batteryImage(status, showingPercentage: withNumber,
                                                          darkMenuBar: false) else { continue }
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

    // The load bars at a few loads, so "does this read as a graph or as dirt"
    // can be answered by looking rather than by putting it in a menu bar.
    let loads: [(String, [Double])] = [
        ("idle", Array(repeating: 0.02, count: 16)),
        ("light", (0..<16).map { $0 % 4 == 0 ? 0.35 : 0.05 }),
        ("busy", (0..<16).map { 0.2 + Double($0) / 20 }),
        ("full", Array(repeating: 0.98, count: 16)),
    ]
    var barY = sheetSize.height - CGFloat(cases.count) * rowHeight - 6
    for (name, values) in loads {
        barY -= rowHeight
        (name as NSString).draw(at: NSPoint(x: 8, y: barY + 6), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.black,
        ])
        if let bars = MenuBarComposer.threadBars(values, darkMenuBar: false) {
            bars.draw(in: NSRect(x: 110, y: barY + 3,
                                 width: bars.size.width * 1.6, height: bars.size.height * 1.6),
                      from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
    // The whole composed line, drawn against a dark ground like the real menu
    // bar, so spacing and order can be judged without photographing a screen.
    let telemetry = Telemetry()
    telemetry.start()
    RunLoop.current.run(until: Date().addingTimeInterval(2.5))
    let saved = Preferences.menuBarItems
    let savedCaptions = Preferences.captionedMenuBarItems
    let savedBattery = Preferences.batteryStyle
    let savedSpeed = Preferences.cpuSpeedStyle
    let savedLoad = Preferences.cpuLoadStyle
    let savedMemory = Preferences.memoryStyle
    Preferences.menuBarItems = [.battery, .temperature, .fan, .cpuSpeed, .cpuLoad, .memory]
    Preferences.batteryStyle = .iconAndPercent
    Preferences.cpuSpeedStyle = .frequency
    Preferences.cpuLoadStyle = .perThread
    Preferences.memoryStyle = .percent
    for captions in [false, true] {
        Preferences.captionedMenuBarItems = captions
            ? Set(MenuBarComposer.Item.allCases.map(\.rawValue)) : []
        let line = MenuBarComposer.compose(telemetry: telemetry, darkMenuBar: true)
        barY -= rowHeight + 4
        ((captions ? "with labels" : "plain") as NSString).draw(
            at: NSPoint(x: 8, y: barY + 6),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
        if let image = line.image {
            // The composed line on its own, which is what the status item is
            // actually handed — the sheet shows it on a black strip, and a
            // strip is no use for checking where the drawing sits inside it.
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent(
                    captions ? "line-with-labels.png" : "line-plain.png"))
            }
            let target = NSRect(x: 110, y: barY, width: image.size.width, height: image.size.height)
            NSColor.black.setFill()
            target.insetBy(dx: -4, dy: 0).fill()
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
    Preferences.menuBarItems = saved
    Preferences.captionedMenuBarItems = savedCaptions
    Preferences.batteryStyle = savedBattery
    Preferences.cpuSpeedStyle = savedSpeed
    Preferences.cpuLoadStyle = savedLoad
    Preferences.memoryStyle = savedMemory

    sheet.unlockFocus()
    if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: directory.appendingPathComponent("sheet.png"))
    }
    _ = scale
    print(directory.path)
}


// MARK: - Power limit diagnostics

func runPowerLimitTest(write: Bool) {
    guard let before = PowerLimits.current() else {
        print("sysctls absent — the kext is not loaded")
        return
    }
    func show(_ label: String, _ r: PowerLimits.Reading) {
        print(String(format: "  %@: PL1 %.1f W (on %@), PL2 %.1f W (on %@), locked %@, raw 0x%016llX",
                     label, r.pl1Watts, r.pl1Enabled ? "yes" : "no",
                     r.pl2Watts, r.pl2Enabled ? "yes" : "no",
                     r.isLocked ? "YES" : "no", r.raw))
    }
    show("before", before)
    guard write else { return }

    let targetPL1 = 60.0, targetPL2 = 75.0
    guard let composed = PowerLimits.composed(pl1Watts: targetPL1, pl2Watts: targetPL2) else {
        print("  compose refused — the register reads as locked")
        return
    }
    print(String(format: "  composed 0x%016llX for PL1 %.0f / PL2 %.0f", composed, targetPL1, targetPL2))

    let helper = HelperClient()
    print("  helper version: \(helper.version() ?? "unreachable")")
    helper.setPowerLimit(composed)
    _ = helper.version()   // flushes the asynchronous write

    Thread.sleep(forTimeInterval: 0.5)
    if let after = PowerLimits.current() { show("after", after) }
    Thread.sleep(forTimeInterval: 3)
    if let settled = PowerLimits.current() { show("3 s later", settled) }

    // Put it back however it went.
    if let restore = PowerLimits.composed(pl1Watts: before.pl1Watts, pl2Watts: before.pl2Watts) {
        helper.setPowerLimit(restore)
        _ = helper.version()
        Thread.sleep(forTimeInterval: 0.5)
        if let back = PowerLimits.current() { show("restored", back) }
    }
}
