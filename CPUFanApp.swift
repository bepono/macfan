// CPU Fan — menu bar app for the cpufan service.
// Shows live readings, explains the current fan speed, and starts/stops CPU control.

import Charts
import Darwin
import ServiceManagement
import SwiftUI

// MARK: - Data

struct Reading: Decodable {
    struct Fan: Decodable {
        let rpm: Double
        let target: Double
        let min: Double
        let max: Double
        let manual: Bool
    }
    let cpu: Double?
    let avg: Double?
    let hottest: String
    let sensors: Int
    let power: Double?
    let fans: [Fan]
    let battery: [Double]
}

struct Sample: Identifiable {
    let id: Date
    let cpu: Double
    let rpm: Double
}

/// Whole-machine CPU usage from the kernel's tick counters.
final class CPULoad {
    private var previous: host_cpu_load_info?

    func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        defer { previous = info }
        guard let p = previous else { return nil }
        let user = Double(info.cpu_ticks.0 &- p.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- p.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- p.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- p.cpu_ticks.3)
        let total = user + system + idle + nice
        return total > 0 ? (user + system + nice) / total : nil
    }
}

// MARK: - Model

@MainActor
final class FanModel: ObservableObject {
    static let plistPath = "/Library/LaunchDaemons/com.local.cpufan.plist"
    static let pausePath = "/Library/Application Support/cpufan/paused"
    static let historyLength: TimeInterval = 10 * 60
    /// Rendering a screenshot: draw controls that ImageRenderer can't (menus) as plain views.
    static var snapshot = false

    @Published var reading: Reading?
    @Published var cpuLoad: Double?
    @Published var history: [Sample] = []
    @Published var installed = false
    @Published var paused = false
    @Published var curve: (low: Double, high: Double) = (55, 85)
    @Published var working = false
    @Published var message: String?
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled

    private let load = CPULoad()

    init() {
        refreshService()
        startWatcher()
    }

    var fan: Reading.Fan? { reading?.fans.first }

    enum State { case notInstalled, stopped, running, starting }

    var state: State {
        if !installed { return .notInstalled }
        if paused { return .stopped }
        return (fan?.manual ?? false) ? .running : .starting
    }

    /// Where the hottest CPU sensor sits on the fan curve, 0...1.
    var curvePosition: Double? {
        guard let t = reading?.cpu else { return nil }
        return Swift.min(Swift.max((t - curve.low) / (curve.high - curve.low), 0), 1)
    }

    /// Battery temperature sensors are all stuck at zero.
    var batteryDead: Bool {
        guard let b = reading?.battery, !b.isEmpty else { return false }
        return b.allSatisfy { $0 < 1 }
    }

    func refreshService() {
        let fm = FileManager.default
        installed = fm.fileExists(atPath: Self.plistPath)
        paused = fm.fileExists(atPath: Self.pausePath)
        if let plist = NSDictionary(contentsOfFile: Self.plistPath),
           let args = plist["ProgramArguments"] as? [String], args.count >= 4,
           let low = Double(args[2]), let high = Double(args[3]), high > low {
            curve = (low, high)
        }
    }

    private func startWatcher() {
        guard let tool = Bundle.main.url(forResource: "cpufan", withExtension: nil) else {
            message = "The bundled cpufan tool is missing."
            return
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["watch"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self?.startWatcher()
            }
        }
        do { try process.run() } catch {
            message = "Could not read sensors: \(error.localizedDescription)"
            return
        }
        let handle = pipe.fileHandleForReading
        Task { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    guard let data = line.data(using: .utf8),
                          let r = try? JSONDecoder().decode(Reading.self, from: data) else { continue }
                    self?.apply(r)
                }
            } catch {}
        }
    }

    private func apply(_ r: Reading) {
        reading = r
        cpuLoad = load.sample() ?? cpuLoad
        refreshService()
        let now = Date()
        if let cpu = r.cpu, let fan = r.fans.first {
            history.append(Sample(id: now, cpu: cpu, rpm: fan.rpm))
        }
        history.removeAll { now.timeIntervalSince($0.id) > Self.historyLength }
    }

    func start() {
        message = nil
        guard installed else { runScript("install.sh"); return }
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.pausePath) {
            do { try fm.removeItem(atPath: Self.pausePath) } catch {
                message = "Could not start: \(error.localizedDescription). Try reinstalling the service."
            }
        }
        refreshService()
    }

    func stop() {
        message = nil
        if !FileManager.default.createFile(atPath: Self.pausePath, contents: nil) {
            message = "Could not stop. Try reinstalling the service."
        }
        refreshService()
    }

    /// install.sh / uninstall.sh ask for the admin password themselves with the macOS prompt.
    func runScript(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil) else { return }
        working = true
        message = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            let ok = p.terminationStatus == 0
            Task { @MainActor in
                self?.working = false
                if !ok { self?.message = "Cancelled, or the password wasn't accepted." }
                self?.refreshService()
            }
        }
        do { try process.run() } catch {
            working = false
            message = error.localizedDescription
        }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        openAtLogin = status == .enabled
        if status == .requiresApproval {
            message = "Allow CPU Fan in System Settings › General › Login Items."
        }
    }
}

