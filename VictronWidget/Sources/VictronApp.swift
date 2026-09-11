import SwiftUI
import Charts
import AppKit
import Combine

// MARK: - Two colours only

extension Color {
    static let blue   = Color(red: 0.035, green: 0.588, blue: 0.878)  // #0996E0
    static let orange = Color(red: 0.992, green: 0.482, blue: 0.227)  // #FD7B3A
}

// MARK: - Space Grotesk

extension Font {
    static func hero(_ size: CGFloat) -> Font {
        .custom("Space Grotesk SemiBold", fixedSize: size)
    }
    static func heroLight(_ size: CGFloat) -> Font {
        .custom("Space Grotesk Medium", fixedSize: size)
    }
}

// MARK: - Window transparency

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let w = view.window { w.isOpaque = false; w.backgroundColor = .clear }
        }
        return view
    }
    func updateNSView(_ v: NSView, context: Context) {
        if let w = v.window { w.isOpaque = false; w.backgroundColor = .clear }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .menu
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Logo

struct VictronLogo: View {
    let height: CGFloat

    var body: some View {
        if let img = loadSVG() {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .foregroundStyle(.primary)
        } else {
            Text("VICTRON")
                .font(.hero(height * 1.2))
                .foregroundStyle(.primary)
        }
    }

    private func loadSVG() -> NSImage? {
        if let url = Bundle.module.url(forResource: "Victron_Energy_Logo", withExtension: "svg") {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

// MARK: - Store

final class VictronStore: ObservableObject {
    static let shared = VictronStore()
    @Published var data: VictronData?
    @Published var lastRefresh = Date()
    private var timer: Timer?
    private var fileSource: DispatchSourceFileSystemObject?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        watchFile()

        // Re-establish file watcher and refresh after sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.restartFileWatch()
        }
    }

    func refresh() {
        data = VictronData.load()
        lastRefresh = Date()
    }

    private func restartFileWatch() {
        fileSource?.cancel()
        fileSource = nil
        watchFile()
        refresh()
    }

    private func watchFile() {
        let path = BleDataFile.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }
}

// MARK: - App

@main
struct VictronApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - AppDelegate (colored NSStatusItem)

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.imagePosition = .imageLeading
        }

        let hosting = NSHostingController(rootView: MenuBarView())
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self

        updateButton()
        cancellable = VictronStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let store = VictronStore.shared
        let isCharging: Bool
        let socText: String

        if let d = store.data, !d.isStale {
            isCharging = d.battery.power > 50
            socText = "\(Int(d.battery.soc))%"
        } else {
            isCharging = false
            socText = "--"
        }

        // Colored bolt icon
        let accentColor: NSColor = isCharging
            ? NSColor(red: 0.035, green: 0.588, blue: 0.878, alpha: 1)
            : NSColor(red: 0.992, green: 0.482, blue: 0.227, alpha: 1)

        let config = NSImage.SymbolConfiguration(paletteColors: [accentColor])
        if let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            img.isTemplate = false
            button.image = img
        }

        let monoDigit = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)
        button.attributedTitle = NSAttributedString(
            string: socText,
            attributes: [.font: monoDigit]
        )
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Panel

private let panelWidth: CGFloat = 500
private let panelPad: CGFloat = 20

struct MenuBarView: View {
    @ObservedObject private var store = VictronStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if let data = store.data {
                PanelContent(data: data)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 28, weight: .ultraLight))
                    Text("No telemetry")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            }

            Divider()
            HStack(spacing: 8) {
                Circle().fill(Color.blue).frame(width: 5, height: 5)
                Text(refreshAgo)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Text("Quit")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, panelPad)
            .padding(.vertical, 10)
        }
        .frame(width: panelWidth)
        .background(
            ZStack { WindowAccessor(); VisualEffectBackground() }
        )
        .onAppear { store.refresh() }
    }

    private var refreshAgo: String {
        let secs = Int(Date().timeIntervalSince(store.lastRefresh))
        if secs < 2 { return "Live" }
        if secs < 60 { return "\(secs)s ago" }
        return "\(secs / 60)m ago"
    }
}

// MARK: - Panel Content

