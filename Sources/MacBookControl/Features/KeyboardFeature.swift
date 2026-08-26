import SwiftUI

/// Key-for-key swaps, written below the window server, per keyboard.
///
/// Deliberately the simple half of what Karabiner does. Layers, chords and
/// hold-versus-tap need an event tap, which macOS shuts out of password fields
/// and the login window — so a Caps Lock that became Escape would stop being
/// Escape at exactly the moment it is least expected. Plain swaps go through
/// the HID layer instead, where they hold everywhere.
///
/// Each keyboard gets its own table because an external board and a built-in
/// one are two different opinions about where Control belongs.
final class KeyboardFeature: Feature {
    private let remapper = KeyRemapper()

    @Published var store: DeviceScopedStore<[KeyRemapper.Mapping]> {
        didSet {
            Preferences.keyboardStore = store
            guard isEnabled else { return }
            remapper.apply(store)
        }
    }
    @Published private(set) var devices: [InputDevice] = []
    /// nil means the defaults every keyboard follows unless it has its own.
    @Published var scope: String?

    init() {
        store = Preferences.keyboardStore
        super.init(id: "keyboard",
                   title: "Keyboard",
                   summary: "Swap keys for other keys, per keyboard. Applied below the window server, so it holds on the login screen and in password fields.")
        // A previous run may have been killed with a mapping live. The keys
        // stay swapped until logout, and nothing else knows to undo it.
        if Preferences.keyboardMappingApplied && !isEnabled {
            remapper.clear()
        }
    }

    override var isSupported: Bool { remapper.isAvailable }
    override var unsupportedReason: String? {
        isSupported ? nil : "This build of macOS does not expose the HID interfaces Zephyr needs."
    }

    override func activate() {
        refresh()
        remapper.apply(store)
    }

    override func deactivate() {
        remapper.clear()
    }

    func refresh() {
        devices = remapper.keyboards()
        // Forget devices that are gone, so the store does not accumulate every
        // keyboard ever attached.
        var pruned = store
        pruned.prune(keeping: Set(devices.map(\.identity)))
        if pruned != store { store = pruned }
        if let scope = scope, !devices.contains(where: { $0.identity == scope }) {
            self.scope = nil
        }
    }

    /// What the hardware actually holds for the selected keyboard, which is
    /// not always what we asked for.
    func liveMappings() -> [KeyRemapper.Mapping] { remapper.liveMappings(for: scope) }

    // MARK: Editing the selected scope

    var mappings: [KeyRemapper.Mapping] {
        get { scope.map { store[$0] } ?? store.defaults }
        set {
            if let scope = scope { store[scope] = newValue } else { store.defaults = newValue }
        }
    }

    var scopeIsCustomised: Bool { scope.map { store.isCustomised($0) } ?? false }

    func followDefaults() {
        guard let scope = scope else { return }
        var updated = store
        updated.revertToDefaults(scope)
        store = updated
    }

    func add() { mappings.append(KeyRemapper.Mapping(source: 0x39, destination: 0x29)) }

    func remove(at index: Int) {
        guard mappings.indices.contains(index) else { return }
        mappings.remove(at: index)
    }

    func applyPreset(_ preset: [KeyRemapper.Mapping]) { mappings = preset }

    override func makeView() -> AnyView { AnyView(KeyboardView(feature: self)) }
}

private struct KeyboardView: View {
    @ObservedObject var feature: KeyboardFeature

    private static let presets: [(String, [KeyRemapper.Mapping])] = [
        ("Caps Lock → Escape", [.init(source: 0x39, destination: 0x29)]),
        ("Caps Lock → Control", [.init(source: 0x39, destination: 0xE0)]),
        ("Swap Option and Command", [
            .init(source: 0xE2, destination: 0xE3), .init(source: 0xE3, destination: 0xE2),
            .init(source: 0xE6, destination: 0xE7), .init(source: 0xE7, destination: 0xE6),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MenuChoice(label: "These apply to",
                           selection: Binding(get: { feature.scope ?? "" },
                                              set: { feature.scope = $0.isEmpty ? nil : $0 }),
                           options: [("Every keyboard", "")] + feature.devices.map {
                               ($0.name + (feature.store.isCustomised($0.identity) ? " ·" : ""),
                                $0.identity)
                           })
                if feature.scopeIsCustomised {
                    Button("Follow the default") { feature.followDefaults() }
                }
            }
            Text(feature.scope == nil
                 ? "The default table. Any keyboard without one of its own follows this."
                 : (feature.scopeIsCustomised
                    ? "This keyboard has its own table."
                    : "This keyboard follows the default. Editing here gives it a table of its own."))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Common swaps").font(.headline)
            HStack {
                ForEach(Self.presets, id: \.0) { name, preset in
                    Button(name) { feature.applyPreset(preset) }
                }
            }

            Divider()
            HStack {
                Text("Mappings").font(.headline)
                Spacer()
                Button("Add") { feature.add() }
            }

            if feature.mappings.isEmpty {
                Text("Nothing is swapped. The keys behave as printed.")
                    .font(.subheadline).foregroundColor(.secondary)
            }

            ForEach(Array(feature.mappings.enumerated()), id: \.offset) { index, _ in
                HStack {
                    keyPicker(index: index, isSource: true)
                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                    keyPicker(index: index, isSource: false)
                    Button("Remove") { feature.remove(at: index) }
                }
            }

            Divider()
            Text("macOS forgets these when a keyboard re-enumerates, so Zephyr writes them again at login. Turn on Launch at login if you rely on a swap.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { feature.refresh() }
    }

    private func keyPicker(index: Int, isSource: Bool) -> some View {
        MenuChoice(label: nil,
                   selection: Binding(
                       get: { isSource ? feature.mappings[index].source
                                       : feature.mappings[index].destination },
                       set: { usage in
                           var mapping = feature.mappings[index]
                           if isSource { mapping.source = usage } else { mapping.destination = usage }
                           feature.mappings[index] = mapping
                       }),
                   options: KeyRemapper.catalogue.map { ($0.name, $0.usage) })
    }
}
