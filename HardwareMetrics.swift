import Foundation
import IOKit

func gpuUsage() -> Int? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    guard let statistics = IORegistryEntryCreateCFProperty(
        service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue() as? [String: NSNumber],
          let usage = statistics["Device Utilization %"]?.doubleValue,
          (0...100).contains(usage) else { return nil }
    return Int(usage.rounded())
}

final class CPUTemperature {
    // AppleSMC 的请求格式未公开。按字节偏移读写，避免依赖 Swift 结构体布局。
    private enum Layout {
        static let size = 80
        static let key = 0
        static let dataSize = 28
        static let type = 32
        static let result = 40
        static let command = 42
        static let index = 44
        static let payload = 48
    }

    private enum Command: UInt8 {
        case read = 5
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private struct Sensor {
        let key: UInt32
        let size: UInt32
        let type: UInt32
    }

    private var connection: io_connect_t = 0
    private var sensors: [Sensor] = []

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        sensors = discoverSensors()
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func celsius() -> Int? {
        let readings = sensors.compactMap { sensor -> Double? in
            guard let payload = read(sensor) else { return nil }
            let value: Double
            switch sensor.type {
            case code("flt "):
                value = Double(Float(bitPattern: UInt32(littleEndian: payload)))
            case code("sp78"):
                let fixed = UInt16(bigEndian: UInt16(truncatingIfNeeded: payload))
                value = Double(Int16(bitPattern: fixed)) / 256
            default:
                return nil
            }
            return (10...130).contains(value) ? value : nil
        }
        guard !readings.isEmpty else { return nil }
        return Int((readings.reduce(0, +) / Double(readings.count)).rounded())
    }

    private func discoverSensors() -> [Sensor] {
        #if arch(arm64)
        guard let directory = sensorInfo(code("#KEY")), directory.size == 4,
              let payload = read(directory) else { return [] }
        let count = UInt32(bigEndian: payload)
        guard count <= 16_384 else { return [] }
        let prefixes = [code("Tp  ") >> 16, code("Te  ") >> 16]
        let keys = (0..<count).compactMap { index -> UInt32? in
            guard let response = request(.keyAtIndex, index: index) else { return nil }
            let key = word(response, at: Layout.key)
            return prefixes.contains(key >> 16) ? key : nil
        }.sorted()
        // 分散选取最多四个 CPU 传感器，减少每次刷新对 SMC 的访问。
        let sampleCount = min(keys.count, 4)
        let selected = (0..<sampleCount).map { keys[$0 * (keys.count - 1) / max(1, sampleCount - 1)] }
        #else
        let selected = ["TC0D", "TC0E", "TC0F", "TC0P"].map(code)
        #endif

        return selected.compactMap { key in
            guard let sensor = sensorInfo(key),
                  (sensor.size == 4 && sensor.type == code("flt ")) ||
                  (sensor.size == 2 && sensor.type == code("sp78")) else { return nil }
            return sensor
        }
    }

    private func sensorInfo(_ key: UInt32) -> Sensor? {
        guard let response = request(.keyInfo, key: key) else { return nil }
        return Sensor(key: key, size: word(response, at: Layout.dataSize), type: word(response, at: Layout.type))
    }

    private func read(_ sensor: Sensor) -> UInt32? {
        request(.read, key: sensor.key, size: sensor.size, type: sensor.type).map { word($0, at: Layout.payload) }
    }

    private func request(
        _ command: Command, key: UInt32 = 0, size: UInt32 = 0, type: UInt32 = 0, index: UInt32 = 0
    ) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: Layout.size)
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: key, toByteOffset: Layout.key, as: UInt32.self)
            $0.storeBytes(of: size, toByteOffset: Layout.dataSize, as: UInt32.self)
            $0.storeBytes(of: type, toByteOffset: Layout.type, as: UInt32.self)
            $0.storeBytes(of: index, toByteOffset: Layout.index, as: UInt32.self)
        }
        input[Layout.command] = command.rawValue
        var output = [UInt8](repeating: 0, count: Layout.size)
        var outputSize = Layout.size
        let result = IOConnectCallStructMethod(connection, 2, input, Layout.size, &output, &outputSize)
        guard result == kIOReturnSuccess, outputSize == Layout.size, output[Layout.result] == 0 else { return nil }
        return output
    }

    private func word(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private func code(_ name: String) -> UInt32 {
        name.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