// MARK: - Formatting

private func rpm(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0))) }
private func deg(_ v: Double?) -> String { v.map { String(format: "%.0f°C", $0) } ?? "—" }

// MARK: - Views

@main
struct CPUFanApp: App {
    @StateObject private var model: FanModel

    init() {
        let model = FanModel()
        _model = StateObject(wrappedValue: model)
        // `CPUFan --snapshot light.png dark.png`: collect readings for 30 s, save pictures of the
        // panel in light and dark appearance, quit. Used for the README screenshots.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count {
            FanModel.snapshot = true
            let outputs = [(args[i + 1], NSAppearance.Name.aqua), (args[i + 2], NSAppearance.Name.darkAqua)]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                for (path, name) in outputs {
                    let appearance = NSAppearance(named: name)!
                    appearance.performAsCurrentDrawingAppearance {
                        let dark = name == .darkAqua
                        let renderer = ImageRenderer(content: PanelView().environmentObject(model)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .background(dark ? Color(white: 0.16) : Color(white: 0.96)))
                        renderer.scale = 2
                        if let tiff = renderer.nsImage?.tiffRepresentation,
                           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: path))
                        }
                    }
                }
                exit(0)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            MenuLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuLabel: View {
    @ObservedObject var model: FanModel

    var body: some View {
        let icon = model.state == .running ? "fan.fill" : model.state == .stopped ? "fan" : "fan.slash"
        let temp = model.reading?.cpu.map { "\(Int($0.rounded()))°" } ?? "--°"
        let speed = model.fan.map { " \(Int($0.rpm.rounded()))" } ?? ""
        Text("\(Image(systemName: icon)) \(temp)\(speed)")
            .monospacedDigit()
    }
}

