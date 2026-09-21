import Foundation
import IOKit.pwr_mgt

/// Holds macOS awake by taking power-management assertions.
///
/// Three separate assertions rather than one, because they answer different
/// questions and people want different combinations:
///
/// - `PreventUserIdleSystemSleep` — the machine does not fall asleep on its
///   own. The lid must stay open; shutting it still sleeps.
/// - `PreventUserIdleDisplaySleep` — the screen stays lit. Independent of the
///   above: a long build wants the machine awake and the screen off.
/// - `PreventSystemSleep` — survives a closed lid, but only while power is
///   attached. On battery the firmware sleeps regardless, which is why the
///   lid-closed option is tied to being plugged in rather than offered alone.
///
/// The assertion type names are passed as literals: the `kIOPMAssertionType*`
/// constants arrive in Swift inconsistently across SDK versions, and a wrong
/// import silently yields an assertion nobody honours.
final class SleepInhibitor {
    private enum Kind: String, CaseIterable {
        case system  = "PreventUserIdleSystemSleep"
        case display = "PreventUserIdleDisplaySleep"
        case lidShut = "PreventSystemSleep"
    }

    private var held: [Kind: IOPMAssertionID] = [:]
    private var expiry: DispatchWorkItem?

    /// True while anything is being held.
    var isActive: Bool { !held.isEmpty }

    /// Applies the requested combination, releasing whatever no longer applies.
    /// Idempotent: calling it with the same arguments changes nothing.
    ///
    /// `minutes == 0` means indefinite. A non-zero value schedules a release
    /// rather than using IOKit's own timeout, so the countdown survives the
    /// assertion being re-taken with different options.
    func apply(keepSystemAwake: Bool, keepDisplayOn: Bool, throughLidClose: Bool, minutes: Int) {
        var wanted: Set<Kind> = []
        if keepSystemAwake { wanted.insert(.system) }
        if keepDisplayOn { wanted.insert(.display) }
        if throughLidClose { wanted.insert(.lidShut) }

        for kind in Kind.allCases where !wanted.contains(kind) { release(kind) }
        for kind in wanted where held[kind] == nil { take(kind) }

        expiry?.cancel()
        expiry = nil
        guard minutes > 0, !wanted.isEmpty else { return }
        let item = DispatchWorkItem { [weak self] in self?.releaseAll() }
        expiry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(minutes * 60), execute: item)
    }

    func releaseAll() {
        expiry?.cancel()
        expiry = nil
        Kind.allCases.forEach(release)
    }

    /// Whether an active hold will still be honoured. `PreventSystemSleep` is
    /// ignored on battery, so a lid-closed hold silently stops working when
    /// the charger is pulled — worth saying out loud in the UI rather than
    /// letting the machine sleep mid-task.
    static var isOnExternalPower: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if state == kIOPSACPowerValue { return true }
        }
        return false
    }

    // MARK: Assertion plumbing

    /// Takes an assertion, in the process that owns the machine.
    ///
    /// A power assertion belongs to the process that made it and is released
    /// when that process ends — and the settings window ends every time it is
    /// closed. Held there, "keep awake" would have lasted exactly as long as
    /// somebody was looking at the switch. The choice is written down; the
    /// menu bar holds the assertion.
    private func take(_ kind: Kind) {
        guard ProcessRole.ownsTheMachine else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kind.rawValue as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Zephyr keeps this Mac awake" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return }
        held[kind] = id
    }

    private func release(_ kind: Kind) {
        guard let id = held.removeValue(forKey: kind) else { return }
        IOPMAssertionRelease(id)
    }

    deinit { releaseAll() }
}
