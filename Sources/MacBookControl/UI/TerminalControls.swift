import AppKit
import SwiftUI

/// Controls drawn the way a terminal draws them.
///
/// This is the trade that was refused twice and is now being made deliberately:
/// a hand-drawn control looks nearly right and then behaves differently from
/// every other control on the Mac. It is worth it here and nowhere else,
/// because a monospaced window full of blue system sliders is not a terminal
/// theme — it is two themes at once, which was the actual complaint.
///
/// Three rules keep the cost down. Each of these draws the same value the
/// native control would and writes it back the same way, so nothing downstream
/// knows the difference. Each falls back to the native control when the theme
/// is off, so the other two layouts are untouched. And the keyboard still
/// works, because they are built from real controls where one exists — the
/// number field is a real `TextField` with its own frame drawn around it.

/// Sizes shared by the terminal controls, so a column in one view lines up
/// with the same column in another.
enum TerminalMetrics {
    /// One column for every label — the drop-downs and the value rows both —
    /// so everything in a section starts at the same place. Wide enough for
    /// "Start lifting the fans at", which is the longest label in the app.
    ///
    /// Labels are set against its right edge, so a short one sits beside its
    /// field instead of stranded a long way to the left of it. That is what a
    /// settings form has always done and it is the only arrangement where both
    /// the labels and the fields have an edge in common.
    static let labelColumn: CGFloat = 215
}

private struct TerminalStylingKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ReadoutInSidebarKey: EnvironmentKey {
    static let defaultValue = false
}

private struct TerminalPaletteKey: EnvironmentKey {
    static let defaultValue = LayoutPalette.of(.terminal, dark: true)
}



extension EnvironmentValues {
    /// Set once, at the top of the window, and read by every control below it.
    var terminalStyling: Bool {
        get { self[TerminalStylingKey.self] }
        set { self[TerminalStylingKey.self] = newValue }
    }
    /// True when the window has a sidebar carrying the readings, so a section
    /// need not repeat them.
    var readoutInSidebar: Bool {
        get { self[ReadoutInSidebarKey.self] }
        set { self[ReadoutInSidebarKey.self] = newValue }
    }
    var terminalPalette: LayoutPalette {
        get { self[TerminalPaletteKey.self] }
        set { self[TerminalPaletteKey.self] = newValue }
    }
}

/// `[x]` and `[ ]`, which is how a switch has been written since before there
/// were switches to draw.
struct BracketToggleStyle: ToggleStyle {
    let palette: LayoutPalette

    func makeBody(configuration: Configuration) -> some View {
        // On the label's baseline, not centred against its box. The labels
        // here are not all the same size — "Enable Cooling" is a headline, the
        // rows in the menu-bar list are body text — and centring put the
        // bracket at a different height in each one.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(configuration.isOn ? "[x]" : "[ ]")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(configuration.isOn ? palette.accent : palette.dim)
            configuration.label
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

/// A button written the way a terminal writes one: in brackets, with no
/// bezel. The rounded grey pill is the last system shape left in the theme —
/// and there are enough buttons in the Input section for it to read as two
/// designs at once.
struct BracketButtonStyle: ButtonStyle {
    let palette: LayoutPalette

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            Text("[ ").foregroundColor(palette.dim)
            configuration.label
                .foregroundColor(configuration.isPressed ? palette.accent : palette.text)
            Text(" ]").foregroundColor(palette.dim)
        }
        .font(.system(size: 13, design: .monospaced))
        .contentShape(Rectangle())
    }
}

/// A row of choices in a ruled frame, the selected one in brackets.
///
/// A segmented control is the one thing `fontDesign` cannot reach: AppKit draws
/// its labels itself, inside a control this app does not own. So in the
/// terminal theme it is drawn here instead — and everywhere else it is still
/// the system's, which is why both branches exist in one view rather than at
/// each of the four call sites.
struct SegmentedChoice<Value: Hashable>: View {
    let label: String?
    @Binding var selection: Value
    let options: [(String, Value)]
    @Environment(\.terminalStyling) private var terminal
    @Environment(\.terminalPalette) private var palette

    var body: some View {
        if terminal {
            HStack(spacing: 10) {
                if let label = label {
                    // The same column the drop-downs and the value rows use,
                    // so every label in a section shares one right edge.
                    Text(label)
                        .foregroundColor(palette.text)
                        .frame(width: TerminalMetrics.labelColumn, alignment: .trailing)
                }
                cells
            }
        } else {
            Picker(label ?? "", selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.0).tag(option.1)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .modifier(HideLabelIfEmpty(hidden: label == nil))
        }
    }

    private var cells: some View {
        // No boxes. The brackets and the colour already say which one is
        // chosen, and a frame around each choice on top of that is a third
        // way of saying the same thing — which is what made the row look like
        // a control borrowed from somewhere else.
        HStack(spacing: 18) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let active = option.1 == selection
                // The gap either side is padding rather than two spaces of
                // text: the same look for half the width, which matters in a
                // row that has to hold three or five of these.
                Text(active ? "[ \(option.0) ]" : option.0)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(active ? palette.accent : palette.text)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, active ? 0 : 8)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = option.1 }
                    .id(index)
            }
            Spacer(minLength: 0)
        }
    }
}

