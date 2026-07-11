import SwiftUI
import IOKit
import Darwin
import ServiceManagement

// MARK: - HID Thermal Sensor Reader

private let iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)!

private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
private typealias SetMatchFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void
private typealias CopySvcFn = @convention(c) (UnsafeMutableRawPointer) -> CFArray?
private typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UnsafeRawPointer?, UInt32) -> UnsafeMutableRawPointer?
private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Double
private typealias CopyPropFn = @convention(c) (UnsafeMutableRawPointer, CFString) -> CFTypeRef?

private let hidCreate = unsafeBitCast(dlsym(iokitHandle, "IOHIDEventSystemClientCreate")!, to: CreateFn.self)
private let hidSetMatch = unsafeBitCast(dlsym(iokitHandle, "IOHIDEventSystemClientSetMatching")!, to: SetMatchFn.self)
private let hidCopySvcs = unsafeBitCast(dlsym(iokitHandle, "IOHIDEventSystemClientCopyServices")!, to: CopySvcFn.self)
private let hidCopyEvent = unsafeBitCast(dlsym(iokitHandle, "IOHIDServiceClientCopyEvent")!, to: CopyEventFn.self)
private let hidGetFloat = unsafeBitCast(dlsym(iokitHandle, "IOHIDEventGetFloatValue")!, to: GetFloatFn.self)
private let hidCopyProp = unsafeBitCast(dlsym(iokitHandle, "IOHIDServiceClientCopyProperty")!, to: CopyPropFn.self)

// MARK: - sysctl helpers

