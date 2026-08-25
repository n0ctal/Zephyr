import SwiftUI

/// A slider with the number written out and editable beside it.
///
/// A slider alone cannot be aimed. Charge ceilings, watts and fan speeds are
/// values people know in advance — "80 %", "45 W" — and dragging until the
/// label happens to read the right number is not how anyone wants to enter
/// one. The two stay in step: the field commits on Return or when it loses
/// focus, and the slider writes back into the field.
struct ValueField: View {
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    @Binding var value: Double

    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                TextField("", text: $text, onCommit: commit)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text(suffix).font(.subheadline).foregroundColor(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
        .onAppear { text = format(value) }
        // Keeps the field honest while the slider is dragged. Without it the
        // number would freeze at whatever was last typed.
        .onChange(of: value) { text = format($0) }
    }

    private func format(_ value: Double) -> String {
        step < 1 ? String(format: "%.2f", value) : String(Int(value.rounded()))
    }

    private func commit() {
        guard let typed = Double(text.replacingOccurrences(of: ",", with: ".")) else {
            text = format(value)   // unparseable: put back what it was
            return
        }
        value = min(max(typed, range.lowerBound), range.upperBound)
        text = format(value)
    }
}

/// The same idea for a whole number, which is what most of these are.
struct IntField: View {
    let title: String
    let range: ClosedRange<Int>
    let suffix: String
    @Binding var value: Int

    var body: some View {
        ValueField(
            title: title,
            range: Double(range.lowerBound)...Double(range.upperBound),
            step: 1,
            suffix: suffix,
            value: Binding(
                get: { Double(value) },
                set: { value = Int($0.rounded()) }
            )
        )
    }
}

/// A bare number box, for rows too dense to carry a slider as well.
struct CompactNumberField: View {
    let range: ClosedRange<Int>
    let suffix: String
    @Binding var value: Int
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text, onCommit: commit)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
            Text(suffix).font(.subheadline).foregroundColor(.secondary)
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { text = String($0) }
    }

    private func commit() {
        guard let typed = Int(text) else { text = String(value); return }
        value = min(max(typed, range.lowerBound), range.upperBound)
        text = String(value)
    }
}
