import Foundation

/// A tap on the shoulder between the two processes.
///
/// The settings window writes the user's choices down; the menu bar owns the
/// machine and acts on them. What was missing was the moment in between — the
/// window had no way to say "look again", so a change sat in preferences until
/// the window was closed. Dragging the scroll speed did nothing you could
/// feel, and the graphics watchdog spent five seconds arguing with a mode the
/// window had just set.
///
/// It carries nothing, and that is the design rather than a limitation:
/// preferences are the message and this is only the knock. Which is also what
/// makes it safe — a knock that goes missing costs a late reading and never a
/// wrong one, and the same knock arriving twice is free.
enum CrossProcess {
    /// Distributed rather than Darwin's own `notify_post`, which would have
    /// been lighter: `notify.h` is not visible to Swift without a C target,
    /// and adding one to carry nothing is a worse trade than the heavier
    /// mechanism. Measured across two processes, delivery is immediate.
    private static let changed = Notification.Name("com.n0ctal.zephyr.preferences-changed")

    /// Says that something was written. Called from the settings process.
    static func announceChange() {
        DistributedNotificationCenter.default().postNotificationName(
            changed, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Listens, from the menu-bar process. The handler runs on the main queue.
    ///
    /// Coalesced: a slider being dragged writes on every frame, and each write
    /// would otherwise ask every feature to re-read itself. A tenth of a
    /// second is under what a hand notices and above what a drag produces.
    static func onChange(_ handler: @escaping () -> Void) {
        var pending: DispatchWorkItem?
        DistributedNotificationCenter.default().addObserver(
            forName: changed, object: nil, queue: .main
        ) { _ in
            pending?.cancel()
            let item = DispatchWorkItem(block: handler)
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }
    }

    /// Announces every write this process makes, for as long as it runs.
    ///
    /// One hook rather than a call beside each setter: a preference added
    /// later would not know to announce itself, and the failure would be the
    /// quiet kind — one setting, and only that one, no longer taking effect
    /// until the window is closed.
    static func announceEveryChange() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in announceChange() }
    }
}
