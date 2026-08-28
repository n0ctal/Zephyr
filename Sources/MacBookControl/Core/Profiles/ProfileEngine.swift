import Foundation

/// Decides which profile is in force and applies it once.
///
/// The important word is *once*. Re-applying every tick would mean the app
/// silently undoing anything changed by hand — move a fan slider and watch it
/// snap back, with nothing saying why. So a profile is applied when it takes
/// over, and not again until the circumstances change to a different one. A
/// manual change therefore stands until the context genuinely moves.
///
/// When several profiles match, the first in the list wins. Order is the
/// user's, which makes "more specific above more general" expressible without
/// inventing a priority number for them to maintain.
final class ProfileEngine {
    private(set) var activeProfile: Profile?
    /// Set when the last evaluation found nothing, so the UI can distinguish
    /// "no profile applies" from "not evaluated yet".
    private(set) var hasEvaluated = false

    private unowned let registry: FeatureRegistry
    private let telemetry: Telemetry

    init(registry: FeatureRegistry, telemetry: Telemetry) {
        self.registry = registry
        self.telemetry = telemetry
    }

    /// Returns true when the active profile changed.
    @discardableResult
    func evaluate(_ profiles: [Profile]) -> Bool {
        hasEvaluated = true
        let context = Context.sample(telemetry: telemetry)
        let winner = Profile.firstMatching(profiles, in: context)
        guard winner?.id != activeProfile?.id else { return false }
        activeProfile = winner
        if let winner = winner { apply(winner) }
        return true
    }

    /// Forces a re-apply of whatever is active. Used when a profile is edited:
    /// the circumstances have not changed, but what they should produce has.
    func reapply() {
        guard let active = activeProfile else { return }
        apply(active)
    }

    func forget() { activeProfile = nil }

    // MARK: Applying

    private func apply(_ profile: Profile) {
        for action in profile.actions {
            switch action {
            case .coolingMode(let mode):
                cooling?.mode = mode
            case .fanCurve(let min, let max):
                cooling?.curveMin = min
                cooling?.curveMax = max
            case .turboDisabled(let disabled):
                turbo?.setTurboDisabled(disabled)
            case .gpuMode(let raw):
                if let mode = GPUMode(rawValue: raw) { graphics?.setMode(mode) }
            case .chargeLimit(let percent):
                battery?.setLimit(percent)
            case .keepAwake(let on):
                // A profile can only ask for something the user has allowed:
                // switching a feature on from here would let a rule turn on a
                // capability that was deliberately left off.
                awake?.setEnabledByProfile(on)
            case .pointerAcceleration(let value):
                pointer?.setAccelerationByProfile(value)
            }
        }
    }

    private var cooling: CoolingFeature? { registry.feature(id: "cooling") as? CoolingFeature }
    private var turbo: TurboBoostFeature? { registry.feature(id: "turbo") as? TurboBoostFeature }
    private var graphics: GraphicsFeature? { registry.feature(id: "graphics") as? GraphicsFeature }
    private var battery: BatteryFeature? { registry.feature(id: "battery") as? BatteryFeature }
    private var awake: AwakeFeature? { registry.feature(id: "awake") as? AwakeFeature }
    private var pointer: PointerFeature? { registry.feature(id: "pointer") as? PointerFeature }
}