/// `.labelsHidden()` only when there is no label, since hiding an empty label
/// still reserves its column.
private struct HideLabelIfEmpty: ViewModifier {
    let hidden: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if hidden { content.labelsHidden() } else { content }
    }
}

/// A thin rule with a square knob.
///
/// The system slider on macOS ignores `accentColor` and keeps its blue fill and
/// round grey knob, which in a monospaced green panel reads as a control
/// borrowed from another application. This is the same square the text is set
/// on.
struct TerminalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let palette: LayoutPalette

    var body: some View {
        GeometryReader { geometry in
            let span = max(0.0001, range.upperBound - range.lowerBound)
            let fraction = min(1, max(0, (value - range.lowerBound) / span))
            let knob: CGFloat = 10
            let travel = max(0, geometry.size.width - knob)
            let x = travel * CGFloat(fraction)

            ZStack(alignment: .leading) {
                Rectangle().fill(palette.rule).frame(height: 1)
                Rectangle().fill(palette.accent.opacity(0.55))
                    .frame(width: x + knob / 2, height: 1)
                Rectangle().fill(palette.accent)
                    .frame(width: knob, height: knob)
                    .offset(x: x)
            }
            .frame(height: geometry.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    value = Self.value(atX: drag.location.x, knob: knob, travel: travel,
                                       range: range, step: step)
                }
            )
        }
    }
}

extension TerminalSlider {
    /// Where a drag lands, in the value's own units.
    ///
    /// Pulled out of the gesture so it can be checked: this is the arithmetic
    /// that turns a pixel into a wattage, and getting it wrong writes a real
    /// number into a real register. The rounding matches what a stepped system
    /// slider does, so switching themes cannot change what a drag means.
    static func value(atX x: CGFloat, knob: CGFloat, travel: CGFloat,
                      range: ClosedRange<Double>, step: Double) -> Double {
        let span = max(0.0001, range.upperBound - range.lowerBound)
        let position = min(max(0, x - knob / 2), travel)
        // The two ends are the bounds themselves, before any rounding. A step
        // that does not divide the range evenly otherwise leaves the top
        // unreachable — dragged fully right, a 10…110 slider stepping by 7
        // stops at 108 and no amount of pulling gets the last two watts.
        if position <= 0 { return range.lowerBound }
        if position >= travel { return range.upperBound }
        let raw = range.lowerBound + Double(travel > 0 ? position / travel : 0) * span
        guard step > 0 else { return min(max(raw, range.lowerBound), range.upperBound) }
        let stepped = ((raw - range.lowerBound) / step).rounded() * step + range.lowerBound
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}

/// A number you can type into, with a frame drawn around it — because in a
/// window with no filled controls, the border is the only thing that says a
/// field is a field.
struct TerminalNumberBox: View {
    @Binding var text: String
    let commit: () -> Void
    let palette: LayoutPalette
    var width: CGFloat = 58

    var body: some View {
        TextField("", text: $text, onCommit: commit)
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 13, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .foregroundColor(palette.text)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(width: width)
            .overlay(Rectangle().stroke(palette.rule, lineWidth: 1))
    }
}

/// A drop-down, drawn as a ruled field with a marker rather than as the
/// system's grey pill.
///
/// The pill is the last thing in the window that still looks borrowed: a
/// popup button draws its own bezel and there is no style to change it, only
/// the font inside. So in the terminal theme this is a `Menu` with a label of
/// our own, and everywhere else it is the ordinary `Picker` — same value, same
/// binding, same keyboard behaviour.
struct MenuChoice<Value: Hashable>: View {
    let label: String?
    @Binding var selection: Value
    let options: [(String, Value)]
    @Environment(\.terminalStyling) private var terminal
    @Environment(\.terminalPalette) private var palette

    private var currentLabel: String {
        options.first { $0.1 == selection }?.0 ?? ""
    }

    var body: some View {
        if terminal {
            HStack(spacing: 8) {
                if let label = label, !label.isEmpty {
                    // The colon is what a written-out setting looks like:
                    // "Follow: the hottest sensor". With no box around the
                    // value there is nothing else joining the two.
                    Text(label + ":")
                        .foregroundColor(palette.text)
                        .frame(width: TerminalMetrics.labelColumn, alignment: .trailing)
                }
                menu
                Spacer(minLength: 0)
            }
        } else {
            Picker(label ?? "", selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.0).tag(option.1)
                }
            }
            .modifier(HideLabelIfEmptyPublic(hidden: label == nil || label?.isEmpty == true))
        }
    }

    private var menu: some View {
        // No box. A ruled rectangle around every value was one frame too many
        // in a window whose switches and choices are already written in
        // brackets — the value reads as a value because of the colon in front
        // of it and the marker after it.
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.0) { selection = option.1 }
            }
        } label: {
            Text(currentLabel)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(palette.accent)
                .lineLimit(1)
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .fixedSize()
    }
}

private struct HideLabelIfEmptyPublic: ViewModifier {
    let hidden: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if hidden { content.labelsHidden() } else { content }
    }
}
