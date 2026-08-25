import Foundation

/// Swaps keys at the HID layer, before anything else sees them.
///
/// This is the same mechanism `hidutil` drives, reached directly instead of
/// through a subprocess. Being below the window server has one consequence
/// that matters: the mapping holds on the login window and inside password
/// fields, where an event tap is deliberately shut out. That is the whole
/// reason to prefer it for plain key-for-key swaps.
///
/// What it cannot do is anything conditional — no layers, no chords, no
/// hold-versus-tap, no per-application rules. Those need to watch the event
/// stream, which is a different mechanism with different trade-offs.
///
/// Mappings do not survive a reboot; macOS forgets them when the device
/// re-enumerates. Zephyr re-applies at login, which is why it wants to start
/// there if this is in use.
final class KeyRemapper {
    private let hid = HIDServiceBridge.shared

    var isAvailable: Bool { hid.isAvailable }

    struct Mapping: Equatable, Codable {
        var source: Int
        var destination: Int
    }

    /// A key the user can pick, by HID usage. The wire value is the usage
    /// with the keyboard page in the high word, which is what the property
    /// expects — the catalogue stores the bare usage so the table stays
    /// readable against the HID spec.
    struct Key: Identifiable, Hashable {
        let name: String
        let usage: Int
        var id: Int { usage }
        var wireValue: Int { KeyRemapper.wireValue(forUsage: usage) }
    }

    /// Curated rather than exhaustive: the full HID table is a thousand
    /// entries, almost none of which anyone wants to remap.
    static let catalogue: [Key] = [
        Key(name: "Caps Lock", usage: 0x39),
        Key(name: "Escape", usage: 0x29),
        Key(name: "Tab", usage: 0x2B),
        Key(name: "Return", usage: 0x28),
        Key(name: "Space", usage: 0x2C),
        Key(name: "Delete", usage: 0x2A),
        Key(name: "Forward Delete", usage: 0x4C),
        Key(name: "Left Control", usage: 0xE0),
        Key(name: "Left Shift", usage: 0xE1),
        Key(name: "Left Option", usage: 0xE2),
        Key(name: "Left Command", usage: 0xE3),
        Key(name: "Right Control", usage: 0xE4),
        Key(name: "Right Shift", usage: 0xE5),
        Key(name: "Right Option", usage: 0xE6),
        Key(name: "Right Command", usage: 0xE7),
        Key(name: "Grave (`)", usage: 0x35),
        Key(name: "Home", usage: 0x4A),
        Key(name: "End", usage: 0x4D),
        Key(name: "Page Up", usage: 0x4B),
        Key(name: "Page Down", usage: 0x4E),
        Key(name: "Left Arrow", usage: 0x50),
        Key(name: "Right Arrow", usage: 0x4F),
        Key(name: "Down Arrow", usage: 0x51),
        Key(name: "Up Arrow", usage: 0x52),
    ] + (1...12).map { Key(name: "F\($0)", usage: 0x3A + $0 - 1) }

    /// The property expects the HID usage with the keyboard page in the high
    /// word. One function so the value written to the hardware and the value
    /// shown in the UI cannot drift apart — and so a check of one is a check
    /// of both.
    static func wireValue(forUsage usage: Int) -> Int { 0x700000000 | usage }

    static func name(forUsage usage: Int) -> String {
        catalogue.first { $0.usage == usage }?.name ?? String(format: "0x%02X", usage)
    }

    /// Every attached keyboard, with the identity its settings are stored
    /// under. The Touch Bar registers as a keyboard too, which is worth seeing
    /// rather than discovering when a swap lands somewhere unexpected.
    func keyboards() -> [InputDevice] {
        hid.services(matching: [.keyboard]).map {
            InputDevice(identity: hid.identity($0), name: hid.name($0))
        }
    }

    /// Writes each keyboard its own table. Partial edits are not possible:
    /// the property is the complete list for that device, so anything left out
    /// of a device's table is unmapped on that device.
    func apply(_ store: DeviceScopedStore<[Mapping]>) {
        var anyApplied = false
        for service in hid.services(matching: [.keyboard]) {
            let mappings = store[hid.identity(service)]
            let pairs = mappings.map {
                ["HIDKeyboardModifierMappingSrc": Self.wireValue(forUsage: $0.source),
                 "HIDKeyboardModifierMappingDst": Self.wireValue(forUsage: $0.destination)]
            }
            hid.set(service, "HIDKeyboardModifierMappingPairs", pairs as CFArray)
            anyApplied = anyApplied || !mappings.isEmpty
        }
        Preferences.keyboardMappingApplied = anyApplied
    }

    /// Back to the keys as printed. Called when the feature is switched off,
    /// and at launch if a previous run was killed while a mapping was live —
    /// otherwise a keyboard stays rearranged with nothing admitting to it.
    func clear() {
        for service in hid.services(matching: [.keyboard]) {
            hid.set(service, "HIDKeyboardModifierMappingPairs", [] as CFArray)
        }
        Preferences.keyboardMappingApplied = false
    }

    /// Reads back what a keyboard actually holds, so the UI can show the state
    /// of the hardware rather than the state of our own intentions. With no
    /// identity given, the first keyboard answers.
    func liveMappings(for identity: String? = nil) -> [Mapping] {
        let services = hid.services(matching: [.keyboard])
        let service = identity.flatMap { wanted in
            services.first { hid.identity($0) == wanted }
        } ?? services.first
        guard let service = service,
              let pairs = hid.get(service, "HIDKeyboardModifierMappingPairs") as? [[String: Int]]
        else { return [] }
        return pairs.compactMap { pair in
            guard let source = pair["HIDKeyboardModifierMappingSrc"],
                  let destination = pair["HIDKeyboardModifierMappingDst"] else { return nil }
            return Mapping(source: source & 0xFFFF, destination: destination & 0xFFFF)
        }
    }
}
