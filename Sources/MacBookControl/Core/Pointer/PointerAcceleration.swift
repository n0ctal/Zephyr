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
            if captured[id] == nil, let current = hid.int(service, key) {
                captured[id] = current
            }
            hid.set(service, key, Int((multiplier * 65536.0).rounded()) as CFNumber)
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
