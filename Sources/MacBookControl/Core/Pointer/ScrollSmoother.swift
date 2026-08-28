import CoreGraphics
import Foundation

/// Turns a wheel notch into a short glide instead of a jump.
///
/// A trackpad already has this: the system generates a stream of pixel
/// deltas and a decaying tail when the fingers lift. A notched wheel gets
/// none of it — one notch is one lump of three lines, which is what makes a
/// mouse feel coarse next to the trackpad on the same machine.
///
/// So the notch is swallowed and paid out over a handful of frames. The
/// events posted are continuous pixel scrolls, which is what a trackpad
/// sends, so applications that treat the two differently see the kind they
/// already handle smoothly.
final class ScrollSmoother {
    struct Tuning: Equatable {
        /// How much of what is left is paid out each frame. Larger is faster
        /// and closer to the original lump; smaller glides longer.
        var factor: Double = 0.25
        /// Frames per second to pay out at.
        var rate: Double = 60
        /// Pixels per line, for turning a line-based notch into a distance.
        var pixelsPerLine: Double = 10
    }

    var tuning = Tuning()
    /// Marks what this posts, so the tap that feeds it does not feed it again.
    var signature: Int64 = 0

    private var pending = (x: 0.0, y: 0.0)
    private var timer: Timer?

    var isGliding: Bool { timer != nil }

    /// Adds a distance in pixels to whatever is still in flight.
    ///
    /// Adding rather than replacing is the point: spinning the wheel three
    /// notches quickly should travel three notches' worth, not restart the
    /// glide from the last one.
    func add(x: Double, y: Double) {
        pending.x += x
        pending.y += y
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / max(tuning.rate, 1), repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Common modes, or the glide stops dead while a menu is open or a
        // window is being resized — exactly when a scroll is still in flight.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        pending = (0, 0)
    }

    private func tick() {
        let stepX = Self.step(remaining: pending.x, factor: tuning.factor)
        let stepY = Self.step(remaining: pending.y, factor: tuning.factor)
        pending.x -= stepX
        pending.y -= stepY

        // Whole pixels go out; the fraction stays behind for the next frame,
        // so a slow tail still moves rather than rounding itself away.
        let outX = Int32(stepX.rounded(.towardZero))
        let outY = Int32(stepY.rounded(.towardZero))
        pending.x += stepX - Double(outX)
        pending.y += stepY - Double(outY)

        if outX != 0 || outY != 0, let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: outY, wheel2: outX, wheel3: 0) {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: signature)
            event.post(tap: .cgSessionEventTap)
        }

        if abs(pending.x) < 0.5 && abs(pending.y) < 0.5 {
            pending = (0, 0)
            timer?.invalidate()
            timer = nil
        }
    }

    /// What to pay out this frame.
    ///
    /// Exponential decay, with a floor: a fixed fraction of a small remainder
    /// is smaller still, so without the floor the glide approaches the target
    /// forever and the timer never stops. Below a pixel the rest goes out at
    /// once.
    static func step(remaining: Double, factor: Double) -> Double {
        guard remaining != 0 else { return 0 }
        let step = remaining * min(max(factor, 0.05), 1)
        return abs(step) < 1 ? remaining : step
    }

    /// The whole glide, for checking that it arrives and how long it takes.
    static func glide(distance: Double, factor: Double, limit: Int = 600) -> [Double] {
        var remaining = distance
        var steps: [Double] = []
        while remaining != 0 && steps.count < limit {
            let step = self.step(remaining: remaining, factor: factor)
            steps.append(step)
            remaining -= step
        }
        return steps
    }
}
