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
    private let batteryReader: BatteryReader
    private let batteryWatcher = BatteryWatcher()
    /// When the battery was last read, for the floor under the notification.
    private var batteryReadAt = Date.distantPast
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

    /// The slack every repeating timer here is given, as a fraction of its
    /// period. Named because two things have to agree about it: the timers,
    /// and the arithmetic deciding how far apart two readings may legitimately
    /// fall.
    static let timerToleranceFraction: Double = 0.2

    /// How long the charge may go unread when nothing has announced a change.
    ///
    /// The floor under `BatteryWatcher`, and the whole of what a missed
    /// notification costs: fifteen seconds of a stale percentage, rather than
    /// a wrong one until the app is restarted. Short enough that plugging the
    /// charger in looks immediate even if IOKit says nothing, long enough that
    /// fourteen readings out of fifteen are saved.
    static let batteryFallbackSeconds: TimeInterval = 15

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
    /// sensor sweep: fifty keys on this machine, read one at a time, of which
    /// forty-eight answer. With the window closed and a temperature in the
    /// menu bar, exactly one of them is wanted.
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
        /// Everything the battery can say beyond its charge: health, cycles,
        /// capacities, temperature, the flow and the time left.
        ///
        /// Apart from `battery` because it is most of the price. The charge is
        /// four properties out of the registry; the rest is ten more and two
        /// SMC round trips at about 350 us each, and nothing outside the
        /// window shows any of it. A menu bar with a battery icon in it was
        /// paying for all of it once a second.
        var batteryInDetail = false
        var load = false
        var network = false

        static let everything = Needs(full: true, oneSensor: true, cpuSensor: true,
                                      fans: true, battery: true, batteryInDetail: true,
                                      load: true, network: true)

        func union(_ other: Needs) -> Needs {
            Needs(full: full || other.full,
                  oneSensor: oneSensor || other.oneSensor,
                  cpuSensor: cpuSensor || other.cpuSensor,
                  fans: fans || other.fans,
                  battery: battery || other.battery,
                  batteryInDetail: batteryInDetail || other.batteryInDetail,
                  load: load || other.load,
                  network: network || other.network)
        }

        /// What the menu bar alone asks for. Pure, so it can be checked.
        static func of(menuBar items: [MenuBarComposer.Item]) -> Needs {
            items.reduce(Needs()) { $0.union($1.telemetryNeeds) }
        }
    }

    /// Called on the main thread after a reading has been published, and only
    /// then.
    ///
    /// The menu bar used to keep a repeating timer of its own, at the same
    /// rate as this one: two wake-ups a second to show one line, and the
    /// second of them could only ever redraw what the first had just read.
    /// There is nothing to redraw that a reading did not change, so the
    /// reading says when.
    var didPublish: () -> Void = {}

    /// Whether this tick should read the battery.
    ///
    /// Pure, so the rule can be checked without a battery. The detailed
    /// reading is never paced: it carries the watts and the amperage, which
    /// move continuously, and the only thing asking for it is a window or a
    /// menu-bar field showing them. It is the charge — four properties, and a
    /// number that steps once in several minutes — that is worth waiting for a
    /// reason to read.
    static func shouldReadBattery(needs: Needs, watching: Bool, changed: Bool,
                                  since lastRead: TimeInterval) -> Bool {
        guard needs.battery else { return false }
        guard needs.batteryInDetail == false, watching else { return true }
        return changed || lastRead >= batteryFallbackSeconds
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
        // The same connection, for the reason in this type's own note: the SMC
        // is one serialised device and the battery was quietly opening a
        // second line to it twice a second.
        batteryReader = BatteryReader(smc: smc)
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
        timer.tolerance = interval * Telemetry.timerToleranceFraction
        // Keep ticking while a menu is open or a slider is being dragged —
        // otherwise the readings freeze exactly when someone is looking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The temperature of the card that is doing the work.
    ///
    /// Which key carries it depends on the model — this machine publishes
    /// `TG0P`, others put the discrete card on `TG1P` or name the die instead —
    /// so take the first that answers rather than the one that happens to be
    /// right here. The CPU reading has worked this way for a while; the GPU
    /// asked for a single key and showed a dash on any machine that spells it
    /// differently.
    func gpuTemperature(discrete: Bool) -> TemperatureReading? {
        Telemetry.gpuTemperature(in: temperatures, discrete: discrete)
    }

    /// The choice itself, apart from the readings it is made against, so the
    /// order can be checked without a machine that has the sensors.
    /// The integrated list has one entry on purpose. TCXC used to follow it,
    /// but that is the CPU's own PECI sensor — it sits in `cpuKeyPreference`
    /// too — so on a machine with TCXC and no TCGC the graphics row printed
    /// the processor's temperature under a heading that said GPU. A dash is
    /// the better answer.
    static func gpuTemperature(in readings: [TemperatureReading],
                               discrete: Bool) -> TemperatureReading? {
        let preference = discrete
            ? ["TG0P", "TG1P", "TGDD", "TGVP"]
            : ["TCGC"]   // and nothing else: see below
        for key in preference {
            if let reading = readings.first(where: { $0.key == key }) { return reading }
        }
        return nil
    }

    /// Served from the last poll rather than read on demand: callers are view
    /// bodies and the menu-bar title, both of which ask often.
    var cpuTemperature: TemperatureReading? {
        Telemetry.cpuTemperature(in: temperatures)
    }

    /// The choice apart from the readings, so the order can be checked, and
    /// so it can be checked against the order the reader fetches by. They are
    /// the same list now; when they were two lists that disagreed, the menu
    /// bar read eighteen degrees low with the window shut and corrected itself
    /// when it was opened.
    static func cpuTemperature(in readings: [TemperatureReading]) -> TemperatureReading? {
        for key in SensorReader.cpuKeyPreference {
            if let reading = readings.first(where: { $0.key == key }) { return reading }
        }
        // Nothing preferred came back — a sensor can decline — so the hottest
        // thing that did is a better answer than none.
        return readings.max { $0.celsius < $1.celsius }
    }

    /// Blocking read, for the one moment where a wrong answer is permanent.
    ///
    /// The reads themselves go on the queue like every other read, even though
    /// the caller waits for them. This is reached from `retune()`, which a
    /// window opening calls on the main thread while a tick may already be
    /// reading — and the readers are not stateless. `SystemLoad` and
    /// `NetworkThroughput` both hold the previous sample to subtract from, the
    /// SMC is one connection with one table of key shapes behind it, and two
    /// threads writing those is not a wrong number but a corrupted one.
    /// Demonstrated with `--test-telemetry-race` under the thread sanitizer,
    /// which reported it five times over four seconds before this.
    ///
    /// The wait is one tick's worth of reads, on a path that already accepts
    /// about 45 ms of one.
    private func readNow() {
        let generation = nextGeneration()
        let reading = queue.sync {
            Reading(generation: generation,
                    temperatures: self.sensors?.readTemperatures() ?? [],
                    fans: self.fanController?.readFans() ?? [],
                    battery: self.batteryReader.read(),
                    // Without the accelerator's share, which is the most
                    // expensive thing in the load reader and which nothing is
                    // displaying at launch — the only moment this path is
                    // reliably taken.
                    //
                    // Asking for it here by the window's state was tried and
                    // does not work: opening the window calls retune(), which
                    // returns without restarting anything when the interval
                    // has not changed, and at the shipped defaults both poll
                    // rates are two seconds, so it has not. The read that does
                    // happen is the refresh() the same didSet issues, and if
                    // that lands within a fifth of a second of the previous
                    // tick the load reader refuses it as too close to be a
                    // rate. So the graphics row can read "—" for one polling
                    // interval after the window opens. It is a dash while
                    // nothing has been measured, which is the honest answer;
                    // the alternatives were to show the previous reading as
                    // though it were current, or to pay a registry walk on a
                    // blocking main-thread read that occlusion changes
                    // re-trigger.
                    load: self.systemLoad.read(),
                    network: self.throughput.read(),
                    thermal: self.thermalMonitor.read())
        }
        // This read the battery too, so the floor starts from here rather than
        // letting the next tick read it again a moment later.
        batteryReadAt = Date()
        apply(reading)
    }

    /// What one read came back with.
    ///
    /// Nil means either "nobody asked for it" or "the reader declined to
    /// answer", and the fields do not need to tell those apart: both mean
    /// leave what is there alone.
    private struct Reading {
        /// Which read this is. Readings are published in the order they were
        /// started, not the order they finish.
        var generation: Int
        var temperatures: [TemperatureReading]?
        var fans: [FanReading]?
        var battery: BatteryStatus?
        var load: SystemLoad.Snapshot?
        var network: NetworkThroughput.Snapshot?
        var thermal: ThermalStatus
    }

    /// Publishes a reading, on the main thread.
    ///
    /// The one place that decides what an absent value means. The two paths
    /// that read the hardware each used to carry their own copy of that rule,
    /// and they drifted: the tick left a field alone when its reader said
    /// nothing, and the blocking read — the one that runs every time the
    /// window opens — overwrote it with nothing.
    /// Counts reads, and remembers the newest one published.
    ///
    /// The blocking read waits for a tick that is already reading, then reads
    /// everything itself and publishes at once — while the tick it waited for
    /// is still queued to publish its own, narrower result on the run loop.
    /// That one landed second and replaced a full sweep with a single sensor,
    /// for one cycle, at the exact moment the window opened and somebody
    /// looked at the pickers.
    private var reads = 0
    private var newestPublished = 0

    /// Both counters are touched only on the main thread: refresh() and
    /// readNow() are both called there, and apply() runs there.
    private func nextGeneration() -> Int {
        reads += 1
        return reads
    }

    private func apply(_ reading: Reading) {
        // A reading that was started before one already published describes an
        // older moment, whatever order they finished in.
        guard reading.generation > newestPublished else { return }
        newestPublished = reading.generation
        if let temperatures = reading.temperatures { self.temperatures = temperatures }
        if let fans = reading.fans { self.fans = fans }
        if let battery = reading.battery { self.battery = battery }
        if let load = reading.load { self.load = load }
        if let network = reading.network { self.network = network }
        thermal = reading.thermal
        stats.record(reading.thermal, interval: interval,
                     longestGap: interval * (1 + Telemetry.timerToleranceFraction))
        didPublish()
    }

    private func refresh() {
        // A slow read must not queue up behind itself. Skipping a tick is
        // harmless; stacking them turns a busy machine into a growing backlog.
        guard !isReading else {
            needsAnotherRead = true
            return
        }
        isReading = true
        let generation = nextGeneration()
        let needs = currentNeeds
        let sensorKey = currentSensorKey
        // Decided here, on the main thread, because that is where the
        // notification lands and where the clock for the floor is kept.
        let readBattery = Telemetry.shouldReadBattery(
            needs: needs, watching: batteryWatcher.isWatching,
            changed: batteryWatcher.takeChange(),
            since: Date().timeIntervalSince(batteryReadAt))
        if readBattery { batteryReadAt = Date() }
        queue.async { [weak self] in
            guard let self = self else { return }

            // Each of these stays nil when nothing needs it; see apply() for
            // what the fields make of that.
            var temperatures: [TemperatureReading]?
            if needs.full {
                temperatures = self.sensors?.readTemperatures() ?? []
            } else if needs.oneSensor || needs.cpuSensor {
                // Both, when they are different keys — two reads out of
                // fifty, and the alternative is the profile engine deciding on
                // the wrong sensor.
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
            // Nil here means "not read", which apply() takes as "leave what is
            // there alone" — exactly right for a charge that has not moved.
            let battery = readBattery
                ? self.batteryReader.read(inDetail: needs.batteryInDetail) : nil
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
                self.apply(Reading(generation: generation,
                                   temperatures: temperatures, fans: fans, battery: battery,
                                   load: load, network: network, thermal: status))
                self.isReading = false
                if self.needsAnotherRead {
                    self.needsAnotherRead = false
                    self.refresh()
                }
            }
        }
    }
}
