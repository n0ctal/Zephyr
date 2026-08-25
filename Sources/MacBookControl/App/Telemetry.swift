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

    /// Accumulated across the session, so "is it throttling" can be answered
    /// for the time nobody was looking.
    private(set) var stats = ThermalStats()

    private let sensors: SensorReader?
    private let fanController: FanController?
    private let thermalMonitor = ThermalMonitor()
    private let batteryReader = BatteryReader()
    private var timer: Timer?

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
        refresh()
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

    var cpuTemperature: TemperatureReading? { sensors?.cpuTemperature() }

    private func refresh() {
        temperatures = sensors?.readTemperatures() ?? []
        fans = fanController?.readFans() ?? []
        battery = batteryReader.read()
        let status = thermalMonitor.read()
        thermal = status
        stats.record(status, interval: Int(Self.interval))
        objectWillChange.send()
    }
}
