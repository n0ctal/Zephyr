import Foundation
import SwiftUI

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

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        guard !enabled || isSupported else { return }
        isEnabled = enabled
        Preferences.setFeatureEnabled(id, enabled)
        enabled ? activate() : deactivate()
    }

    /// Applies the stored choice at launch. Split from `init` so every feature
    /// exists before any of them touches the hardware.
    func applyStoredState() {
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

    /// Hand everything back to the firmware. Called on quit — leaving fans
    /// pinned by a process that no longer exists is the one failure mode that
    /// can cook the machine.
    func deactivateAll() { features.forEach { $0.deactivate() } }

    func feature(id: String) -> Feature? { features.first { $0.id == id } }
}
