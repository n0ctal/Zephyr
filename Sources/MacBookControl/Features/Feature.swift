import Foundation
import SwiftUI

/// Which of the two processes this is.
///
/// The menu bar and the settings window run separately now, and they are not
/// equals in what they may do to the machine. Anything that goes through the
/// root daemon is safe from either — the daemon is one owner and serialises
/// what it is told. Anything the process holds *itself* is not: an event tap
/// belongs to the process that created it, so two processes with the Pointer
/// tab enabled would rewrite every scroll twice.
///
/// So the window shows and edits; the menu bar owns.
enum ProcessRole {
    /// Set once, in main, before anything is built.
    static var isSettingsWindow = false
}

/// One thing the app is allowed to do to the machine.
///
/// The Enable checkbox is a promise, not a display preference: a feature that
/// is off must leave the hardware exactly as it found it. That is why
/// `deactivate()` exists separately from "stop drawing the UI" — turning
/// Cooling off has to hand the fans back to the firmware, not merely stop
/// showing their speed.
///
/// Subclassing rather than a protocol: SwiftUI needs an `ObservableObject` it
/// can hold onto, and a protocol with an associated view type cannot go in a
/// heterogeneous array of tabs.
class Feature: ObservableObject, Identifiable {
    /// Stable across releases — it keys the stored enable flag, so renaming it
    /// silently resets the user's choice.
    let id: String
    /// Tab label. Short: it sits in a row with eight others.
    let title: String
    /// One line under the checkbox saying what turning this on will do.
    let summary: String

    @Published private(set) var isEnabled: Bool

    init(id: String, title: String, summary: String) {
        self.id = id
        self.title = title
        self.summary = summary
        self.isEnabled = Preferences.featureEnabled(id)
    }

    /// Whether this machine can do it at all. A feature that answers `false`
    /// shows its reason instead of its controls rather than disappearing —
    /// a missing tab reads as a bug, an explained one reads as an answer.
    var isSupported: Bool { true }
    var unsupportedReason: String? { nil }

    /// Called when the user ticks the box, and once at launch for features
    /// already enabled. Must be safe to call twice.
    func activate() {}

    /// Called when the user unticks the box, and on quit. Must return the
    /// machine to firmware defaults, and be safe to call when never activated.
    func deactivate() {}

    /// The tab body, below the Enable row. Rendered disabled while off.
    ///
    /// `AnyView` rather than `some View`: an opaque return type is pinned to
    /// the concrete type the base class returns, so a subclass could not hand
    /// back its own view at all.
    func makeView() -> AnyView { AnyView(EmptyView()) }

    // MARK: Enable plumbing

    /// Set by whoever owns telemetry, so that switching a feature on or off
    /// re-asks what is worth reading.
    static var needsDidChange: () -> Void = {}

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        guard !enabled || isSupported else { return }
        isEnabled = enabled
        Preferences.setFeatureEnabled(id, enabled)
        enabled ? activate() : deactivate()
        Feature.needsDidChange()
    }

    /// Applies the stored choice at launch. Split from `init` so every feature
    /// exists before any of them touches the hardware.
    /// What this feature needs read while it is enabled, whether or not
    /// anything is displaying it. Most features need nothing: they write to
    /// the machine rather than watch it.
    var telemetryNeeds: Telemetry.Needs { Telemetry.Needs() }

    /// Re-reads everything this feature read when it was built.
    ///
    /// The settings window is another process, and it writes the user's
    /// choices straight to preferences — the copies held here never hear about
    /// it. So whatever a feature reads once, in `init`, has to be readable
    /// again: the two lists must match, and a property in one and not the
    /// other is a setting that silently stops taking effect.
    /// `scripts/check-reload-mirrors-init.sh` compares them.
    ///
    /// Assigning is enough. Every one of these publishes and writes back
    /// through its own `didSet`, which is also what re-applies it.
    func reloadFromPreferences() {}

    func applyStoredState() {
        // The settings window displays and edits. It does not take ownership
        // of the machine at startup: see `ProcessRole`.
        guard !ProcessRole.isSettingsWindow else { return }
        guard isEnabled else { return }
        guard isSupported else {
            // The machine changed under a stored yes (external GPU gone, kext
            // uninstalled). Forget the choice rather than fail on every tick.
            isEnabled = false
            Preferences.setFeatureEnabled(id, false)
            return
        }
        activate()
    }
}

/// The tab order of the Settings window, and the list the app walks at launch
/// and at quit. One place to add a feature.
final class FeatureRegistry: ObservableObject {
    let features: [Feature]

    init(features: [Feature]) {
        self.features = features
    }

    func applyStoredState() { features.forEach { $0.applyStoredState() } }

    /// Hand back what we are actually holding. Called on quit — leaving fans
    /// pinned by a process that no longer exists is the one failure mode that
    /// can cook the machine.
    ///
    /// Only enabled features. Deactivating the rest looks tidy and is wrong:
    /// `TurboBoostFeature.deactivate` re-enables Turbo Boost, so quitting Zephyr
    /// used to switch it back on for someone who had never enabled the tab and
    /// had turned turbo off by other means. A feature that was never asked to
    /// touch the machine must not touch it on the way out either.
    func deactivateAll() { features.filter(\.isEnabled).forEach { $0.deactivate() } }

    /// Brings the enabled flags back in line with what is stored.
    ///
    /// The settings window is a process of its own now. It writes the user's
    /// choices to preferences and applies them to the machine itself, being as
    /// entitled to the daemon as this process is — what it cannot do is reach
    /// into these objects. And the flag is the only thing here that goes
    /// stale: everything else a feature acts on, it reads from preferences at
    /// the moment it acts, which is why re-applying after a wake works at all.
    ///
    /// Safe to call at any time: `setEnabled` does nothing when the answer has
    /// not changed, and `activate` is required to be safe to call twice.
    func reconcileEnabledState() {
        for feature in features {
            // Values first, so a feature being switched on is switched on with
            // what the other process chose and not with what this one
            // remembers from launch.
            feature.reloadFromPreferences()
            feature.setEnabled(Preferences.featureEnabled(feature.id))
        }
    }

    func feature(id: String) -> Feature? { features.first { $0.id == id } }
}
