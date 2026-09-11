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
        let t = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        watchFile()

        // Re-establish file watcher and refresh after sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.restartFileWatch()
        }
        NotificationCenter.default.addObserver(
            forName: .installationDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
            self?.refresh()
        }
    }

    var installationTitle: String {
        if let n = data?.installationName, !n.isEmpty { return n }
        if let n = InstallationConfig.load()?.installationName, !n.isEmpty { return n }
        return "Victron"
    }

    func refresh() {
        if let loaded = VictronData.load() {
            data = loaded
            lastRefresh = Date()
        }
    }

    private func restartFileWatch() {
        fileSource?.cancel()
        fileSource = nil
        watchFile()
        refresh()
    }

    private func scheduleWatchRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.fileSource == nil else { return }
            self.watchFile()
        }
    }

    private func watchFile() {
        let path = BleDataFile.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleWatchRetry()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            self.refresh()
            // Atomic replace invalidates this fd; re-open the new inode.
            if flags.contains(.rename) || flags.contains(.delete) {
                self.restartFileWatch()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }
}

// MARK: - Weekly solar forecast

final class ForecastStore: ObservableObject {
    static let shared = ForecastStore()

    @Published var days: [ForecastDay] = []
    @Published var todayIso: String?
    @Published var todayKwh: Double?
    @Published var error: String?

    var todayKwhText: String? {
        guard let kwh = todayKwh else { return nil }
        return String(format: "TODAY %.1f kWh", kwh)
    }

    private init() {
        Task { await fetch() }
        let t = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
    }

    func refresh() {
        Task { await fetch() }
    }

    private func fetch() async {
        let bases = [
            "http://127.0.0.1:3001",
            "http://localhost:3001",
            "http://127.0.0.1:3000",
            "http://localhost:3000",
        ]
        for base in bases {
            guard let url = URL(string: "\(base)/api/forecast") else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                let decoded = try JSONDecoder().decode(ForecastPayload.self, from: data)
                await MainActor.run { apply(decoded) }
                return
            } catch {
                continue
            }
        }
        await MainActor.run {
            if days.isEmpty {
                self.error = "Dashboard offline — start it to load forecast"
            }
        }
    }

    private func apply(_ payload: ForecastPayload) {
        if let err = payload.error {
            error = payload.message ?? err
            return
        }
        if payload.needsLocation == true, (payload.days ?? []).isEmpty {
            error = payload.message ?? "Dashboard could not resolve site location"
            return
        }
        error = nil
        todayIso = payload.todayIso
        todayKwh = payload.estimate?.todayKwh
        days = payload.days ?? []
    }
}

struct ForecastPayload: Codable {
    var needsLocation: Bool?
    var message: String?
    var error: String?
    var todayIso: String?
    var estimate: ForecastEstimate?
    var days: [ForecastDay]?
}

struct ForecastEstimate: Codable {
    var todayKwh: Double?
    var remainingKwh: Double?
    var producedKwh: Double?
}

struct ForecastDay: Codable, Identifiable {
    var date: String
    var weatherCode: Int
    var estimatedKwh: Double
    var tempMax: Double?
    var id: String { date }

    var weekday: String {
        let inFmt = DateFormatter()
        inFmt.calendar = Calendar(identifier: .gregorian)
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.dateFormat = "yyyy-MM-dd"
        guard let d = inFmt.date(from: date) else { return "" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "EEE"
        return out.string(from: d).uppercased()
    }

    var symbol: String {
        let c = weatherCode
        if c == 0 || c == 1 { return "sun.max" }
        if c == 2 { return "cloud.sun" }
        if c == 3 { return "cloud" }
        if c == 45 || c == 48 { return "cloud.fog" }
        if (51...67).contains(c) || (80...82).contains(c) { return "cloud.rain" }
        if (71...77).contains(c) || (85...86).contains(c) { return "cloud.snow" }
        if c >= 95 { return "cloud.bolt.rain" }
        return "cloud"
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

// MARK: - Panel size (16:9)

private let panelWidth: CGFloat = 960
private let panelHeight: CGFloat = 540
private let panelPad: CGFloat = 16

// MARK: - AppDelegate (colored NSStatusItem)

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?
    private var wizardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.imagePosition = .imageLeading
        }

        let hosting = NSHostingController(rootView: MenuBarView())
        hosting.sizingOptions = [.preferredContentSize]
        hosting.preferredContentSize = NSSize(width: panelWidth, height: panelHeight)
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: panelWidth, height: panelHeight)
        popover.behavior = .transient
        popover.delegate = self