struct PanelContent: View {
    let data: VictronData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            batterySection
            Divider()
            solarSection
            Divider()
            energySection
            if data.timeseries.count >= 2 {
                Divider()
                chartSection
            }
            if !data.insights.isEmpty {
                Divider()
                notesSection
            }
            if !data.overview.devices.isEmpty {
                Divider()
                devicesSection
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VictronLogo(height: 14)
            Text("Mothership Powerplant")
                .font(.hero(13))
                .foregroundStyle(.primary)
            Spacer()
            if let alarm {
                Text(alarm)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
            } else if data.isStale {
                Text("Offline · \(timeAgo(data.lastUpdated))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange)
            } else {
                Text(timeAgo(data.lastUpdated))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, panelPad)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: Battery

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Battery", trailing: data.isStale ? "Offline" : data.battery.state.lowercased().capitalized)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(data.isStale ? "--" : String(format: "%.1f", data.battery.soc))
                    .font(.hero(64))
                    .foregroundStyle(data.isStale ? .tertiary : .primary)
                    .monospacedDigit()
                Text("%")
                    .font(.heroLight(24))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let remaining {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(remaining)
                            .font(.hero(18))
                            .foregroundStyle(.primary)
                        Text("REMAINING")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.blue)
                        .frame(width: geo.size.width * min(CGFloat(data.battery.soc / 100), 1))
                }
            }
            .frame(height: 6)

            HStack(spacing: 0) {
                if data.isStale {
                    Metric(value: "--", label: "Volts")
                    Metric(value: "--", label: "Amps")
                    Metric(value: "--", label: "Power")
                    Metric(value: "--", label: "Temp")
                } else {
                    Metric(value: String(format: "%.1fV", data.battery.voltage), label: "Volts")
                    Metric(value: String(format: "%.1fA", data.battery.current), label: "Amps")
                    Metric(
                        value: String(format: "%+.0fW", data.battery.power),
                        label: "Power",
                        color: data.battery.power >= 0 ? .blue : .orange
                    )
                    Metric(
                        value: data.battery.temperature > 0 ? "\(Int(data.battery.temperature))°C" : "--",
                        label: "Temp"
                    )
                }
            }
        }
        .padding(.horizontal, panelPad)
        .padding(.vertical, 14)
    }

    // MARK: Solar

    private var solarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Solar")
            HStack(alignment: .top, spacing: 0) {
                StatCell(
                    value: data.isStale ? "--" : "\(Int(data.solar.power))",
                    unit: "W",
                    label: "Output"
                )
                StatCell(
                    value: String(format: "%.2f", data.solar.yieldToday / 1000),
                    unit: "kWh",
                    label: "Yield",
                    accessory: yieldSub
                )
                StatCell(
                    value: peakSolar,
                    unit: "W",
                    label: "Peak"
                )
            }
        }
        .padding(.horizontal, panelPad)
        .padding(.vertical, 14)
    }

    // MARK: Energy

    private var energySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Energy today")
            HStack(alignment: .top, spacing: 0) {
                StatCell(
                    value: String(format: "+%.1f", data.todayEnergy.chargedAh),
                    unit: "Ah",
                    label: "Charged",
                    color: .blue
                )
                StatCell(
                    value: String(format: "−%.1f", data.todayEnergy.dischargedAh),
                    unit: "Ah",
                    label: "Discharged"
                )
                if data.todayEnergy.dcdcAh > 0.3 {
                    StatCell(
                        value: String(format: "%.1f", data.todayEnergy.dcdcAh),
                        unit: "Ah",
                        label: "DC-DC"
                    )
                }
                if abs(data.overview.inverter.ac_power) > 1 {
                    StatCell(
                        value: String(format: "%.0f", data.overview.inverter.ac_power),
                        unit: "W",
                        label: "AC load"
                    )
                } else if abs(data.todayEnergy.consumedAhNet) > 1 {
                    let net = data.todayEnergy.consumedAhNet
                    StatCell(
                        value: String(format: "%+.1f", -net),
                        unit: "Ah",
                        label: "Net",
                        color: net < 0 ? .blue : .orange
                    )
                }
            }
        }
        .padding(.horizontal, panelPad)
        .padding(.vertical, 14)
    }

    // MARK: Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TODAY")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.tertiary)
                Spacer()
                ChartKey(color: .blue, title: "Solar")
                ChartKey(color: .orange, title: "Current")
            }
            .padding(.horizontal, panelPad)

            IntradayChart(points: data.timeseries)
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Notes")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(data.insights.prefix(3))) { insight in
                    HStack(alignment: .top, spacing: 8) {
                        Text(moodMark(insight.mood))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(moodColor(insight.mood))
                            .frame(width: 12, alignment: .leading)
                        Text(insight.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, panelPad)
        .padding(.vertical, 14)
    }

    // MARK: Devices

    private var devicesSection: some View {
        let devs = data.overview.devices.values.sorted(by: { $0.name < $1.name })
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Devices", trailing: "\(devs.count)")
            VStack(alignment: .leading, spacing: 7) {
                ForEach(devs, id: \.address) { dev in
                    let age = Date().timeIntervalSince1970 - dev.last_seen
                    let alive = age < 120
                    HStack(spacing: 8) {
                        Circle()
                            .fill(alive ? Color.blue : .secondary.opacity(0.28))
                            .frame(width: 6, height: 6)
                        Text(dev.name)
                            .font(.system(size: 12))
                            .foregroundStyle(alive ? .primary : .secondary)
                        Spacer()
                        Text(alive ? "\(Int(age))s ago" : "Offline")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, panelPad)
        .padding(.vertical, 14)
    }

    // MARK: Derived

    private var alarm: String? {
        let raw = data.overview.alarm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "ok", "no alarm", "none", "0": return nil
        default: return raw
        }
    }

    private var remaining: String? {
        let mins = data.battery.remaining_mins
        guard !data.isStale, mins > 0, data.battery.power < -20 else { return nil }
        let total = Int(mins)
        if total >= 1440 { return "\(total / 1440)d \(total % 1440 / 60)h" }
        if total >= 60 { return "\(total / 60)h \(total % 60)m" }
        return "\(total)m"
    }

    private var peakSolar: String {
        guard !data.isStale, let peak = data.dailyStats.last?.solarPeakPower, peak > 0 else { return "--" }
        return "\(Int(peak))"
    }

    private var yieldSub: String? {
        guard let diff = data.yieldDiffPercent else { return nil }
        let sign = diff >= 0 ? "+" : ""
        return "\(sign)\(Int(diff))%"
    }

    private func moodMark(_ mood: VictronData.Insight.Mood) -> String {
        switch mood {
        case .positive: return "+"
        case .negative: return "−"
        case .warning:  return "!"
        case .neutral:  return "·"
        }
    }

    private func moodColor(_ mood: VictronData.Insight.Mood) -> Color {
        switch mood {
        case .positive: return .blue
        case .negative, .warning: return .orange
        case .neutral: return .secondary
        }
    }

    func timeAgo(_ ms: Double) -> String {
        let secs = Int(Date().timeIntervalSince1970 - ms / 1000)
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }
}

