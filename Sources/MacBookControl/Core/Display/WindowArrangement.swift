import AppKit
import ApplicationServices

/// Where every window was, so it can be put back.
///
/// macOS herds every window onto whatever screen is left when one goes away,
/// and puts none of them back when it returns. That is the whole of Display
/// Maid, and it is the first thing anybody notices after switching a panel off
/// and on again: the desktop comes back and the work does not.
///
/// Read and written through the accessibility interface — the same permission
/// the Pointer section already asks for. Without it, this does nothing at all
/// and says so rather than pretending.
enum WindowArrangement {

    struct Placement {
        let pid: pid_t
        /// The window's title, which survives the window being reordered.
        /// Untitled windows fall back to their index in the application's own
        /// list, which is the best that is on offer.
        let title: String
        let index: Int
        let frame: CGRect
    }

    static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Every window of every ordinary application, with where it sits now.
    static func capture() -> [Placement] {
        guard isPermitted else { return [] }
        var placements: [Placement] = []
        for application in NSWorkspace.shared.runningApplications
        where application.activationPolicy == .regular {
            let element = AXUIElementCreateApplication(application.processIdentifier)
            guard let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else {
                continue
            }
            for (index, window) in windows.enumerated() {
                guard let frame = frame(of: window) else { continue }
                placements.append(Placement(pid: application.processIdentifier,
                                            title: (attribute(window, kAXTitleAttribute) as? String) ?? "",
                                            index: index,
                                            frame: frame))
            }
        }
        return placements
    }

    /// Puts them back where they were, skipping anything that has closed or
    /// already sits where it belongs.
    @discardableResult
    static func restore(_ placements: [Placement]) -> Int {
        guard isPermitted else { return 0 }
        var restored = 0
        let byProcess = Dictionary(grouping: placements, by: \.pid)
        for (pid, wanted) in byProcess {
            let element = AXUIElementCreateApplication(pid)
            guard let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else {
                continue
            }
            // Titles read once rather than once per placement: each is a call
            // across the accessibility interface, and matching walked the list
            // again for every window being put back.
            let titles = windows.map { (attribute($0, kAXTitleAttribute) as? String) ?? "" }
            for (placement, index) in pairings(of: wanted, against: titles) {
                let window = windows[index]
                guard frame(of: window) != placement.frame else { continue }
                set(window, kAXPositionAttribute, placement.frame.origin)
                set(window, kAXSizeAttribute, placement.frame.size)
                restored += 1
            }
        }
        return restored
    }

    /// Which window each placement belongs to: by title first, by the position
    /// it held second, and never the same window twice.
    ///
    /// The last clause is the one that was missing. Two windows of one
    /// application can carry the same title — two Finder windows on the same
    /// folder, or two that have none at all — and taking the first match for
    /// each placement put both of them on that one window: it ended up where
    /// the second placement said, and the other window never moved.
    ///
    /// Sorted by the position each window held, so that where the fallback is
    /// what decides, it decides the same way every time.
    ///
    /// Pure, and separate from the accessibility calls, because a wrong answer
    /// here moves somebody's windows to the wrong place and that is not a
    /// thing to find out by trying it.
    static func pairings(of placements: [Placement],
                         against titles: [String]) -> [(Placement, Int)] {
        var used = Set<Int>()
        var result: [(Placement, Int)] = []
        for placement in placements.sorted(by: { $0.index < $1.index }) {
            let byTitle = titles.indices.first {
                !used.contains($0) && !placement.title.isEmpty && titles[$0] == placement.title
            }
            let byPosition = titles.indices.contains(placement.index)
                && !used.contains(placement.index) ? placement.index : nil
            guard let index = byTitle ?? byPosition else { continue }
            used.insert(index)
            result.append((placement, index))
        }
        return result
    }

    // MARK: The accessibility interface, in three lines

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(window, kAXPositionAttribute),
              let sizeValue = attribute(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private static func set(_ window: AXUIElement, _ name: String, _ point: CGPoint) {
        var value = point
        guard let wrapped = AXValueCreate(.cgPoint, &value) else { return }
        AXUIElementSetAttributeValue(window, name as CFString, wrapped)
    }

    private static func set(_ window: AXUIElement, _ name: String, _ size: CGSize) {
        var value = size
        guard let wrapped = AXValueCreate(.cgSize, &value) else { return }
        AXUIElementSetAttributeValue(window, name as CFString, wrapped)
    }
}
