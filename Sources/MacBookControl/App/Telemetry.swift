import Foundation
import Combine

/// The one place that polls the hardware.
///
/// Every tab and the menu-bar title read from here instead of opening their
/// own SMC connection: the SMC is a single serialised device, and eight
/// independent pollers turn a 2-second refresh into eight round trips that
/// can stall each other. It also means every part of the UI shows the same
/// numbers from the same instant.
final class Telemetry: ObservableObject {
    @Published private(set) var temperatures: [TemperatureReading] = []
    @Published private(set) var fans: [FanReading] = []
    @Published private(set) var battery: BatteryStatus?
    /// Optional rather than a zeroed default: "not read yet" and "read, and
    /// nothing is capped" are different answers, and a fake nominal reading
    /// would show a reassuring dash before the first poll.
    @Published private(set) var thermal: ThermalStatus?
    /// Nil until two samples exist: load is a rate, and the first reading has
    /// nothing to subtract from.
    @Published private(set) var load: SystemLoad.Snapshot?
    /// Also nil until two samples exist, and for the same reason: a network
    /// speed is a difference between two totals.
    @Published private(set) var network: NetworkThroughput.Snapshot?

    /// Accumulated across the session, so "is it throttling" can be answered
    /// for the time nobody was looking.
    private(set) var stats = ThermalStats()

    private let sensors: SensorReader?
    private let fanController: FanController?
    private let thermalMonitor = ThermalMonitor()
    private let batteryReader = BatteryReader()
    private let systemLoad = SystemLoad()
    private let throughput = NetworkThroughput()
    private var timer: Timer?

    /// Reading happens here, never on the main thread. The SMC answers one key
    /// per IOKit round trip and this reads a few dozen of them; doing that
    /// where the UI lives makes every tick a visible stall, which is exactly
    /// how the settings window came to feel slow to open.
    private let queue = DispatchQueue(label: "com.n0ctal.zephyr.telemetry", qos: .utility)
    private var isReading = false
    /// Set when a refresh was asked for while one was already running with a
    /// smaller set of needs. Without it, opening the window can hand the
    /// pickers a list of one sensor: the immediate read is dropped as
    /// duplicate and the read already in flight — taken for a closed window —
    /// is what lands.
    private var needsAnotherRead = false

    /// Seconds between reads. Also the unit `ThermalStats` integrates over, so
    /// changing it here keeps the "held back for" figure honest.
    /// The default, and the floor the pickers offer.
    static let interval: TimeInterval = 2

    /// How often to actually read.
    ///
    /// One timer serves both the window and the menu bar, running at whichever
    /// of the two wants readings sooner. Reading twice on two schedules would
    /// cost two sensor sweeps to produce the same numbers, so what the second
    /// setting really buys is this: with the window shut, the rate drops to
    /// the menu bar's, which is the case worth saving.
    var interval: TimeInterval {
        isWindowOpen
            ? Swift.min(Preferences.windowPollSeconds, Preferences.menuBarPollSeconds)
            : Preferences.menuBarPollSeconds
    }

    /// Restarts the timer when the interval it was started with is stale.
    func retune() {
        guard timer != nil, timer?.timeInterval != interval else { return }
        stop()
        start()
    }

    /// True while the settings window is on screen.
    ///
    /// With it closed, the only thing reading any of this is the menu bar, and
    /// the menu bar shows a handful of fields chosen by hand. Everything else
    /// can be left unread until somebody looks.
    var isWindowOpen = false {
        didSet {
            guard isWindowOpen != oldValue else { return }
            // The two states read at different rates, so the timer has to be
            // rebuilt rather than left running at whatever it started with.
            retune()
            guard isWindowOpen else { return }
            refresh()   // fill the window immediately rather than in two seconds
        }
    }

    /// What is worth reading on this tick.
    ///
    /// Every field here costs IOKit round trips, and the expensive one is the
    /// sensor sweep: forty-eight keys on this machine, read one at a time.
    /// With the window closed and a temperature in the menu bar, exactly one
    /// of those forty-eight is wanted.
    struct Needs: Equatable {
        /// Everything, because a window is open and shows all of it — the
        /// sweep of every sensor for the pickers, and the accelerator's busy
        /// fraction for the corner readout. Those two are only ever wanted
        /// together, which is why they are one flag and not two.
        var full = false
        /// The one sensor the menu bar is set to show.
        var oneSensor = false
        /// The CPU sensor specifically, whatever the menu bar is set to.
        var cpuSensor = false
        var fans = false
        var battery = false
        var load = false
        var network = false

        static let everything = Needs(full: true, oneSensor: true, cpuSensor: true,
                                      fans: true, battery: true, load: true, network: true)

        func union(_ other: Needs) -> Needs {
            Needs(full: full || other.full,
                  oneSensor: oneSensor || other.oneSensor,
                  cpuSensor: cpuSensor || other.cpuSensor,
                  fans: fans || other.fans,
                  battery: battery || other.battery,
                  load: load || other.load,
                  network: network || other.network)
        }

        /// What the menu bar alone asks for. Pure, so it can be checked.
        static func of(menuBar items: [MenuBarComposer.Item]) -> Needs {
            items.reduce(Needs()) { $0.union($1.telemetryNeeds) }
        }
    }

    /// What the enabled features need whether or not anything is displaying
    /// it — set by whoever builds the registry, since telemetry has no
    /// business knowing which features exist.
    var featureNeeds: () -> Needs = { Needs() }

