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
            for placement in wanted {
                // By title first: a window that was second in the list may be
                // first by the time it comes back, and moving the wrong window
                // is worse than moving none.
                let match = windows.first {
                    !placement.title.isEmpty
                        && (attribute($0, kAXTitleAttribute) as? String) == placement.title
                } ?? (windows.indices.contains(placement.index) ? windows[placement.index] : nil)
                guard let window = match, frame(of: window) != placement.frame else { continue }
                set(window, kAXPositionAttribute, placement.frame.origin)
                set(window, kAXSizeAttribute, placement.frame.size)
                restored += 1
            }
        }
        return restored
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
