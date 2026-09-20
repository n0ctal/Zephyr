import Foundation

/// Turns off the pointer acceleration curve, per device.
///
/// macOS scales pointer movement non-linearly: move the mouse twice as fast
/// and the cursor travels more than twice as far. It suits a trackpad and
/// fights anyone who wants the cursor to track the hand — which is why every
/// mouse utility on this platform ends up implementing this.
///
/// Each device names its own acceleration key in `HIDPointerAccelerationType`
/// — a trackpad answers `HIDTrackpadAcceleration`, a mouse
/// `HIDMouseAcceleration`. Guessing the key writes to the wrong one and
/// silently does nothing, so it is always read first.
final class PointerAcceleration {
    private let hid = HIDServiceBridge.shared

    var isAvailable: Bool { hid.isAvailable }

    /// The value each device had before we touched it.
    ///
    /// Persisted, not merely held in memory: a crash or a `kill` runs no
    /// cleanup, and the device keeps whatever was last written to it. Storing
    /// the originals means the next launch can put them back, so the worst
    /// case is an odd-feeling pointer until Zephyr starts again — not one that
    /// stays that way with nothing left that knows the old value.
    private var originals: [String: Int] {
        get { Preferences.pointerOriginals }
        set { Preferences.pointerOriginals = newValue }
    }

    struct Device {
        let identity: String
        let name: String
        let key: String
        let value: Int
        /// A trackpad names its curve `HIDTrackpadAcceleration`, a mouse
        /// `HIDMouseAcceleration`. The device says which it is, so nothing has
        /// to be guessed from the product name.
        var isTrackpad: Bool { key.localizedCaseInsensitiveContains("trackpad") }
        /// 1.0 is the shipped curve for that device; 0 is no acceleration.
        var multiplier: Double { Double(value) / 65536.0 }
    }

    /// Every attached pointing device that exposes an acceleration curve.
    func devices() -> [Device] {
        pointerServices().compactMap { service in
            guard let key = hid.string(service, "HIDPointerAccelerationType"),
                  let value = hid.int(service, key) else { return nil }
            return Device(identity: hid.identity(service), name: hid.name(service),
                          key: key, value: value)
        }
    }

    /// True when a previous run left devices altered and never put them back.
    var hasUnrestored: Bool { !originals.isEmpty }

    /// Applies `multiplier` to every pointing device, remembering what each
    /// one had first. Re-applying is cheap and expected: a mouse plugged in
    /// later arrives with the system curve and has to be caught.
    /// Applies a per-device multiplier. Returning nil for a device leaves it
    /// alone entirely — which is different from applying 1.0, because the
    /// shipped curve is not the same number on every device.
    func apply(_ multiplierFor: (String) -> Double?) {
        var captured = originals
        for service in pointerServices() {
            guard let key = hid.string(service, "HIDPointerAccelerationType") else { continue }
            let id = hid.identity(service)
            guard let multiplier = multiplierFor(id) else { continue }
            // Decided before anything is written down. Capturing first left a
            // record saying "we altered this device" for one that was then
            // skipped, so `hasUnrestored` reported work outstanding and the
            // next launch put back a device Zephyr had never touched.
            guard let wire = PointerAcceleration.curveValue(multiplier) else { continue }
            // Alter only what can be put back. A device that will not say what
            // its curve is now gets nothing written to it: `originals` is what
            // both this run and the next one restore from, so writing without
            // a record leaves the device carrying our figure with nothing left
            // that knows the old one.
            //
            // This is not hypothetical on the machine this was written on. Its
            // trackpad publishes `HIDPointerAccelerationType` — the name of
            // its curve reads fine — while the property that name points at is
            // absent from the service. `devices()` needs both and so never
            // lists it; this loop walks the services directly and would have
            // written to it.
            if captured[id] == nil {
                guard let current = hid.int(service, key) else { continue }
                captured[id] = current
            }
            hid.set(service, key, wire as CFNumber)
        }
        originals = captured
    }

    /// Puts every device back the way it was found.
    func restore() {
        for service in pointerServices() {
            guard let key = hid.string(service, "HIDPointerAccelerationType"),
                  let original = originals[hid.identity(service)] else { continue }
            hid.set(service, key, original as CFNumber)
        }
        originals = [:]
    }

    /// Diagnostics only — see the `--test-pointer` flag.
    func probe(_ key: String) -> String? {
        guard let service = pointerServices().first else { return nil }
        return hid.string(service, key)
    }

    private func pointerServices() -> [AnyObject] {
        hid.services(matching: [.mouse, .pointer])
    }

    /// A multiplier as the HID property wants it: 1.0 is the shipped curve and
    /// the wire value is that times 65536.
    ///
    /// Bounded because the multiplier comes from stored preferences and
    /// `Int(_:)` traps rather than saturating, on a NaN as well as on anything
    /// past its range — the same hazard FanController.rpm() names, here on a
    /// path that writes to an input device.
    static func curveValue(_ multiplier: Double) -> Int? {
        // Nothing rather than 1.0. The note on apply() is explicit that
        // applying the shipped curve is not the same as leaving a device
        // alone — this machine's trackpad ships at 45056, not 65536 — so a
        // figure that is not a number has to mean "leave it", not "reset it".
        guard multiplier.isFinite else { return nil }
        let bounded = Swift.min(Swift.max(multiplier, 0), 20)
        return Int((bounded * 65536.0).rounded())
    }

    /// What the device list is made of: every service that matched, and the
    /// curve it publishes, if any.
    ///
    /// For the probe. An empty device list has two quite different causes —
    /// nothing matched, or things matched and none of them publishes a curve
    /// to adjust — and "devices: 0" cannot tell them apart. On this machine it
    /// is the second: the built-in trackpad matches as a pointer and does not
    /// answer for `HIDPointerAccelerationType`, although the registry holds
    /// that property on its event driver.
    func matchedServices() -> [(name: String, curve: String?, value: Int?, raw: String?)] {
        pointerServices().map { service in
            let curve = hid.string(service, "HIDPointerAccelerationType")
            let raw = curve.flatMap { hid.string(service, $0) }
            return (hid.name(service), curve, curve.flatMap { hid.int(service, $0) }, raw)
        }
    }
}
