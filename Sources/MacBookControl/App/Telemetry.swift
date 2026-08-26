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

    /// Seconds between reads. Also the unit `ThermalStats` integrates over, so
    /// changing it here keeps the "held back for" figure honest.
    static let interval: TimeInterval = 2

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
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
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
        stats.record(status, interval: Int(Self.interval))
    }

    private func refresh() {
        // A slow read must not queue up behind itself. Skipping a tick is
        // harmless; stacking them turns a busy machine into a growing backlog.
        guard !isReading else { return }
        isReading = true
        queue.async { [weak self] in
            guard let self = self else { return }
            let temperatures = self.sensors?.readTemperatures() ?? []
            let fans = self.fanController?.readFans() ?? []
            let battery = self.batteryReader.read()
            let load = self.systemLoad.read()
            let network = self.throughput.read()
            let status = self.thermalMonitor.read()
            DispatchQueue.main.async {
                self.temperatures = temperatures
                self.fans = fans
                self.battery = battery
                self.load = load
                // Only when there is one: the reader declines to answer across
                // a sleep, and replacing a real speed with nothing there would
                // blank the field for one tick every time the lid opens.
                if let network = network { self.network = network }
                self.thermal = status
                self.stats.record(status, interval: Int(Self.interval))
                self.isReading = false
            }
        }
    }
}
