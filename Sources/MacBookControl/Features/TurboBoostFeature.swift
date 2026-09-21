import AppKit
import SwiftUI

/// What the CPU is allowed to draw.
///
/// Turbo Boost is the blunt lever: off, the i9 stops sprinting to 4.8 GHz and
/// the machine runs perceptibly cooler and quieter at a cost in burst speed.
/// It is implemented by a kext that sets `IA32_MISC_ENABLE` bit 38, so it
/// needs SIP disabled and a one-time approval — which is why the tab explains
/// itself when the kext is missing rather than showing a switch that fails.
/// Turbo Boost, on its own switch.
///
/// It was joined to the power limit under one "Power" heading, which read
/// tidily and hid a fault: the pair shared a single support test, so a machine
/// with the power-limit kext and not the Turbo Boost one lost the limits from
/// the interface as well. They need different kexts and are different
/// decisions, so they are now two.
final class TurboBoostFeature: Feature {
    private let helper: HelperClient
    private let turbo: TurboBoostController

    @Published var turboDisabled: Bool

    init(helper: HelperClient, turbo: TurboBoostController) {
        self.helper = helper
        self.turbo = turbo
        // Asking the system costs 813 ms, measured — `kextstat` walks every
        // loaded extension. Paying that in init delays the menu-bar icon
        // appearing at all, so the last known answer is used and corrected
        // from a background read a moment later.
        self.turboDisabled = Preferences.lastKnownTurboDisabled
        super.init(id: "turbo",
                   title: "Turbo Boost",
                   summary: "Hold the CPU to its base clock. Cooler and quieter, and slower under load.")
    }

    override var isSupported: Bool { turbo.isAvailable }
    override var unsupportedReason: String? {
        isSupported ? nil : "The Turbo Boost kext is not installed. It needs System Integrity Protection disabled, which is a deliberate choice — Zephyr will not make it for you."
    }

    /// Re-asserts the stored choice. Enabling the feature must not silently
    /// change the CPU: if the user never asked for turbo off, leave it on.
    override func reloadFromPreferences() {
        turboDisabled = Preferences.lastKnownTurboDisabled
    }

    override func activate() {
        // Deferred until the real state is known: acting on a stale cached
        // value could flip Turbo Boost the wrong way at launch.
        refreshTurboState { [weak self] in
            guard let self = self, self.isEnabled else { return }
            self.helper.setTurboBoostEnabled(!self.turboDisabled)
        }
    }

    /// Turbo Boost back on. Leaving a machine derated by a feature the user
    /// switched off would be a lie about what "off" means.
    override func deactivate() {
        helper.setTurboBoostEnabled(true)
    }

    /// Reads the live state off the main thread and publishes it back.
    func refreshTurboState(then completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let disabled = self.turbo.refreshTurboState()
            DispatchQueue.main.async {
                self.turboDisabled = disabled
                Preferences.lastKnownTurboDisabled = disabled
                completion?()
            }
        }
    }

    func setTurboDisabled(_ disabled: Bool) {
        turboDisabled = disabled
        Preferences.lastKnownTurboDisabled = disabled
        guard isEnabled else { return }
        helper.setTurboBoostEnabled(!disabled)
    }

    override func makeView() -> AnyView { AnyView(TurboBoostView(feature: self)) }
}

private struct TurboBoostView: View {
    @ObservedObject var feature: TurboBoostFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Disable Turbo Boost", isOn: Binding(
                get: { feature.turboDisabled },
                set: { feature.setTurboDisabled($0) }
            ))
            Text("The firmware restores this register across sleep, so Zephyr re-applies it on every wake. Without that the setting quietly lapses overnight.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