    /// Cached: with the window shut this is asked every two seconds for the
    /// life of the process, and `Preferences.menuBarItems` allocates a decoder
    /// and parses JSON out of user defaults every time it is read.
    private var cachedNeeds: Needs?
    private var cachedSensorKey: String?

    /// Called when anything that decides what is worth reading has changed.
    func invalidateNeeds() {
        cachedNeeds = nil
        cachedSensorKey = nil
    }

    private var currentNeeds: Needs {
        if isWindowOpen { return .everything }
        if let cached = cachedNeeds { return cached }
        let needs = Needs.of(menuBar: Preferences.menuBarItems).union(featureNeeds())
        cachedNeeds = needs
        return needs
    }

    private var currentSensorKey: String {
        if let cached = cachedSensorKey { return cached }
        let key = Preferences.temperatureSensorKey
        cachedSensorKey = key
        return key
    }

    init() {
        let smc = try? SMC()
        sensors = smc.map { SensorReader(smc: $0) }
        fanController = smc.map { FanController(smc: $0) }
    }

    func start() {
        guard timer == nil else { return }
        // One synchronous read before anything else runs. Costs about 45 ms
        // against a launch that takes 670, and without it every feature that
        // asks "does this machine have fans" at startup gets told no — then
        // never asks again, because a tab observes its feature and not this.
        readNow()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // A fifth of the period, so the system can line this wake-up up with
        // others. At the two-second floor that is 400 ms of slack, which no one
        // watching a temperature can see, and with the window shut the period is
        // the menu bar's and the slack grows with it.
        timer.tolerance = interval / 5
        // Keep ticking while a menu is open or a slider is being dragged —
        // otherwise the readings freeze exactly when someone is looking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Served from the last poll rather than read on demand: callers are view
    /// bodies and the menu-bar title, both of which ask often.
    var cpuTemperature: TemperatureReading? {
        temperatures.first { $0.key == "TC0F" || $0.key == "TC0P" || $0.key == "TC0D" }
            ?? temperatures.max { $0.celsius < $1.celsius }
    }

    /// Blocking read, for the one moment where a wrong answer is permanent.
    private func readNow() {
        temperatures = sensors?.readTemperatures() ?? []
        fans = fanController?.readFans() ?? []
        battery = batteryReader.read()
        load = systemLoad.read()
        network = throughput.read()
        let status = thermalMonitor.read()
        thermal = status
        stats.record(status, interval: Int(interval))
    }

    private func refresh() {
        // A slow read must not queue up behind itself. Skipping a tick is
        // harmless; stacking them turns a busy machine into a growing backlog.
        guard !isReading else {
            needsAnotherRead = true
            return
        }
        isReading = true
        let needs = currentNeeds
        let sensorKey = currentSensorKey
        queue.async { [weak self] in
            guard let self = self else { return }

            // Each of these is nil when nothing needs it, and a nil result
            // leaves the last reading in place rather than blanking it.
            var temperatures: [TemperatureReading]?
            if needs.full {
                temperatures = self.sensors?.readTemperatures() ?? []
            } else if needs.oneSensor || needs.cpuSensor {
                // Both, when they are different keys — two reads out of
                // forty-eight, and the alternative is the profile engine
                // deciding on the wrong sensor.
                var wanted: [TemperatureReading] = []
                if needs.oneSensor, let one = self.sensors?.temperature(forKey: sensorKey) {
                    wanted.append(one)
                }
                // Skipped when the menu bar's sensor *is* the CPU one, which
                // is what an empty key means — otherwise the same SMC key was
                // read twice a tick and the second answer thrown away.
                let alreadyHaveCPU = needs.oneSensor && sensorKey.isEmpty
                if needs.cpuSensor, !alreadyHaveCPU,
                   let cpu = self.sensors?.cpuTemperature(),
                   !wanted.contains(where: { $0.key == cpu.key }) {
                    wanted.append(cpu)
                }
                // Empty stays nil: a sensor that momentarily declines to
                // answer must not blank the menu bar, which is what assigning
                // an empty list would do.
                temperatures = wanted.isEmpty ? nil : wanted
            }
            let fans = needs.fans ? (self.fanController?.readFans() ?? []) : nil
            let battery = needs.battery ? self.batteryReader.read() : nil
            let load = needs.load ? self.systemLoad.read(includeGPU: needs.full) : nil
            let network = needs.network ? self.throughput.read() : nil
            // Never skipped. It is one dictionary from the power-management
            // framework, and the session's throttle history is documented to
            // cover the time nobody was looking — which is exactly the time
            // this would otherwise stop recording.
            let status = self.thermalMonitor.read()

            // Handed back through the run loop rather than the main dispatch
            // queue, and in the common modes. A block on the main queue is not
            // delivered while a menu is tracking or a slider is being dragged
            // — which is exactly when someone is watching a reading — and it
            // is not delivered at all inside a nested run loop, which is how
            // the offscreen renders came to draw dashes where the numbers go.
            RunLoop.main.perform(inModes: [.common]) {
                if let temperatures = temperatures { self.temperatures = temperatures }
                if let fans = fans { self.fans = fans }
                if let battery = battery { self.battery = battery }
                if let load = load { self.load = load }
                // Only when there is one: the reader declines to answer across
                // a sleep, and replacing a real speed with nothing there would
                // blank the field for one tick every time the lid opens.
                if let network = network { self.network = network }
                self.thermal = status
                self.stats.record(status, interval: Int(self.interval))
                self.isReading = false
                if self.needsAnotherRead {
                    self.needsAnotherRead = false
                    self.refresh()
                }
            }
        }
    }
}
