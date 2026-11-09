import AppKit
import Darwin

struct NetworkCounters {
    let received: UInt32
    let sent: UInt32
}

struct Sample {
    private static let host = mach_host_self()

    let time = ProcessInfo.processInfo.systemUptime
    let cpu: [UInt32]?
    let network: [String: NetworkCounters]?

    init(readCPU: Bool, readNetwork: Bool) {
        cpu = readCPU ? Self.cpuTicks() : nil
        network = readNetwork ? Self.networkCounters() : nil
    }

    private static func cpuTicks() -> [UInt32]? {
        var ticks = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: ticks) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &ticks) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(Self.host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        let (user, system, idle, nice) = ticks.cpu_ticks
        return result == KERN_SUCCESS ? [user, system, idle, nice] : nil
    }

    private static func networkCounters() -> [String: NetworkCounters]? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }

        var counters: [String: NetworkCounters] = [:]
        var next = addresses
        while let address = next {
            let interface = address.pointee
            next = interface.ifa_next
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
            let name = String(cString: interface.ifa_name)
            // 统计 Wi-Fi 和以太网接口，避免 VPN 虚拟接口重复计量。
            guard name.hasPrefix("en") else { continue }
            counters[name] = NetworkCounters(received: data.ifi_ibytes, sent: data.ifi_obytes)
        }
        return counters
    }

    func cpuUsage(since previous: Sample) -> Int? {
        guard let cpu, let old = previous.cpu else { return nil }
        let delta = zip(cpu, old).map { UInt64($0.0 &- $0.1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return Int((100 * (total - delta[2]) + total / 2) / total)
    }

    func rates(since previous: Sample) -> (down: Double, up: Double)? {
        guard let network, let old = previous.network else { return nil }
        let elapsed = time - previous.time
        guard elapsed > 0 else { return nil }

        var down: UInt64 = 0
        var up: UInt64 = 0
        for (name, current) in network {
            guard let prior = old[name] else { continue }
            down += UInt64(current.received &- prior.received)
            up += UInt64(current.sent &- prior.sent)
        }
        return (Double(down) / elapsed, Double(up) / elapsed)
    }
}

func rateLabel(_ bytesPerSecond: Double?, compact: Bool) -> String {
    guard let bytesPerSecond else { return "—" }
    let units = compact ? ["B", "K", "M", "G"] : ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = bytesPerSecond
    var unit = 0
    while value >= 999.5 && unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    return String(format: value < 10 && unit > 0 ? "%.1f%@" : "%.0f%@", value, units[unit])
}

enum Metric: Int, CaseIterable {
    case cpu = 0, temperature = 1, gpu = 2, network = 3

    var title: String {
        switch self {
        case .cpu: return "CPU 占用率"
        case .temperature: return "CPU 温度"
        case .gpu: return "GPU 占用率"
        case .network: return "实时网速"
        }
    }
}

final class MenuBarMonitor: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: 78)
    private let defaultsKey = "visibleMetrics"
    private lazy var visible: Set<Metric> = {
        guard let saved = UserDefaults.standard.array(forKey: defaultsKey) as? [Int] else {
            return [.cpu, .network]
        }
        return Set(saved.compactMap(Metric.init(rawValue:)))
    }()
    private let thermalQueue = DispatchQueue(label: "local.menu-bar-monitor.temperature", qos: .utility)
    // 温度读取器只在 thermalQueue 上访问。
    private lazy var temperatureSource = CPUTemperature()
    private var temperaturePending = false
    private var nextTemperatureRead: TimeInterval = 0
    private var cpu: Int?
    private var temperature: Int?
    private var gpu: Int?
    private var rates: (down: Double, up: Double)?
    private var previous: Sample?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        for metric in Metric.allCases {
            let option = menu.addItem(withTitle: metric.title, action: #selector(toggle(_:)), keyEquivalent: "")
            option.tag = metric.rawValue
            option.target = self
            option.state = visible.contains(metric) ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.15
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let metric = Metric(rawValue: sender.tag) else { return }
        if visible.remove(metric) != nil {
            sender.state = .off
        } else {
            visible.insert(metric)
            sender.state = .on
        }
        UserDefaults.standard.set(visible.map(\.rawValue).sorted(), forKey: defaultsKey)
        if metric == .temperature { nextTemperatureRead = 0 }
        refresh()
    }

    private func refresh() {
        let current = Sample(readCPU: visible.contains(.cpu), readNetwork: visible.contains(.network))
        if let previous {
            cpu = current.cpuUsage(since: previous)
            rates = current.rates(since: previous)
        }
        previous = current
        gpu = visible.contains(.gpu) ? gpuUsage() : nil
        if visible.contains(.temperature), !temperaturePending, current.time >= nextTemperatureRead {
            temperaturePending = true
            nextTemperatureRead = current.time + 3
            thermalQueue.async { [weak self] in
                guard let self else { return }
                let reading = self.temperatureSource?.celsius()
                DispatchQueue.main.async {
                    self.temperature = reading
                    self.temperaturePending = false
                    self.update()
                }
            }
        }
        update()
    }

    private func update() {
        guard let button = item.button else { return }
        let metrics = Metric.allCases.filter(visible.contains)
        if metrics.isEmpty {
            guard button.toolTip != "UpTop" else { return }
            button.toolTip = "UpTop"
            button.setAccessibilityLabel("UpTop")
            item.length = NSStatusItem.squareLength
            button.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "UpTop")
            return
        }

        let cpuText = cpu.map { "\($0)%" } ?? "—"
        let temperatureText = temperature.map { "\($0)°C" } ?? "—"
        let gpuText = gpu.map { "\($0)%" } ?? "—"
        let columns = metrics.map { metric -> (top: String, bottom: String, width: CGFloat, detail: String) in
            switch metric {
            case .cpu: return ("CPU", cpuText, 36, "CPU 占用率 \(cpuText)")
            case .temperature: return ("TEMP", temperatureText, 43, "CPU 温度 \(temperatureText)")
            case .gpu: return ("GPU", gpuText, 36, "GPU 占用率 \(gpuText)")
            case .network:
                let down = rateLabel(rates?.down, compact: true)
                let up = rateLabel(rates?.up, compact: true)
                let detail = "下载 \(rateLabel(rates?.down, compact: false))　上传 \(rateLabel(rates?.up, compact: false))"
                return ("↓" + down, "↑" + up, 36, detail)
            }
        }
        let description = columns.map(\.detail).joined(separator: "　")
        guard button.toolTip != description else { return }
        button.toolTip = description
        button.setAccessibilityLabel(description)

        let width = columns.map(\.width).reduce(0, +)
        item.length = width + 6
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            let labelStyle: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.black
            ]
            let valueStyle: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.black
            ]
            var x: CGFloat = 0
            for (metric, column) in zip(metrics, columns) {
                (column.top as NSString).draw(at: NSPoint(x: x, y: 10), withAttributes: labelStyle)
                (column.bottom as NSString).draw(at: NSPoint(x: x, y: 0),
                                                  withAttributes: metric == .network ? labelStyle : valueStyle)
                x += column.width
            }
            return true
        }
        image.isTemplate = true
        button.image = image
    }
}

let app = NSApplication.shared
let monitor = MenuBarMonitor()
app.setActivationPolicy(.accessory)
app.delegate = monitor
app.run()
