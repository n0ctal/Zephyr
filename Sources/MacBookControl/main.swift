import Foundation
import AppKit

// Entry point. A hidden `--dump-smc` flag runs a one-shot CLI sensor dump
// (handy for debugging and for open-source users); otherwise the menu-bar
// app launches.
let arguments = CommandLine.arguments

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

if arguments.contains("--test-keyboard") {
    runKeyboardTest(write: arguments.contains("--write"))
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
    DispatchQueue.main.async { controller.openSettingsForTesting() }
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
    acceleration.apply(multiplier: 0)
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
    print("keyboards: \(remapper.keyboards().joined(separator: ", "))")
    func show(_ label: String) {
        let live = remapper.liveMappings()
        let text = live.isEmpty ? "none" : live.map {
            "\(KeyRemapper.name(forUsage: $0.source)) -> \(KeyRemapper.name(forUsage: $0.destination))"
        }.joined(separator: ", ")
        print("  \(label): \(text)")
    }
    show("before")
    guard write else { return }
    remapper.apply([KeyRemapper.Mapping(source: 0x39, destination: 0x29)])
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
