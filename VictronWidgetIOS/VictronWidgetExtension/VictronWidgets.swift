import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct VictronEntry: TimelineEntry {
    let date: Date
    let data: VictronData?
    let error: String?

    static var placeholder: VictronEntry {
        VictronEntry(date: .now, data: nil, error: nil)
    }
}

// MARK: - Provider

struct VictronProvider: TimelineProvider {
    func placeholder(in context: Context) -> VictronEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (VictronEntry) -> Void) {
        Task {
            let entry = await fetchEntry()
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VictronEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            let minutes = entry.error == nil ? 5 : 1
            let next = Calendar.current.date(byAdding: .minute, value: minutes, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func fetchEntry() async -> VictronEntry {
        do {
            let data = try await VictronAPI.fetch()
            return VictronEntry(date: .now, data: data, error: nil)
        } catch {
            return VictronEntry(date: .now, data: nil, error: error.localizedDescription)
        }
    }
}

// MARK: - Colors (matching macOS widget)

private let victronBlue = Color(red: 0.035, green: 0.588, blue: 0.878)
private let victronOrange = Color(red: 0.992, green: 0.482, blue: 0.227)

// MARK: - Small Widget

struct VictronSmallWidget: Widget {
    let kind = "VictronSmall"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VictronProvider()) { entry in
            SmallWidgetView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Battery")
        .description("Battery SOC and solar power")
        .supportedFamilies([.systemSmall])
    }
}

struct SmallWidgetView: View {
    let entry: VictronEntry

    var body: some View {
        if let data = entry.data {
            VStack(alignment: .leading, spacing: 6) {
                // SOC hero
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(data.isStale ? "--" : String(format: "%.0f", data.battery.soc))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(data.isStale ? .secondary : .primary)
                    Text("%")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                // SOC bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(.white.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(data.isStale ? .gray : victronBlue)
                            .frame(width: geo.size.width * min(data.battery.soc / 100, 1))
                    }
                }
                .frame(height: 5)

                Spacer(minLength: 2)

                // Solar
                HStack(spacing: 4) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                    Text("\(Int(data.solar.power))W")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }

                // Battery power + direction
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(data.battery.power > 50 ? victronBlue : victronOrange)
                    Text(String(format: "%+.0fW", data.battery.power))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }

                // Status
                Text(data.isStale ? "Offline" : data.batteryDirection)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(data.isStale ? victronOrange : .secondary)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(entry.error ?? "No data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Medium Widget

struct VictronMediumWidget: Widget {
    let kind = "VictronMedium"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VictronProvider()) { entry in
            MediumWidgetView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Powerplant")
        .description("Battery, solar, and energy overview")
        .supportedFamilies([.systemMedium])
    }
}

struct MediumWidgetView: View {
    let entry: VictronEntry

    var body: some View {
        if let data = entry.data {
            HStack(spacing: 16) {
                // Left: battery
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(data.isStale ? "--" : String(format: "%.0f", data.battery.soc))
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(data.isStale ? .secondary : .primary)
                        Text("%")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(.white.opacity(0.1))
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(data.isStale ? .gray : victronBlue)
                                .frame(width: geo.size.width * min(data.battery.soc / 100, 1))
                        }
                    }
                    .frame(height: 5)

                    Spacer(minLength: 0)

                    // Voltage / current
                    HStack(spacing: 8) {
                        Text(String(format: "%.1fV", data.battery.voltage))
                        Text(String(format: "%.1fA", data.battery.current))
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                    Text(data.isStale ? "Offline" : data.batteryDirection)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(data.isStale ? victronOrange : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right: stats
                VStack(alignment: .leading, spacing: 10) {
                    // Solar
                    HStack(spacing: 6) {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.yellow)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(Int(data.solar.power))W")
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                            Text("Solar")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Yield
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(String(format: "%.2f kWh", data.solar.yieldToday / 1000))
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                            HStack(spacing: 2) {
                                Text("Yield")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                if let diff = data.yieldDiffPercent {
                                    Text(String(format: "%+.0f%% vs this hour", diff))
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(diff >= 0 ? victronBlue : victronOrange)
                                }
                            }
                        }
                    }

                    // Battery power
                    HStack(spacing: 6) {
                        Image(systemName: "battery.100.bolt")
                            .font(.system(size: 12))
                            .foregroundStyle(data.battery.power > 50 ? victronBlue : victronOrange)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(String(format: "%+.0fW", data.battery.power))
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                            Text("Net")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Energy Ah
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text("+\(String(format: "%.1f", data.todayEnergy.chargedAh)) / -\(String(format: "%.1f", data.todayEnergy.dischargedAh)) Ah")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Victron")
                        .font(.headline)
                    Text(entry.error ?? "No data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    VictronSmallWidget()
} timeline: {
    VictronEntry.placeholder
}

#Preview("Medium", as: .systemMedium) {
    VictronMediumWidget()
} timeline: {
    VictronEntry.placeholder
}