// MARK: - Components

struct SectionLabel: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.tertiary)
            Spacer()
            if let trailing {
                Text(trailing.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct Metric: View {
    let value: String
    let label: String
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(color ?? Color.primary)
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatCell: View {
    let value: String
    let unit: String
    let label: String
    var accessory: String? = nil
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.hero(26))
                    .foregroundStyle(color ?? Color.primary)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 5) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.tertiary)
                if let accessory {
                    Text(accessory)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accessory.hasPrefix("+") ? Color.blue : Color.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChartKey: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Chart — edge to edge, no Y axis

struct IntradayChart: View {
    let points: [VictronData.TimePoint]

    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { idx, point in
                AreaMark(
                    x: .value("T", idx),
                    yStart: .value("B", 0),
                    yEnd: .value("S", point.solar),
                    series: .value("S", "Solar")
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.18), Color.blue.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("T", idx),
                    y: .value("S", point.solar),
                    series: .value("S", "Solar")
                )
                .foregroundStyle(Color.blue.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("T", idx),
                    y: .value("C", point.current * 10),
                    series: .value("S", "Cur")
                )
                .foregroundStyle(Color.orange.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .interpolationMethod(.catmullRom)
            }

            RuleMark(y: .value("Z", 0))
                .foregroundStyle(.quaternary)
                .lineStyle(StrokeStyle(lineWidth: 0.5))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                if let idx = value.as(Int.self), idx < points.count {
                    AxisValueLabel(anchor: .top) {
                        Text(points[idx].t)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.padding(.horizontal, 0)
        }
        .frame(height: 148)
    }
}
