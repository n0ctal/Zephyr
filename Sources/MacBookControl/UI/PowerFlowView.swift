import SwiftUI

/// Where the watts are going, drawn.
///
/// Three numbers side by side never answer the question people actually have:
/// is the charger keeping up, and how much of it reaches the battery. A band
/// whose thickness is the power makes that readable without arithmetic — the
/// thin ribbon going up is what is left over for charging.
///
/// Directions come from the sign of the battery flow, which is why that had to
/// be signed: positive is the adapter filling the battery, negative is the
/// battery carrying the machine and there is no adapter at all.
struct PowerFlowView: View {
    let draw: PowerDraw
    let isPluggedIn: Bool
    @Environment(\.terminalStyling) private var terminal
    @Environment(\.terminalPalette) private var palette

    /// Rounded boxes and a mustard fill are the system's shapes, and in a
    /// window where every other frame is a one-point rule they read as a
    /// picture pasted in from somewhere else. Square corners and the theme's
    /// own green in the terminal layout; unchanged everywhere else.
    private var corner: CGFloat { terminal ? 0 : 10 }
    private var bandCorner: CGFloat { terminal ? 0 : 4 }

    private var systemWatts: Double { max(0, draw.systemWatts ?? 0) }
    private var batteryWatts: Double { draw.batteryWatts ?? 0 }
    private var adapterWatts: Double { max(0, draw.adapterWatts ?? 0) }

    /// Charging: the adapter feeds both. Discharging: the battery feeds the
    /// machine and the adapter is not in the picture.
    private var isCharging: Bool { batteryWatts > 0.05 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sourceNode
                GeometryReader { geometry in
                    bands(in: geometry.size)
                }
                .frame(height: 96)
                machineNode
            }
            legend
        }
    }

    // MARK: Nodes

    private var sourceNode: some View {
        VStack(spacing: 4) {
            Image(systemName: isCharging || isPluggedIn ? "powerplug.fill" : "battery.50")
                .font(.system(size: 18))
            Text(String(format: "%.0f W", isCharging || isPluggedIn ? max(adapterWatts, systemWatts + batteryWatts) : -batteryWatts))
                .font(.system(.caption, design: .monospaced))
        }
        .frame(width: 62, height: 96)
        .background(nodeBackground)
    }

    private var machineNode: some View {
        VStack(spacing: 6) {
            Image(systemName: "laptopcomputer").font(.system(size: 18))
            Text(String(format: "%.1f W", systemWatts))
                .font(.system(.caption, design: .monospaced))
        }
        .frame(width: 62, height: 96)
        .background(nodeBackground)
    }

    @ViewBuilder private var nodeBackground: some View {
        if terminal {
            Rectangle().stroke(palette.rule, lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: corner).fill(Color.secondary.opacity(0.12))
        }
    }

    // MARK: Bands

    private func bands(in size: CGSize) -> some View {
        // Scaled against the largest flow so the thickest band always fills the
        // height: an absolute scale would make everything a hairline on a
        // machine that idles at eight watts.
        let total = max(systemWatts + max(0, batteryWatts), 1)
        let toMachine = CGFloat(systemWatts / total) * size.height
        let toBattery = CGFloat(max(0, batteryWatts) / total) * size.height

        return ZStack(alignment: .topLeading) {
            if isCharging && toBattery > 1 {
                band(height: toBattery, width: size.width,
                     label: String(format: "%.2f W", batteryWatts))
                    .foregroundColor(terminal ? palette.accent.opacity(0.30)
                                              : .orange.opacity(0.45))
            }
            band(height: toMachine, width: size.width,
                 label: String(format: "%.2f W", systemWatts))
                .foregroundColor(terminal ? palette.accent.opacity(0.55)
                                          : .yellow.opacity(0.45))
                .offset(y: isCharging ? toBattery : 0)
        }
    }

    private func band(height: CGFloat, width: CGFloat, label: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: bandCorner)
                .frame(width: width, height: max(2, height))
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(terminal ? palette.ground : .primary)
        }
        .frame(width: width, height: max(2, height), alignment: .center)
    }

    private var legend: some View {
        Text(isCharging
             ? "The adapter is carrying the machine and putting the rest into the battery."
             : (isPluggedIn
                ? "The adapter is carrying the machine; the battery is neither filling nor draining."
                : "The battery is carrying the machine."))
            .font(.caption).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
