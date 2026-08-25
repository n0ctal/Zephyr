import SwiftUI

/// Key-for-key swaps, written below the window server.
///
/// Deliberately the simple half of what Karabiner does. Layers, chords and
/// hold-versus-tap need an event tap, which macOS shuts out of password fields
/// and the login window — so a Caps Lock that became Escape would stop being
/// Escape at exactly the moment it is least expected. Plain swaps go through
/// the HID layer instead, where they hold everywhere.
final class KeyboardFeature: Feature {
    private let remapper = KeyRemapper()

    @Published var mappings: [KeyRemapper.Mapping] {
        didSet {
            Preferences.keyMappings = mappings
            guard isEnabled else { return }
            remapper.apply(mappings)
        }
    }
    @Published private(set) var keyboards: [String] = []

    init() {
        mappings = Preferences.keyMappings
        super.init(id: "keyboard",
                   title: "Keyboard",
                   summary: "Swap keys for other keys. Applied below the window server, so it holds on the login screen and in password fields.")
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
        remapper.apply(mappings)
        refresh()
    }

    override func deactivate() {
        remapper.clear()
    }

    func refresh() { keyboards = remapper.keyboards() }

    /// What the hardware actually holds, which is not always what we asked for.
    func liveMappings() -> [KeyRemapper.Mapping] { remapper.liveMappings() }

    func add() {
        mappings.append(KeyRemapper.Mapping(source: 0x39, destination: 0x29))
    }

    func remove(at index: Int) {
        guard mappings.indices.contains(index) else { return }
        mappings.remove(at: index)
        // An empty list still has to be written: the property is the whole
        // table, so dropping the last row only takes effect once it is sent.
        if isEnabled { remapper.apply(mappings) }
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Applies to: \(feature.keyboards.isEmpty ? "no keyboards found" : feature.keyboards.joined(separator: ", "))")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("macOS forgets these when a keyboard re-enumerates, so Zephyr writes them again at login. Turn on Launch at login if you rely on a swap.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { feature.refresh() }
    }

    private func keyPicker(index: Int, isSource: Bool) -> some View {
        Picker("", selection: Binding(
            get: {
                isSource ? feature.mappings[index].source : feature.mappings[index].destination
            },
            set: { usage in
                var mapping = feature.mappings[index]
                if isSource { mapping.source = usage } else { mapping.destination = usage }
                feature.mappings[index] = mapping
            }
        )) {
            ForEach(KeyRemapper.catalogue) { key in
                Text(key.name).tag(key.usage)
            }
        }
        .labelsHidden()
        .frame(width: 150)
    }
}
