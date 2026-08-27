import Foundation
import IOKit
import IOKit.pwr_mgt

/// Why the Mac did not sleep, why it woke, and how it last went off.
///
/// All of it is read from the power-management registry and none of it needs
/// privileges — which is the whole reason it is worth doing here rather than
/// leaving people to install something else for it.
///
/// Read on demand, never on a timer of its own: assertions change when an
/// application decides they should, and the wake and shutdown records change
/// once per sleep and once per boot.
enum SleepDiagnostics {

    /// Something holding the machine awake, and who is holding it.
    struct Assertion: Identifiable {
        let pid: Int
        let process: String
        let kind: String
        let name: String
        let since: Date?

        var id: String { "\(pid)/\(kind)/\(name)" }

        /// What it actually prevents, in words rather than in Apple's key
        /// names — which are the same words with the letters run together.
        var effect: String {
            switch kind {
            case kIOPMAssertionTypePreventUserIdleDisplaySleep: return "keeps the display on"
            case kIOPMAssertionTypePreventUserIdleSystemSleep: return "keeps the Mac awake"
            case kIOPMAssertionTypePreventSystemSleep: return "keeps the Mac awake"
            case kIOPMAssertionTypeNoIdleSleep: return "keeps the Mac awake"
            case kIOPMAssertionTypeNoDisplaySleep: return "keeps the display on"
            default: return kind
            }
        }
    }

    /// Only the assertions that actually stop something from sleeping.
    ///
    /// The registry also carries a dozen bookkeeping assertions — "user is
    /// active", "network client active" — that hold nothing awake by
    /// themselves. Listing them would bury the one line that answers the
    /// question.
    private static let blocking: Set<String> = [
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionTypePreventSystemSleep,
        kIOPMAssertionTypeNoIdleSleep,
        kIOPMAssertionTypeNoDisplaySleep,
    ]

    static func assertions() -> [Assertion] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }

        var found: [Assertion] = []
        for (pidNumber, entries) in byProcess {
            for entry in entries {
                guard let kind = entry[kIOPMAssertionTypeKey] as? String,
                      blocking.contains(kind) else { continue }
                found.append(Assertion(
                    pid: pidNumber.intValue,
                    process: entry["Process Name"] as? String ?? "pid \(pidNumber)",
                    kind: kind,
                    name: entry[kIOPMAssertionNameKey] as? String ?? "",
                    // Spelled out rather than taken from a constant: the
                    // start date has a documented key name but no symbol
                    // exported to Swift.
                    since: entry["AssertStartWhen"] as? Date))
            }
        }
        // Longest-held first: the one that has been holding the machine awake
        // all afternoon is the one being looked for.
        return found.sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }

    // MARK: The power record

    struct PowerRecord {
        /// What woke the machine last — "EC.USBC", "OHC1", the lid, a key.
        let wakeReason: String?
        /// Whether that was a full wake or one of the maintenance wakes that
        /// run with the screen dark.
        let wakeType: String?
        let sleepReason: String?
        /// The SMC's own account of how the machine last went off.
        let shutdownCause: Int?

        /// Only one of these codes has a meaning this app has actually seen
        /// the system print, so it is the only one named. The rest are shown
        /// as the number they are rather than guessed at from a table nobody
        /// has verified.
        var shutdownDescription: String? {
            guard let code = shutdownCause else { return nil }
            return code == 1 ? "normal warm reset" : "code \(code)"
        }
    }

    static func powerRecord() -> PowerRecord {
        let rootDomain = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                     IOServiceMatching("IOPMrootDomain"))
        defer { if rootDomain != 0 { IOObjectRelease(rootDomain) } }

        let smc = IOServiceGetMatchingService(kIOMasterPortDefault,
                                              IOServiceMatching("AppleSMC"))
        defer { if smc != 0 { IOObjectRelease(smc) } }

        return PowerRecord(
            wakeReason: nonEmpty(string(rootDomain, "Wake Reason")),
            wakeType: nonEmpty(string(rootDomain, "Wake Type")),
            sleepReason: nonEmpty(string(rootDomain, "Last Sleep Reason")),
            shutdownCause: string(smc, "ShutdownCause").flatMap(Int.init))
    }

    private static func string(_ service: io_service_t, _ key: String) -> String? {
        guard service != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(service, key as CFString,
                                               kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        return value
    }
}
