import SwiftUI
import WidgetKit

@main
struct VictronWidgetApp: App {
    @AppStorage("apiBaseURL", store: UserDefaults(suiteName: appGroupID))
    private var apiBaseURL = "http://localhost:3000"

    @State private var data: VictronData?
    @State private var error: String?
    @State private var loading = true

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        // URL config
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Dashboard URL")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("http://192.168.1.100:3000", text: $apiBaseURL)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .onSubmit {
                                    VictronAPI.setBaseURL(apiBaseURL)
                                    WidgetCenter.shared.reloadAllTimelines()
                                    Task { await refresh() }
                                }
                        }
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                        if loading {
                            ProgressView("Connecting...")
                                .padding(40)
                        } else if let error {
                            VStack(spacing: 8) {
                                Image(systemName: "wifi.slash")
                                    .font(.title)
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Retry") { Task { await refresh() } }
                                    .buttonStyle(.bordered)
                            }
                            .padding(40)
                        } else if let data {
                            LiveDataView(data: data)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Victron")
                .refreshable { await refresh() }
            }
            .task { await refresh() }
        }
    }

    func refresh() async {
        loading = data == nil
        do {
            data = try await VictronAPI.fetch()
            error = nil
            loading = false
        } catch {
            if data == nil {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

// MARK: - Live data view (in-app)

struct LiveDataView: View {
    let data: VictronData

    var body: some View {
        VStack(spacing: 16) {
            // Battery hero
            VStack(spacing: 8) {
                HStack(alignment: .lastTextBaseline) {
                    Text(data.isStale ? "--" : String(format: "%.0f", data.battery.soc))
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                    Text("%")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(data.isStale ? "Offline" : data.batteryDirection)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(barColor)
                            .frame(width: geo.size.width * min(data.battery.soc / 100, 1))
                    }
                }
                .frame(height: 8)

                HStack {
                    Label(String(format: "%.1fV", data.battery.voltage), systemImage: "bolt")
                    Spacer()
                    Label(String(format: "%.1fA", data.battery.current), systemImage: "arrow.left.arrow.right")
                    Spacer()
                    Label(String(format: "%.0fW", data.battery.power), systemImage: "powerplug")
                    Spacer()
                    if data.battery.temperature > 0 {
                        Label("\(Int(data.battery.temperature))°", systemImage: "thermometer.medium")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            // Solar + yield
            HStack(spacing: 12) {
                StatBlock(
                    icon: "sun.max.fill",
                    iconColor: .yellow,
                    value: "\(Int(data.solar.power))",
                    unit: "W",
                    label: "Solar"
                )
                StatBlock(
                    icon: "bolt.fill",
                    iconColor: .green,
                    value: String(format: "%.2f", data.solar.yieldToday / 1000),
                    unit: "kWh",
                    label: "Yield"
                )
            }

            // Energy in/out
            HStack(spacing: 12) {
                StatBlock(
                    icon: "arrow.down.circle.fill",
                    iconColor: .blue,
                    value: String(format: "%.1f", data.todayEnergy.chargedAh),
                    unit: "Ah",
                    label: "Charged"
                )
                StatBlock(
                    icon: "arrow.up.circle.fill",
                    iconColor: .orange,
                    value: String(format: "%.1f", data.todayEnergy.dischargedAh),
                    unit: "Ah",
                    label: "Discharged"
                )
            }

            // Devices
            VStack(alignment: .leading, spacing: 6) {
                Text("\(data.deviceCount) devices")
                    .font(.caption.bold())
                ForEach(Array(data.overview.devices.values.sorted(by: { $0.name < $1.name })), id: \.address) { dev in
                    let age = Date().timeIntervalSince1970 - dev.last_seen
                    let alive = age < 120
                    HStack {
                        Circle()
                            .fill(alive ? .green : .gray)
                            .frame(width: 6, height: 6)
                        Text(dev.name)
                            .font(.caption)
                        Spacer()
                        Text(alive ? "\(Int(age))s" : "Offline")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    var barColor: Color {
        if data.battery.soc > 60 { return .green }
        if data.battery.soc > 30 { return .yellow }
        return .red
    }
}

struct StatBlock: View {
    let icon: String
    let iconColor: Color
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.caption)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title2.bold().monospacedDigit())
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
