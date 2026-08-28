import AppKit
import SwiftUI

/// What the CPU is allowed to draw.
///
/// Turbo Boost is the blunt lever: off, the i9 stops sprinting to 4.8 GHz and
/// the machine runs perceptibly cooler and quieter at a cost in burst speed.
/// It is implemented by a kext that sets `IA32_MISC_ENABLE` bit 38, so it
/// needs SIP disabled and a one-time approval — which is why the tab explains
/// itself when the kext is missing rather than showing a switch that fails.
/// The Intel package power limit, on its own switch.
///
/// Separate from Turbo Boost because it is a separate decision and, more to
/// the point, a separate kernel extension: sharing one support test meant a
/// machine with this kext and not the other one saw neither.
final class PowerLimitFeature: Feature {
    private let helper: HelperClient
    private let telemetry: Telemetry

    @Published private(set) var limits: PowerLimits.Reading?
    @Published var pl1: Double = 0
    @Published var pl2: Double = 0

    init(helper: HelperClient, telemetry: Telemetry) {
        self.helper = helper
        self.telemetry = telemetry
        let reading = PowerLimits.current()
        self.limits = reading
        self.pl1 = reading?.pl1Watts ?? 0
        self.pl2 = reading?.pl2Watts ?? 0
        super.init(id: "powerlimit",
                   title: "Power limit",
                   summary: "Cap the watts the package may draw. Less heat and less fan noise, at the cost of sustained speed.")
    }

    // Deliberately not gated on the kext being loaded. The section is where
    // the instructions for installing it live, and a feature that hides
    // itself is a feature nobody can find out how to get.
    override var isSupported: Bool { true }

    override func activate() { reapplyStoredLimits() }

    /// Puts the chosen power limit back.
    ///
    /// Called at launch and after every wake. The firmware restores the Turbo
    /// Boost register across sleep while the app still believes it is set —
    /// that lesson is in the code next door — and MSR_PKG_POWER_LIMIT is in the
    /// same class of register. Whether it actually lapses has not been seen
    /// happen; re-applying costs one sysctl write and removes the question.
    func reapplyStoredLimits() {
        guard isEnabled,
              Preferences.desiredPL1 > 0, Preferences.desiredPL2 > 0,
              let raw = PowerLimits.composed(pl1Watts: Preferences.desiredPL1,
                                             pl2Watts: Preferences.desiredPL2)
        else { return }
        helper.setPowerLimit(raw)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshLimits()
        }
    }

    func refreshLimits() {
        limits = PowerLimits.current()
        if let reading = limits {
            pl1 = reading.pl1Watts
            pl2 = reading.pl2Watts
        }
    }

    func applyLimits() {
        guard isEnabled, let raw = PowerLimits.composed(pl1Watts: pl1, pl2Watts: pl2) else { return }
        Preferences.desiredPL1 = pl1
        Preferences.desiredPL2 = pl2
        helper.setPowerLimit(raw)
        // The helper writes asynchronously, so read the register back a moment
        // later rather than displaying what we hoped for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshLimits()
        }
    }

    /// Built from the running bundle rather than hard-coded, so it is right
    /// whether Zephyr sits in /Applications or in a build directory.
    static var kextInstallCommand: String {
        let script = Bundle.main.resourceURL?
            .appendingPathComponent("scripts/install-power-kext.sh").path
            ?? "/Applications/Zephyr.app/Contents/Resources/scripts/install-power-kext.sh"
        return "sudo \"\(script)\""
    }

    override func makeView() -> AnyView {
        AnyView(PowerLimitView(feature: self, telemetry: telemetry))
    }
}

private struct PowerLimitView: View {
    @Environment(\.readoutInSidebar) private var readoutInSidebar
    @ObservedObject var feature: PowerLimitFeature
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PowerLimitControls(feature: feature)

            // The two draws move to the readings beside the sections when
            // there is a sidebar to put them in: they are numbers the machine
            // reports, not settings, and they are worth seeing from any
            // section rather than only from this one.
            if !readoutInSidebar {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Draw").font(.headline)
                    if let draw = telemetry.battery?.power {
                        if let system = draw.systemWatts {
                            Text(String(format: "System %.1f W", system)).font(.subheadline)
                        }
                        if let adapter = draw.adapterWatts {
                            Text(String(format: "Adapter %.1f W", adapter)).font(.subheadline)
                        }
                    } else {
                        Text("No power sensors answered.").font(.subheadline).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

/// The package power limit, when the kext that exposes it is loaded.
struct PowerLimitControls: View {
    @ObservedObject var feature: PowerLimitFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Power limit").font(.headline)
            if let reading = feature.limits {
                if let tdp = reading.tdpWatts {
                    Text(String(format: "Rated for %.0f W. Currently allowed %.0f W sustained and %.0f W in bursts.",
                                tdp, reading.pl1Watts, reading.pl2Watts))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if reading.isLocked {
                    Text("The firmware has locked this register — writes are ignored by the hardware until the next power cycle. Nothing in software can change that.")
                        .font(.subheadline).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: "Currently PL1 %.0f W, PL2 %.0f W", reading.pl1Watts, reading.pl2Watts))
                        .font(.subheadline)
                } else {
                    ValueField(title: "Sustained (PL1)",
                               range: reading.lowerBound...reading.upperBound,
                               step: 1, suffix: "W",
                               value: Binding(get: { feature.pl1 },
                                              set: { feature.pl1 = $0; feature.applyLimits() }))
                    ValueField(title: "Burst (PL2)",
                               range: reading.lowerBound...reading.upperBound,
                               step: 1, suffix: "W",
                               value: Binding(get: { feature.pl2 },
                                              set: { feature.pl2 = $0; feature.applyLimits() }))
                    Text("Lowering the sustained limit is the substitute for undervolting on this machine: the undervolt register is locked by the firmware's Plundervolt mitigation, while this one is a mechanism Intel intends to be used.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // Saying only "not loaded" leaves the reader at a dead end.
                // The command is the answer, so it is here rather than in a
                // document somebody has to find.
                Text("Not available: the kext that publishes these registers is not loaded. MSRs are ring 0, so there is no way to read them from an ordinary process.")
                    .font(.subheadline).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("It is a deliberate step, not an oversight: it puts code in the kernel and needs System Integrity Protection disabled. Run this once in Terminal, then reopen this tab.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(PowerLimitFeature.kextInstallCommand)
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                HStack {
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(PowerLimitFeature.kextInstallCommand, forType: .string)
                    }
                    Button("Check again") { feature.refreshLimits() }
                }
                Text("macOS will then ask you to approve the extension: System Settings → Privacy & Security → Security, at the bottom. Approval is per extension, so having allowed the Turbo Boost one does not carry over. After approving, restart.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The script says at the end whether the firmware has locked the register. If it has, the limits can be read but not changed — by anything, not just by Zephyr.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { feature.refreshLimits() }
    }
}
