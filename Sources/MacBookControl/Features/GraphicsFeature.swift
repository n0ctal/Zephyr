import SwiftUI

/// Which GPU the machine is allowed to use.
///
/// Uses `pmset -a gpuswitch`, Apple's own supported lever, rather than the
/// private framework calls the old third-party tools reached for — the policy
/// then survives reboots and is honoured by the system instead of fighting it.
///
/// Setting the policy once is not enough. macOS hands the discrete GPU to
/// anything that asks for it, and the choice then quietly stops holding while
/// the UI still claims it. So the policy is watched and re-asserted whenever
/// the active GPU drifts away from what was asked for — the difference
/// between a switch that reports a wish and one that enforces it.
final class GraphicsFeature: Feature {
    private let helper: HelperClient
    private let gpu: GPUController

    @Published var mode: GPUMode
    @Published private(set) var info: GPUInfo
    /// How many times the choice had to be pushed back this session. A number
    /// that keeps climbing means something is holding the other GPU open, and
    /// that is worth seeing rather than silently losing the argument.
    @Published private(set) var reassertCount = 0

    private var watchdog: Timer?
    private var lastReassert: Date?

    init(helper: HelperClient, gpu: GPUController) {
        self.helper = helper
        self.gpu = gpu
        self.mode = GPUMode(rawValue: Preferences.gpuMode) ?? .automatic
        self.info = gpu.info()
        super.init(id: "graphics",
                   title: "Graphics",
                   summary: "Pin the machine to the integrated GPU for battery and quiet, or to the discrete one for consistent performance.")
    }

    override var isSupported: Bool { info.discreteName != nil }
    override var unsupportedReason: String? {
        isSupported ? nil : "This Mac has a single GPU, so there is nothing to switch between."
    }

    override func reloadFromPreferences() {
        mode = GPUMode(rawValue: Preferences.gpuMode) ?? .automatic
    }

    override func activate() {
        helper.setGPUMode(mode)
        startWatchdog()
    }

    /// Back to Apple's automatic switching — the state the machine shipped in.
    override func deactivate() {
        stopWatchdog()
        helper.setGPUMode(.automatic)
    }

    // MARK: Holding the choice

    /// Re-asserts the policy when the machine drifts off it.
    ///
    /// Rate-limited rather than fired on every drift: each re-assert spawns
    /// `pmset`, and an app that holds the discrete GPU open will lose the
    /// argument repeatedly, which would otherwise become a process storm.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.reassertIfDrifted()
        }
        // Let the system line this wake-up up with others; nothing here
        // needs to land on the second.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func reassertIfDrifted() {
        guard isEnabled, mode != .automatic else { return }
        // Compares the *policy*, not which GPU is rendering. Asking Metal which
        // device is active means creating one, and creating a Metal device can
        // itself wake the discrete GPU — a watchdog that woke the very thing it
        // was guarding against would be worse than no watchdog. Reading the
        // policy costs a millisecond and touches nothing.
        guard let live = gpu.currentMode(), live != mode else {
            lastReassert = nil
            return
        }
        // Something took the GPU we did not want. Push back, but no more than
        // once every half minute: if an app is holding it open we cannot win,
        // and hammering pmset helps nobody.
        let now = Date()
        if let last = lastReassert, now.timeIntervalSince(last) < 30 { return }
        lastReassert = now
        reassertCount += 1
        helper.setGPUMode(mode)
    }

    func setMode(_ newMode: GPUMode) {
        mode = newMode
        Preferences.gpuMode = newMode.rawValue
        reassertCount = 0
        lastReassert = nil
        guard isEnabled else { return }
        helper.setGPUMode(newMode)
        newMode == .automatic ? stopWatchdog() : startWatchdog()
    }

    /// Called when the tab is on screen. This is the one place that asks
    /// which GPU is rendering, because asking costs a Metal device.
    func refresh() { info = gpu.info(includeActive: true) }

    override func makeView() -> AnyView { AnyView(GraphicsView(feature: self)) }
}

private struct GraphicsView: View {
    @ObservedObject var feature: GraphicsFeature
    /// Polled only while this section is on screen — see `Polled`. Five
    /// seconds because processes take and drop the card as windows open, and
    /// the card they are rendering on changes with them: one poll answers
    /// both, rather than a timer for one and a single reading on appear for
    /// the other.
    @StateObject private var holders = Polled(every: 5) {
        AcceleratorClients.discreteHolders()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SegmentedChoice(label: "Use",
                            selection: Binding(get: { feature.mode },
                                               set: { feature.setMode($0) }),
                            options: GPUMode.allCases.map { ($0.label, $0) })

            VStack(alignment: .leading, spacing: 4) {
                if let integrated = feature.info.integratedName {
                    Text("Integrated: \(integrated)").font(.subheadline)
                }
                if let discrete = feature.info.discreteName {
                    Text("Discrete: \(discrete)").font(.subheadline)
                }
                if let active = feature.info.activeName {
                    Text("Rendering now: \(active)").font(.subheadline).foregroundColor(.secondary)
                }
            }

            if feature.reassertCount > 0 {
                Text("Put back \(feature.reassertCount) time\(feature.reassertCount == 1 ? "" : "s") this session — something keeps asking for the other GPU.")
                    .font(.caption).foregroundColor(.orange)
            }

            // Naming the culprit, which the line above could only ever hint
            // at. Every client of an accelerator records the process that
            // opened it, so this is the same answer gfxCardStatus gives.
            if let holding = holders.value, !holding.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Running work on the discrete card").font(.subheadline)
                    Text(holding.map(\.name).joined(separator: ", "))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Zephyr re-asserts this every few seconds instead of setting it once, because macOS hands the discrete GPU to whatever asks. It still cannot pull the GPU out from under a running renderer — quit the app holding it and the choice takes hold.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { feature.refresh() }
        .onReceive(holders.$value) { _ in feature.refresh() }
        .polling(holders)
    }
}