        updateButton()
        cancellable = VictronStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        }
        NotificationCenter.default.addObserver(
            forName: .openInstallationWizard, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showWizard()
        }
        if !InstallationConfig.isConfigured {
            DispatchQueue.main.async { [weak self] in self?.showWizard() }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let store = VictronStore.shared
        let socText: String

        let accentColor: NSColor
        if let d = store.data, !d.isStale {
            socText = "\(Int(d.battery.soc))%"
            if d.battery.power > 15 {
                accentColor = NSColor(red: 0.035, green: 0.588, blue: 0.878, alpha: 1)
            } else if d.battery.power < -15 {
                accentColor = NSColor(red: 0.992, green: 0.482, blue: 0.227, alpha: 1)
            } else {
                accentColor = NSColor.secondaryLabelColor
            }
        } else {
            socText = "--"
            accentColor = NSColor.secondaryLabelColor
        }

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
        if !InstallationConfig.isConfigured {
            showWizard()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !InstallationConfig.isConfigured {
            showWizard()
        } else {
            showPopover()
        }
        return false
    }

    func showWizard() {
        let configured = InstallationConfig.isConfigured
        let root = SetupWizardView(
            onComplete: { [weak self] in
                self?.wizardWindow?.close()
                VictronStore.shared.refresh()
            },
            onCancel: configured ? { [weak self] in self?.wizardWindow?.close() } : nil
        )
        let hosting = NSHostingController(rootView: root)
        if let window = wizardWindow {
            window.contentViewController = hosting
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Installation"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 560, height: 640))
            window.center()
            wizardWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.contentSize = NSSize(width: panelWidth, height: panelHeight)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Panel

struct MenuBarView: View {
    @ObservedObject private var store = VictronStore.shared
    @ObservedObject private var bluetooth = BluetoothStatus.shared

    var body: some View {
        VStack(spacing: 0) {
            if bluetooth.isPoweredOff {
                BluetoothOffBanner()
            }
            header
            Divider()
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: panelWidth, height: panelHeight)
        .background(
            ZStack { WindowAccessor(); VisualEffectBackground() }
        )
        .onAppear {
            store.refresh()
            ForecastStore.shared.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VictronLogo(height: 13)
            Text(store.installationTitle)
                .font(.hero(12))
            if let data = store.data {
                if let alarm = alarmText(data) {
                    Text(alarm)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                } else if bluetooth.isPoweredOff {
                    Text("Bluetooth off")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.orange)
                } else if data.isStale {
                    Text("Offline")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.orange)
                }
            }
            Spacer()
            Circle().fill(Color.blue).frame(width: 5, height: 5)
            Text(refreshAgo)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button { store.refresh() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Button {
                NotificationCenter.default.post(name: .openInstallationWizard, object: nil)
            } label: {
                Text("Edit")
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

    private func alarmText(_ data: VictronData) -> String? {
        let raw = data.overview.alarm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "ok", "no alarm", "none", "0": return nil
        default: return raw
        }
    }

    private var refreshAgo: String {
        let secs = Int(Date().timeIntervalSince(store.lastRefresh))
        if secs < 2 { return "Live" }
        if secs < 60 { return "\(secs)s ago" }
        return "\(secs / 60)m ago"
    }
}

// MARK: - Panel Content (landscape)

struct PanelContent: View {
    let data: VictronData
    @ObservedObject private var forecast = ForecastStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                inputColumn
                VRule()
                batteryColumn
                VRule()
                outputColumn
            }
            .frame(height: 156)

            Divider()

            chartBlock
                .frame(maxHeight: .infinity)

            Divider()

            forecastBlock
                .frame(height: 86)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                notesBlock
                VRule()
                devicesBlock
            }
            .frame(height: 96)
        }
    }

    private var inputColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Input")

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(data.isStale ? "--" : "\(Int(inputWatts.rounded()))")
                    .font(.hero(36))
                    .foregroundStyle(inputNumberColor)
                    .monospacedDigit()
                Text("W")
                    .font(.heroLight(14))
                    .foregroundStyle(.tertiary)
            }

            StatRow(
                value: String(format: "%.2f", data.solar.yieldToday / 1000),
                unit: "kWh",
                label: "Yield",
                accessory: yieldSub
            )
            if liveDcdcWatts > 40 {
                StatRow(
                    value: "\(Int(liveDcdcWatts.rounded()))",
                    unit: "W",
                    label: "DC-DC",
                    color: .blue
                )
            } else if data.todayEnergy.dcdcAh > 0.3 {
                StatRow(
                    value: String(format: "%.1f", data.todayEnergy.dcdcAh),
                    unit: "Ah",
                    label: "DC-DC today",
                    color: .blue
                )
            }
        }
        .padding(.horizontal, panelPad)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var batteryColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Battery", trailing: data.isStale ? "Offline" : data.battery.state.lowercased().capitalized)

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(data.isStale ? "--" : String(format: "%.1f", data.battery.soc))
                    .font(.hero(52))
                    .foregroundStyle(data.isStale ? .tertiary : .primary)
                    .monospacedDigit()
                Text("%")
                    .font(.heroLight(20))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(data.isStale ? "--" : String(format: "%+.0f", data.battery.power))
                            .font(.hero(22))
                            .foregroundStyle(flowColor)
                            .monospacedDigit()
                        Text("W")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Text(data.isStale ? "--" : String(format: "%+.1fA", data.battery.current))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(flowColor)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(flow == .idle ? Color.blue.opacity(0.55) : flowColor)
                        .frame(width: geo.size.width * min(CGFloat(data.battery.soc / 100), 1))
                }
            }
            .frame(height: 5)

            HStack(spacing: 0) {
                Metric(
                    value: data.isStale ? "--" : String(format: "%.1fV", data.battery.voltage),
                    label: "Volts"
                )
                Metric(
                    value: remaining ?? "—",
                    label: "Remaining"
                )
                Metric(
                    value: data.isStale ? "—" : flowLabel,
                    label: "State",
                    color: flowColor
                )
            }
        }
        .padding(.horizontal, panelPad)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var outputColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Output")

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(data.isStale ? "--" : "\(Int(loadWatts.rounded()))")
                    .font(.hero(36))
                    .foregroundStyle(outputNumberColor)
                    .monospacedDigit()
                Text("W")
                    .font(.heroLight(14))
                    .foregroundStyle(.tertiary)
            }

            if abs(data.overview.inverter.ac_power) > 1 {
                StatRow(
                    value: String(format: "%.0f", abs(data.overview.inverter.ac_power)),
                    unit: "W",
                    label: "AC load",
                    color: .orange
                )
            }
            if flow == .discharging {
                StatRow(
                    value: String(format: "%.0f", abs(data.battery.power)),
                    unit: "W",
                    label: "From battery",
                    color: .orange
                )
            }
            if data.todayEnergy.dischargedAh > 0.3 {
                StatRow(
                    value: String(format: "%.1f", data.todayEnergy.dischargedAh),
                    unit: "Ah",
                    label: "Used today",
                    color: .orange
                )
            }
        }
        .padding(.horizontal, panelPad)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var chartBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("TODAY · THIS MAC")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.tertiary)
                Spacer()
                ChartKey(color: .blue, title: "Solar")
                ChartKey(color: .orange, title: "Current")
            }
            .padding(.horizontal, panelPad)
            .padding(.top, 8)

            if data.timeseries.count >= 2 {
                IntradayChart(points: data.timeseries)
                    .padding(.bottom, 4)
            } else {
                Text("No samples yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var forecastBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("FORECAST")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let today = forecast.todayKwhText {
                    Text(today)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.blue)
                }
            }
            if let err = forecast.error, forecast.days.isEmpty {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if forecast.days.isEmpty {
                Text("Loading week…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 0) {
                    ForEach(forecast.days.prefix(7)) { day in
                        ForecastDayCell(day: day, isToday: day.date == forecast.todayIso)
                    }
                }
            }
        }
        .padding(.horizontal, panelPad)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Notes")
            if data.insights.isEmpty {
                Text("Quiet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(data.insights.prefix(3))) { insight in
                            HStack(alignment: .top, spacing: 6) {
                                Text(moodMark(insight.mood))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(moodColor(insight.mood))
                                    .frame(width: 10, alignment: .leading)
                                Text(insight.text)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, panelPad)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var devicesBlock: some View {
        let devs = data.overview.devices.values.sorted(by: { $0.name < $1.name })
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Devices", trailing: "\(devs.count)")
            if devs.isEmpty {
                Text("None")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(devs, id: \.address) { dev in
                            let age = Date().timeIntervalSince1970 - dev.last_seen
                            let alive = age < 120
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(alive ? Color.blue : .secondary.opacity(0.28))
                                    .frame(width: 5, height: 5)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(dev.name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(alive ? .primary : .secondary)
                                        .lineLimit(1)
                                    if let summary = dev.summary, !summary.isEmpty {
                                        Text(summary)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    } else if let label = dev.typeLabel, !label.isEmpty {
                                        Text(label)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(alive ? "\(Int(age))s" : "Off")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, panelPad)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private enum Flow { case charging, discharging, idle }

    private var flow: Flow {
        if data.isStale { return .idle }
        if data.battery.power > 15 { return .charging }
        if data.battery.power < -15 { return .discharging }
        return .idle
    }

    private var flowColor: Color {
        switch flow {
        case .charging: return .blue
        case .discharging: return .orange
        case .idle: return .secondary
        }
    }

    private var flowLabel: String {
        switch flow {
        case .charging: return "Charging"
        case .discharging: return "Discharging"
        case .idle: return "Idle"
        }
    }

    private var liveDcdcWatts: Double {
        guard !data.isStale, data.battery.power > 50 else { return 0 }
        let extra = data.battery.power - max(data.solar.power, 0)
        return extra > 40 ? extra : 0
    }

    private var inputWatts: Double {
        guard !data.isStale else { return 0 }
        return max(data.solar.power, 0) + liveDcdcWatts
    }

    private var loadWatts: Double {
        guard !data.isStale else { return 0 }
        return max(0, max(data.solar.power, 0) + liveDcdcWatts - data.battery.power)
    }

    private var inputNumberColor: Color {
        if data.isStale || inputWatts < 5 { return .secondary }
        return .blue
    }

    private var outputNumberColor: Color {
        if data.isStale || loadWatts < 5 { return .secondary }
        return .orange
    }

    private var remaining: String? {
        let mins = data.battery.remaining_mins
        guard !data.isStale, mins > 0, data.battery.power < -20 else { return nil }
        let total = Int(mins)
        if total >= 1440 { return "\(total / 1440)d \(total % 1440 / 60)h" }
        if total >= 60 { return "\(total / 60)h \(total % 60)m" }
        return "\(total)m"
    }

    private var yieldSub: String? {
        guard let diff = data.yieldDiffPercent else { return nil }
        let sign = diff >= 0 ? "+" : ""
        return "\(sign)\(Int(diff))% vs this hour"
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
}

struct VRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(width: 1)
    }
}

struct ForecastDayCell: View {
    let day: ForecastDay
    let isToday: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(isToday ? "TODAY" : day.weekday)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(isToday ? Color.blue : Color.secondary.opacity(0.7))
            Image(systemName: day.symbol)
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(isToday ? Color.blue : Color.secondary)
                .frame(height: 16)
            Text(String(format: "%.1f", day.estimatedKwh))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isToday ? Color.blue : Color.primary)
            Text("kWh")
                .font(.system(size: 8))
                .foregroundStyle(Color.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }
}

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
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(color ?? Color.primary)
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatRow: View {
    let value: String
    let unit: String
    let label: String
    var accessory: String? = nil
    var color: Color? = nil

    var body: some View {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.hero(18))
                    .foregroundStyle(color ?? Color.primary)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.tertiary)
                if let accessory {
                    Text(accessory)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accessory.hasPrefix("+") ? Color.blue : Color.orange)
                }
                Spacer(minLength: 0)
            }
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
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
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
    }
}