struct PanelView: View {
    @EnvironmentObject var model: FanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            stats
            CurveView()
            charts
            details
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // Status line and the start/stop button.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusText).font(.headline)
                Spacer()
                if model.working { ProgressView().controlSize(.small) }
            }
            Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                switch model.state {
                case .running, .starting:
                    Button { model.stop() } label: { Text("Stop").frame(maxWidth: .infinity) }
                case .stopped:
                    Button { model.start() } label: { Text("Start").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                case .notInstalled:
                    Button { model.start() } label: { Text("Install & Start…").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .disabled(model.working)
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .running: return .green
        case .starting: return .orange
        case .stopped, .notInstalled: return .gray
        }
    }

    private var statusText: String {
        switch model.state {
        case .running: return "Running"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .notInstalled: return "Not installed"
        }
    }

    private var statusDetail: String {
        switch model.state {
        case .running: return "The fan follows CPU temperature only."
        case .starting: return "Waiting for the service to take over the fan. If this stays, reinstall the service."
        case .stopped: return "macOS is controlling the fan, including from the battery sensors."
        case .notInstalled: return "Installing asks for your password once. Start and Stop never do."
        }
    }

    private var stats: some View {
        HStack(alignment: .firstTextBaseline) {
            stat("CPU (hottest)", deg(model.reading?.cpu), nil)
            Spacer()
            stat("Fan", model.fan.map { "\(rpm($0.rpm)) rpm" } ?? "—",
                 model.fan.map { "target \(rpm($0.target))" })
        }
    }

    private func stat(_ title: String, _ value: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            if let sub { Text(sub).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last 10 minutes").font(.caption).foregroundStyle(.secondary)
            Chart {
                RuleMark(y: .value("Start of curve", model.curve.low))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                RuleMark(y: .value("Full speed", model.curve.high))
                    .foregroundStyle(.red.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach(model.history) { s in
                    LineMark(x: .value("Time", s.id), y: .value("CPU °C", s.cpu))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: 30...100)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(values: [40, 55, 70, 85, 100]) { AxisGridLine(); AxisValueLabel() } }
            .frame(height: 70)

            Chart(model.history) { s in
                AreaMark(x: .value("Time", s.id), y: .value("rpm", s.rpm))
                    .foregroundStyle(.blue.opacity(0.25))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.id), y: .value("rpm", s.rpm))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...(model.fan?.max ?? 7200))
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisValueLabel() } }
            .frame(height: 55)
        }
    }

    // Small readings that explain the fan's behaviour.
    private var details: some View {
        let r = model.reading
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            row("Hottest sensor", r.map { "\($0.hottest) · \(deg($0.cpu))" } ?? "—")
            row("Average of \(r?.sensors ?? 0) CPU sensors", deg(r?.avg))
            row("CPU load", model.cpuLoad.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
            row("System power", r?.power.map { String(format: "%.1f W", $0) } ?? "—")
            row("Battery sensors",
                r.map { $0.battery.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " °C" } ?? "—",
                warn: model.batteryDead)
            if model.batteryDead {
                GridRow {
                    Text("The battery isn't reporting. macOS treats that as a fault and runs the fan at full speed, which is why cpufan ignores these sensors.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridCellColumns(2)
                }
            }
        }
        .font(.caption)
    }

    private func row(_ name: String, _ value: String, warn: Bool = false) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(warn ? .orange : .primary)
                .gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                .toggleStyle(.checkbox)
            Spacer()
            if FanModel.snapshot {
                HStack(spacing: 3) { Text("More"); Image(systemName: "chevron.down").font(.caption2) }
            } else {
            Menu("More") {
                if model.installed {
                    Button("Reinstall Service…") { model.runScript("install.sh") }
                    Button("Uninstall Service…") { model.runScript("uninstall.sh") }
                } else {
                    Button("Install Service…") { model.runScript("install.sh") }
                }
                Divider()
                Button("Quit CPU Fan") { NSApp.terminate(nil) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            }
        }
        .font(.callout)
        .disabled(model.working)
    }
}

/// The fan curve as a bar: where the CPU temperature sits between "minimum" and "full speed",
/// and a sentence saying why the fan is at the speed it is.
struct CurveView: View {
    @EnvironmentObject var model: FanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Fan curve").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(model.curve.low))°C → \(Int(model.curve.high))°C")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                let pos = model.curvePosition ?? 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    LinearGradient(colors: [.green, .yellow, .orange, .red],
                                   startPoint: .leading, endPoint: .trailing)
                        .mask(alignment: .leading) {
                            Capsule().frame(width: Swift.max(12, geo.size.width * pos))
                        }
                    Circle().fill(.white).shadow(radius: 1)
                        .frame(width: 12, height: 12)
                        .offset(x: Swift.min(Swift.max(geo.size.width * pos - 6, 0), geo.size.width - 12))
                }
            }
            .frame(height: 12)
            .animation(.easeOut(duration: 0.4), value: model.curvePosition)
            Text(explanation).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: String {
        guard let t = model.reading?.cpu, let fan = model.fan, let pos = model.curvePosition else {
            return "Waiting for readings…"
        }
        let low = Int(model.curve.low), high = Int(model.curve.high)
        switch model.state {
        case .stopped, .notInstalled:
            let would = fan.min + pos * (fan.max - fan.min)
            return "macOS chose \(rpm(fan.target)) rpm. On the CPU curve it would be about \(rpm(would)) rpm."
        default:
            break
        }
        if pos <= 0 {
            return "\(Int(t.rounded()))°C is under \(low)°C, so the fan stays at its minimum (\(rpm(fan.min)) rpm)."
        }
        if pos >= 1 {
            return "\(Int(t.rounded()))°C is at or over \(high)°C, so the fan runs at full speed."
        }
        return "\(Int(t.rounded()))°C is \(Int((pos * 100).rounded()))% of the way from \(low)° to \(high)°, so the target is about \(rpm(fan.min + pos * (fan.max - fan.min))) rpm. Speed eases down slowly as the CPU cools."
    }
}