private func sysctlString(_ name: String) -> String? {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

private func sysctlInt(_ name: String) -> Int? {
    var val = 0
    var size = MemoryLayout<Int>.size
    guard sysctlbyname(name, &val, &size, nil, 0) == 0 else { return nil }
    return val
}

// MARK: - RAM Usage Reader

private let sharedHost = mach_host_self()

private func readRAMUsage() -> (usedGB: Double, totalGB: Double, percentage: Double)? {
    var vmStats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &vmStats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(sharedHost, HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let pageSize = Double(vm_page_size)
    let free = Double(vmStats.free_count) * pageSize
    let active = Double(vmStats.active_count) * pageSize
    let inactive = Double(vmStats.inactive_count) * pageSize
    let speculative = Double(vmStats.speculative_count) * pageSize
    let wired = Double(vmStats.wire_count) * pageSize
    let compressed = Double(vmStats.compressor_page_count) * pageSize
    let purgeable = Double(vmStats.purgeable_count) * pageSize
    let total = free + active + inactive + speculative + wired + compressed
    let used = active + wired + compressed + purgeable
    guard total > 0 else { return nil }
    return (used / 1_073_741_824, total / 1_073_741_824, used / total * 100)
}

// MARK: - Data

struct SensorReading: Identifiable {
    let id: String
    let temp: Double
}

struct ClusterInfo {
    var sensors: [SensorReading] = []
    var avg: Double { sensors.isEmpty ? 0 : sensors.map(\.temp).reduce(0, +) / Double(sensors.count) }
    var min: Double { sensors.map(\.temp).min() ?? 0 }
    var max: Double { sensors.map(\.temp).max() ?? 0 }
}

// MARK: - Temperature Monitor

final class TempMonitor: ObservableObject {
    @Published var avg: Double?
    @Published var highest: Double?
    @Published var pCluster = ClusterInfo()
    @Published var eCluster = ClusterInfo()

    let chipName: String
    let pCoreCount: Int
    let eCoreCount: Int

    private var client: UnsafeMutableRawPointer?
    private var timer: Timer?

    init() {
        chipName = sysctlString("machdep.cpu.brand_string")?.trimmingCharacters(in: .whitespaces) ?? "Apple Silicon"
        pCoreCount = sysctlInt("hw.perflevel0.physicalcpu") ?? 0
        eCoreCount = sysctlInt("hw.perflevel1.physicalcpu") ?? 0

        client = hidCreate(kCFAllocatorDefault)
        guard client != nil else { return }

        let matching = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as NSDictionary
        hidSetMatch(client!, matching as CFDictionary)

        refresh()
        timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    deinit { timer?.invalidate() }

    func refresh() {
        guard let client, let services = hidCopySvcs(client) else { return }

        var pSensors: [SensorReading] = []
        var eSensors: [SensorReading] = []

        for i in 0..<CFArrayGetCount(services) {
            let svc = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(services, i)!)
            var name = ""
            if let val = hidCopyProp(svc, "Product" as CFString) { name = "\(val)" }
            guard name.contains("tdie") else { continue }

            guard let event = hidCopyEvent(svc, 15, nil, 0) else { continue }
            let t = hidGetFloat(event, UInt32(15 << 16))
            guard t > 0, t < 130 else { continue }

            let num = name.filter(\.isNumber)
            if name.hasPrefix("PMU2") {
                eSensors.append(SensorReading(id: "e\(num)-\(i)", temp: t))
            } else {
                pSensors.append(SensorReading(id: "p\(num)-\(i)", temp: t))
            }
        }

        pCluster = ClusterInfo(sensors: pSensors.sorted { $0.id < $1.id })
        eCluster = ClusterInfo(sensors: eSensors.sorted { $0.id < $1.id })

        let allTemps = pSensors.map(\.temp) + eSensors.map(\.temp)
        guard !allTemps.isEmpty else { return }
        avg = allTemps.reduce(0, +) / Double(allTemps.count)
        highest = allTemps.max()
    }
}

// MARK: - RAM Monitor

final class RAMMonitor: ObservableObject {
    @Published var percentage: Double = 0
    @Published var usedGB: Double = 0
    @Published var totalGB: Double = 0

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    deinit { timer?.invalidate() }

    func refresh() {
        guard let ram = readRAMUsage() else { return }
        percentage = ram.percentage
        usedGB = ram.usedGB
        totalGB = ram.totalGB
        objectWillChange.send()
    }
}

// MARK: - Launch at Login

final class AppSettings: ObservableObject {
    @Published var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Menu Bar App

@main
struct CPUTempApp: App {
    @StateObject private var monitor = TempMonitor()
    @StateObject private var settings = AppSettings()
    @StateObject private var ram = RAMMonitor()

    // Driven by onReceive so the MenuBarExtra label re-renders
    @State private var menuAvgText = "--"
    @State private var menuMaxText = "--"
    @State private var menuRamText = "0%"

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(monitor)
                .environmentObject(settings)
                .environmentObject(ram)
                .onReceive(monitor.objectWillChange) { _ in
                    menuAvgText = monitor.avg.map { String(format: "%.0f\u{00B0}", $0) } ?? "--"
                    menuMaxText = monitor.highest.map { String(format: "%.0f\u{00B0}", $0) } ?? "--"
                }
                .onReceive(ram.objectWillChange) { _ in
                    menuRamText = String(format: "%.0f%%", ram.percentage)
                }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 11, weight: .medium))
                VStack(alignment: .leading, spacing: -2) {
                    Text(menuAvgText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    Text(menuMaxText)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(.tertiary)
                    .frame(width: 1, height: 14)
                HStack(spacing: 3) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 10, weight: .medium))
                    Text(menuRamText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
            }
            .foregroundStyle(.primary)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Panel (dropdown)

private struct MenuPanel: View {
    @EnvironmentObject var monitor: TempMonitor
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ram: RAMMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // CPU header
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                Text(monitor.chipName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                if let avg = monitor.avg {
                    Text(String(format: "%.0f\u{00B0}", avg))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }

            Divider().background(.white.opacity(0.1)).padding(.vertical, 6)

            // Performance cluster
            if !monitor.pCluster.sensors.isEmpty {
                ClusterRow(
                    title: "P-Core",
                    count: monitor.pCoreCount,
                    avg: monitor.pCluster.avg,
                    min: monitor.pCluster.min,
                    max: monitor.pCluster.max
                )
            }

            // Efficiency cluster
            if !monitor.eCluster.sensors.isEmpty {
                ClusterRow(
                    title: "E-Core",
                    count: monitor.eCoreCount,
                    avg: monitor.eCluster.avg,
                    min: monitor.eCluster.min,
                    max: monitor.eCluster.max
                )
            }

            Divider().background(.white.opacity(0.1)).padding(.vertical, 6)

            // RAM
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.cyan)
                Text("RAM")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(String(format: "%.1f / %.1f GB  %.0f%%", ram.usedGB, ram.totalGB, ram.percentage))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(ramColor)
            }
            RAMBarView(percentage: ram.percentage)

            Divider().background(.white.opacity(0.1)).padding(.vertical, 6)

            // Footer
            HStack {
                Toggle("", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Text("Launch at Login")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(.ultraThinMaterial.opacity(0.95))
    }

    private var ramColor: Color {
        ram.percentage > 85 ? .red : ram.percentage > 65 ? .orange : .green
    }
}

// MARK: - Views

private struct ClusterRow: View {
    let title: String
    let count: Int
    let avg: Double
    let min: Double
    let max: Double

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                Text("\(count) cores")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            StatPill(label: "min", value: min)
            StatPill(label: "avg", value: avg)
            StatPill(label: "max", value: max)
        }
        .padding(.vertical, 2)
    }
}

private struct StatPill: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(spacing: 1) {
            Text(String(format: "%.0f\u{00B0}", value))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(valueColor)
            Text(label)
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(width: 40)
    }

    private var valueColor: Color {
        switch value {
        case ..<40: return .green
        case ..<60: return .yellow
        case ..<80: return .orange
        default:    return .red
        }
    }
}

private struct RAMBarView: View {
    let percentage: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.08))
                Capsule()
                    .fill(barColor.opacity(0.8))
                    .frame(width: geo.size.width * min(percentage / 100.0, 1.0))
            }
        }
        .frame(height: 3)
        .padding(.top, 4)
    }

    private var barColor: Color {
        percentage > 85 ? .red : percentage > 65 ? .orange : .green
    }
}
