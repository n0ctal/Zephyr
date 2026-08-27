import Foundation
import Combine
import SwiftUI

/// A reading that is taken only while something is looking at it.
///
/// The whole point of this app is that it costs the machine as little as
/// possible, and most of what it shows is not worth a timer of its own: drive
/// health moves once a month, sleep assertions move when an application
/// decides they should, and the list of processes holding the graphics card
/// only matters while that section is open.
///
/// So these readings are attached to their view. The timer starts when the
/// view appears and stops when it goes away, and each read happens off the
/// main thread — with a closed section, or a closed window, the cost is
/// exactly nothing.
/// One queue for every polled reading in the app. They are serialised by each
/// object's own in-flight guard, and a queue each made them indistinguishable
/// from one another in a profiler.
enum PolledQueue {
    static let shared = DispatchQueue(label: "com.n0ctal.zephyr.polled", qos: .utility)
}

final class Polled<Value: Equatable>: ObservableObject {
    @Published private(set) var value: Value?
    /// Whether a read has finished at all. "Not looked yet" and "looked and
    /// there is nothing" are different answers, and showing the second while
    /// the first is true tells people their drive has no health page a tenth
    /// of a second before it appears.
    @Published private(set) var hasRead = false

    private let interval: TimeInterval
    private let read: () -> Value?
    
    private var timer: Timer?
    private var watchers = 0
    private var isReading = false
    private var lastReadAt: Date?

    init(every interval: TimeInterval, read: @escaping () -> Value?) {
        self.interval = interval
        self.read = read
    }

    /// Called from `onAppear`. Counted rather than a flag: a section can be
    /// built twice during a layout pass, and the second teardown must not stop
    /// a timer the first appearance still wants.
    func begin() {
        watchers += 1
        guard watchers == 1 else { return }
        // Only if the last reading has actually gone stale. Switching between
        // sections tears these down and builds them again, and re-reading a
        // drive's health page — or every launchd plist on the machine —
        // because somebody clicked Diagnostics twice is work for nothing.
        if lastReadAt.map({ Date().timeIntervalSince($0) >= interval }) ?? true {
            refresh()
        }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // These fire at 5, 30 and 300 seconds and none of them needs to be
        // punctual. A tolerance lets the kernel wake once for several of them,
        // which on a laptop is the difference that matters.
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func end() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        // A slow read must not queue up behind itself; skipping a tick is
        // harmless when the thing being read moves this rarely.
        guard !isReading else { return }
        isReading = true
        PolledQueue.shared.async { [weak self] in
            guard let self = self else { return }
            let fresh = self.read()
            // Handed back through the run loop rather than the main dispatch
            // queue, and in the common modes: a block on the main queue is not
            // delivered while a menu is tracking or a slider is being dragged,
            // which is exactly when a reading is most likely to be watched.
            RunLoop.main.perform(inModes: [.common]) {
                // Assigned only when it differs: `@Published` announces a
                // change on every assignment, and a section of forty formatted
                // rows redrawing five times a minute to show the same numbers
                // is the cost of not checking.
                if let fresh = fresh, fresh != self.value { self.value = fresh }
                if !self.hasRead { self.hasRead = true }
                self.lastReadAt = Date()
                self.isReading = false
            }
        }
    }

    deinit { timer?.invalidate() }
}

extension View {
    /// Ties a polled reading to this view's life on screen.
    func polling<Value>(_ polled: Polled<Value>) -> some View {
        onAppear { polled.begin() }.onDisappear { polled.end() }
    }
}
