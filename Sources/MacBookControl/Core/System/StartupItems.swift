import Foundation

/// What starts with the machine, and where it was installed from.
///
/// The read-only half of what KnockKnock is used for: not "is this
/// malware" — that is a judgement no local list can make — but "here is
/// everything that arranged to run without being asked, and where it lives".
/// Most of it is legitimate and forgotten; the value is in seeing it at all.
///
/// Directory listings and property lists, so it needs no privileges and takes
/// a few milliseconds. Read only while the section showing it is open.
enum StartupItems {

    struct Item: Identifiable, Comparable {
        /// The launchd label, which is what `launchctl` calls it.
        let label: String
        /// The first argument of the thing it runs, which is the part worth
        /// reading — a label can say anything.
        let program: String?
        let scope: Scope
        let path: URL

        var id: String { path.path }

        /// Apple's own agents are the bulk of any list like this and are not
        /// what anyone is looking for.
        var isApple: Bool { label.hasPrefix("com.apple.") }

        static func < (lhs: Item, rhs: Item) -> Bool {
            lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
        /// Every field, not just the path: a poll that finds the same file
        /// pointing somewhere new has found a change.
        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.path == rhs.path && lhs.label == rhs.label
                && lhs.program == rhs.program && lhs.scope == rhs.scope
        }
    }

    enum Scope: String, CaseIterable {
        case userAgent = "Runs when you log in"
        case systemAgent = "Runs when anyone logs in"
        case daemon = "Runs before anyone logs in"

        var directory: URL {
            switch self {
            case .userAgent:
                return FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/LaunchAgents")
            case .systemAgent: return URL(fileURLWithPath: "/Library/LaunchAgents")
            case .daemon: return URL(fileURLWithPath: "/Library/LaunchDaemons")
            }
        }
    }

    /// Everything installed outside the operating system's own directories.
    ///
    /// `/System/Library` is deliberately not read: it is Apple's, it is
    /// sealed, and it would bury the twenty entries that came from software
    /// somebody installed under six hundred that came with the machine.
    static func all() -> [Item] {
        Scope.allCases.flatMap { items(in: $0) }.sorted()
    }

    private static func items(in scope: Scope) -> [Item] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: scope.directory, includingPropertiesForKeys: nil)) ?? []
        return contents.compactMap { url in
            guard url.pathExtension == "plist",
                  let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any]
            else { return nil }
            return Item(label: plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent,
                        program: program(from: plist),
                        scope: scope,
                        path: url)
        }
    }

    /// launchd accepts either a single program or an argument vector, and the
    /// vector is the common form.
    private static func program(from plist: [String: Any]) -> String? {
        if let program = plist["Program"] as? String { return program }
        return (plist["ProgramArguments"] as? [String])?.first
    }
}
