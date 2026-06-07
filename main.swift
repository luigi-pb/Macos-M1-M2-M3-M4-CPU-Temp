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

// MARK: - Data

struct SensorReading: Identifiable {
    let id: String
    let temp: Double
}

struct ClusterInfo {
    var sensors: [SensorReading] = []
    var avg: Double { sensors.isEmpty ? 0 : sensors.map(\.temp).reduce(0, +) / Double(sensors.count) }
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
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
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

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 0) {
                // App header
                HStack(spacing: 10) {
                    Image(systemName: "thermometer.sun.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(
                            .linearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CPU Temp")
                            .font(.system(size: 13, weight: .semibold))
                        Text(monitor.chipName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.bottom, 12)

                // AVG / MAX
                HStack(spacing: 16) {
                    SummaryCell(label: "AVG", value: monitor.avg)
                    SummaryCell(label: "MAX", value: monitor.highest)
                }
                .padding(.bottom, 12)

                // Performance cluster
                if !monitor.pCluster.sensors.isEmpty {
                    ClusterHeader(
                        title: "Performance",
                        cores: monitor.pCoreCount,
                        avg: monitor.pCluster.avg,
                        max: monitor.pCluster.max
                    )
                    SensorGrid(sensors: monitor.pCluster.sensors)
                        .padding(.bottom, 8)
                }

                // Efficiency cluster
                if !monitor.eCluster.sensors.isEmpty {
                    ClusterHeader(
                        title: "Efficiency",
                        cores: monitor.eCoreCount,
                        avg: monitor.eCluster.avg,
                        max: monitor.eCluster.max
                    )
                    SensorGrid(sensors: monitor.eCluster.sensors)
                }

                Divider().padding(.top, 10)

                // Settings
                Toggle(isOn: $settings.launchAtLogin) {
                    Label("Launch at Login", systemImage: "gear")
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 8)

                Divider().padding(.top, 8)

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .padding(.top, 6)
            }
            .padding(16)
            .frame(width: 240)
        } label: {
            let avgText = monitor.avg.map { String(format: "%.0f\u{00B0}", $0) } ?? "--"
            let maxText = monitor.highest.map { String(format: "%.0f\u{00B0}", $0) } ?? "--"
            HStack(spacing: 2) {
                Image(systemName: "thermometer.medium")
                VStack(alignment: .leading, spacing: -1) {
                    Text(avgText)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                    Text(maxText)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Views

struct SummaryCell: View {
    let label: String
    let value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value.map { String(format: "%.0f\u{00B0}C", $0) } ?? "\u{2014}")
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ClusterHeader: View {
    let title: String
    let cores: Int
    let avg: Double
    let max: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("\u{00B7} \(cores) cores")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(String(format: "%.0f\u{00B0} / %.0f\u{00B0}", avg, max))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

struct SensorGrid: View {
    let sensors: [SensorReading]

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(sensors) { s in
                Text(String(format: "%.0f\u{00B0}", s.temp))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
