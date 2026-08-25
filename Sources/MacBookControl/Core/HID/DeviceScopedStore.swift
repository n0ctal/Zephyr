import Foundation

/// Settings that differ per attached device.
///
/// Two mice are two different opinions about how a mouse should behave, and so
/// are a built-in keyboard and an external one. Storing a single set and
/// applying it everywhere is the thing being fixed here.
///
/// Devices are keyed by the identity `HIDServiceBridge` derives from vendor,
/// product and serial, so unplugging a device and plugging it into another
/// port keeps its settings. A device never seen before falls back to the
/// defaults rather than to nothing — otherwise plugging in a mouse would
/// silently drop every preference until it was configured by hand.
struct DeviceScopedStore<Value: Codable & Equatable>: Codable, Equatable {
    var defaults: Value
    var perDevice: [String: Value] = [:]

    init(defaults: Value) { self.defaults = defaults }

    subscript(identity: String) -> Value {
        get { perDevice[identity] ?? defaults }
        set { perDevice[identity] = newValue }
    }

    /// True when this device has its own entry rather than following the
    /// defaults. The UI shows the difference so "why is this mouse different"
    /// has an answer.
    func isCustomised(_ identity: String) -> Bool { perDevice[identity] != nil }

    mutating func revertToDefaults(_ identity: String) { perDevice.removeValue(forKey: identity) }

    /// Drops entries for devices that no longer exist, so the store does not
    /// grow forever with every mouse ever attached. Called with the identities
    /// currently present.
    mutating func prune(keeping present: Set<String>) {
        perDevice = perDevice.filter { present.contains($0.key) }
    }
}

/// A device as the settings UI needs to talk about it.
struct InputDevice: Identifiable, Hashable {
    let identity: String
    let name: String
    var id: String { identity }
}
