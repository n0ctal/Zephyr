import SwiftUI

/// What the machine is and what it has been through: the drive's own health
/// record, whatever is holding sleep off right now, and how it last woke and
/// last went off.
///
/// One section rather than three because none of it is a setting — there is
/// nothing here to switch, only things to read — and because the three answer
/// the same kind of question. It replaces the part of DriveDx and Sleep Aid
/// that people actually open those applications for, at the cost of no new
/// privileges: every reading here is available to any process.
///
/// Nothing is read until this section is on screen, and everything stops the
/// moment it is not. See `Polled`.
struct DiagnosticsSection: View {
    /// The whole sensor set and the fans, which is the screen TG Pro is opened
    /// for. Passed in rather than polled: telemetry is already reading every
    /// sensor while the window is open, and a second reader would be a second
    /// sweep of fifty SMC keys for the same numbers.
    @ObservedObject var telemetry: Telemetry
    @StateObject private var drive = Polled(every: 300) { DriveHealth.read() }
    @StateObject private var sleep = Polled(every: 5) { SleepDiagnostics.assertions() }
    @StateObject private var record = Polled(every: 30) { SleepDiagnostics.powerRecord() }
    /// Five minutes: a login item is installed by an installer, not by the
    /// minute, and the read touches every plist in three directories.
    @StateObject private var startup = Polled(every: 300) { StartupItems.all() }
    /// Three seconds: a share of a core is a rate, and this is the reading
    /// people watch while wondering why the fans came on.
    @StateObject private var busiest = Polled(every: 3) { ProcessLoad.shared.read() }
    @Environment(\.terminalStyling) private var terminal
    @Environment(\.terminalPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sensorBlock
            Divider()
            driveBlock
            Divider()
            sleepBlock
            Divider()
            powerBlock
            Divider()
            busiestBlock
            Divider()
            startupBlock
        }
        .polling(drive)
        .polling(sleep)
        .polling(record)
        .polling(startup)
        .polling(busiest)
    }

    // MARK: Sensors

    @ViewBuilder private var sensorBlock: some View {
        heading("SENSORS")
        let readings = telemetry.temperatures.sorted { $0.celsius > $1.celsius }
        if readings.isEmpty {
            note("Reading…")
        } else {
            // Hottest first. A list of forty-eight in the order the SMC
            // happens to enumerate them answers nothing; the top of this list
            // is the answer to "what is hot".
            ForEach(readings) { reading in
                row(reading.label, String(format: "%.0f °C", reading.celsius) + "   " + reading.key)
            }
            explainer("Every temperature the SMC will answer for, hottest first. The names are the machine's own — several of these sit on parts nobody has a word for, and a key like TC0P is more honest than inventing one.")
        }

        if !telemetry.fans.isEmpty {
            ForEach(telemetry.fans) { fan in
                row("Fan \(fan.index + 1)",
                    "\(fan.actualRPM) rpm  ·  \(Int((fan.loadFraction * 100).rounded())) % of "
                    + "\(fan.minRPM)–\(fan.maxRPM)"
                    + (fan.isManual ? "  ·  held" : ""))
            }
        }
    }

    // MARK: Drive

    @ViewBuilder private var driveBlock: some View {
        heading("DRIVE")
        if let drive = drive.value {
            note(drive.isHealthy ? "The drive reports itself healthy."
                                 : "The drive is reporting a problem.",
                 warning: !drive.isHealthy)
            ForEach(drive.warnings, id: \.self) { warning in
                Text("· " + warning).font(.caption).foregroundColor(.orange)
            }

            row("Drive", drive.model + capacity(drive.capacityBytes))
            row("Wear", "\(drive.percentageUsed) % of its rated endurance used")
            row("Spare blocks", "\(drive.availableSpare) % left, fails below \(drive.spareThreshold) %")
            row("Written", terabytes(drive.bytesWritten))
            row("Read", terabytes(drive.bytesRead))
            row("Powered on", "\(drive.powerOnHours) hours over \(drive.powerCycles) starts")
            row("Unsafe shutdowns", "\(drive.unsafeShutdowns)")
            row("Media errors", "\(drive.mediaErrors)")
            if let celsius = drive.celsius {
                row("Temperature", String(format: "%.0f °C", celsius))
            }

            explainer("Wear is the drive's own estimate of how much of its rated write endurance is gone. It is not a countdown to failure: drives routinely pass 100 % and keep working, while a single media error on a young one is the reading to worry about.")
        } else {
            note(drive.hasRead ? "This drive does not publish a health page." : "Reading…")
        }
    }

    // MARK: Sleep

    @ViewBuilder private var sleepBlock: some View {
        heading("HOLDING SLEEP OFF")
        let assertions = sleep.value ?? []
        if assertions.isEmpty {
            note(sleep.hasRead ? "Nothing is holding the Mac awake." : "Reading…")
        } else {
            ForEach(assertions) { assertion in
                row(assertion.process, held(assertion) + assertion.effect)
            }
            explainer("These are the assertions macOS is honouring right now. An application that leaves one behind is the usual reason a Mac sits awake all night with the lid shut.")
        }
    }

    private func held(_ assertion: SleepDiagnostics.Assertion) -> String {
        guard let since = assertion.since else { return "" }
        let minutes = Int(Date().timeIntervalSince(since) / 60)
        if minutes < 1 { return "just now · " }
        if minutes < 60 { return "\(minutes) min · " }
        return "\(minutes / 60) h \(minutes % 60) min · "
    }

    // MARK: The power record

    @ViewBuilder private var powerBlock: some View {
        heading("LAST TIME ROUND")
        if let record = record.value {
            if let reason = record.wakeReason {
                row("Woke because of", reason + (record.wakeType.map { " · \($0)" } ?? ""))
            }
            if let reason = record.sleepReason {
                row("Went to sleep because of", reason)
            }
            if let shutdown = record.shutdownDescription {
                row("Last shutdown", shutdown)
            }
            explainer("The wake reason is the hardware's own word for what raised the machine — \"EC.USBC\" is something on a USB-C port, \"OHC1\" a USB controller, \"LID0\" the lid. Only one shutdown code has a published meaning, so the rest are shown as the number the firmware reports.")
        } else {
            note("Reading…")
        }
    }

    // MARK: What is costing something

    @ViewBuilder private var busiestBlock: some View {
        heading("BUSIEST")
        if let snapshot = busiest.value {
            ForEach(snapshot.byCPU) { entry in
                row(entry.name, String(format: "%.0f %% of a core", entry.cpu))
            }
            ForEach(snapshot.byMemory) { entry in
                row(entry.name, memory(entry.memoryBytes))
            }
            explainer("Share of one core, the way Activity Monitor counts it — a process using two cores fully reads 200 %. Memory is the footprint the kernel charges to the process. Another user's processes do not answer and are not listed rather than guessed at.")
        } else {
            note(busiest.hasRead ? "Nothing is asking for anything." : "Reading…")
        }
    }

    private func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return megabytes < 1024
            ? String(format: "%.0f MB", megabytes)
            : String(format: "%.1f GB", megabytes / 1024)
    }

    // MARK: Startup

    @ViewBuilder private var startupBlock: some View {
        heading("STARTS WITH THE MACHINE")
        let items = startup.value ?? []
        let others = items.filter { !$0.isApple }
        if !startup.hasRead {
            note("Reading…")
        } else if others.isEmpty {
            note("Nothing outside the system starts by itself.")
        } else {
            ForEach(others) { item in
                row(item.label, (item.program.map { shorten($0) } ?? "—")
                    + " · " + item.scope.rawValue.lowercased())
            }
        }
        let apple = items.count - others.count
        if apple > 0 {
            explainer("\(apple) of Apple's own are not listed: they are the bulk of any list like this and none of them are what anyone is looking for. Nothing here is a verdict — most of what starts by itself was installed on purpose and then forgotten.")
        }
    }

    /// The last two path components, which is where the name is.
    private func shorten(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count <= 2 ? path : ".../" + parts.suffix(2).joined(separator: "/")
    }

    // MARK: Pieces

    private func heading(_ text: String) -> some View {
        SectionHeading(text: text).padding(.top, 2)
    }

    /// A single line about the state of things.
    private func note(_ text: String, warning: Bool = false) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(warning ? .orange : .secondary)
    }

    /// A paragraph explaining what a reading means, which is most of what
    /// makes these numbers worth showing at all.
    private func explainer(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The same label column every other row in the window uses, so a reading
    /// lines up with a setting.
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label + ":")
                .foregroundColor(terminal ? palette.text : .primary)
                .frame(width: TerminalMetrics.labelColumn, alignment: .trailing)
            Text(value)
                .foregroundColor(terminal ? palette.accent : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(terminal ? .system(size: 13, design: .monospaced) : .subheadline)
    }

    private func capacity(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "" }
        return String(format: " · %.0f GB", Double(bytes) / 1_000_000_000)
    }

    /// Decimal, like the number on the box. The drive counts its endurance in
    /// units of 512 000 bytes, so decimal is also the unit it is thinking in —
    /// and quoting 461 TiB beside a "1 TB" drive invites the wrong comparison.
    private func terabytes(_ bytes: UInt64) -> String {
        let terabytes = Double(bytes) / 1_000_000_000_000
        return terabytes < 1
            ? String(format: "%.0f GB", Double(bytes) / 1_000_000_000)
            : String(format: "%.1f TB", terabytes)
    }
}
