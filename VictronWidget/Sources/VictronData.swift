import Foundation

enum BleDataFile {
    static var path: String {
        if let env = ProcessInfo.processInfo.environment["VICTRON_BLE_DATA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let candidates = [
            cwd.appendingPathComponent("victron-dashboard/ble-data.json"),
            cwd.appendingPathComponent("../victron-dashboard/ble-data.json"),
            home.appendingPathComponent("victron-dashboard/ble-data.json"),
            home.appendingPathComponent("Fabrique/victron shit/victron-dashboard/ble-data.json"),
        ]
        for url in candidates {
            let path = url.standardizedFileURL.path
            if fm.fileExists(atPath: path) { return path }
        }
        return home.appendingPathComponent("victron-dashboard/ble-data.json").path
    }
}

struct VictronData: Codable {
    let overview: Overview
    let dailyStats: [DailyStat]
    let timeseries: [TimePoint]
    let todayEnergy: TodayEnergy
    let lastUpdated: Double
    let deviceCount: Int

    struct TodayEnergy: Codable {
        let chargedAh: Double
        let dischargedAh: Double
        let dcdcAh: Double
        let solarYield: Double
        let consumedAhNet: Double
    }

    struct Overview: Codable {
        let battery: Battery
        let solar: Solar
        let inverter: Inverter
        let alarm: String
        let devices: [String: DeviceInfo]
    }

    struct Battery: Codable {
        let soc: Double
        let voltage: Double
        let current: Double
        let power: Double
        let state: String
        let temperature: Double
        let consumed_ah: Double
        let remaining_mins: Double
    }

    struct Solar: Codable {
        let power: Double
        let yieldToday: Double
    }

    struct Inverter: Codable {
        let ac_power: Double
    }

    struct DeviceInfo: Codable {
        let address: String
        let name: String
        let last_seen: Double
        let fields: [String]
    }

    struct DailyStat: Codable {
        let date: String
        let solarYield: Double
        let solarPeakPower: Double
        let batterySOCMin: Double
        let batterySOCMax: Double
        let chargedAh: Double?
        let dischargedAh: Double?
        let dcdcAh: Double?
        let samples: Int
    }

    struct TimePoint: Codable, Identifiable {
        let t: String
        let solar: Double
        let current: Double
        let soc: Double
        var id: String { t }
    }

    var isStale: Bool {
        // Check if any device was actually heard from recently (last_seen is in seconds)
        let now = Date().timeIntervalSince1970
        let newestDevice = overview.devices.values.map(\.last_seen).max() ?? 0
        return (now - newestDevice) > 120
    }

    var batteryDirection: String {
        if battery.power > 50 { return "Charging" }
        if battery.power < -50 { return "Discharging" }
        return "Idle"
    }

    var battery: Battery { overview.battery }
    var solar: Solar { overview.solar }

    /// Net battery power from BMS (positive = charging, negative = discharging)
    var netPower: Double { battery.power }

    var yieldDiffPercent: Double? {
        guard dailyStats.count >= 2 else { return nil }
        let today = dailyStats[dailyStats.count - 1]
        let yesterday = dailyStats[dailyStats.count - 2]
        guard yesterday.solarYield > 0 else { return nil }
        return ((today.solarYield - yesterday.solarYield) / yesterday.solarYield) * 100
    }

    static func load() -> VictronData? {
        let path = BleDataFile.path
        guard let rawData = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(VictronData.self, from: rawData)
    }

    // MARK: - Insights Engine

    struct Insight: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
        let mood: Mood

        enum Mood {
            case positive, negative, neutral, warning
        }
    }

    var insights: [Insight] {
        var results: [Insight] = []
        let stats = dailyStats
        guard !stats.isEmpty else { return results }

        let today = stats.last!
        let previous = Array(stats.dropLast())

        // --- Record solar yield ---
        if previous.count >= 2 {
            let prevMax = previous.map(\.solarYield).max() ?? 0
            if today.solarYield > prevMax && today.solarYield > 0 {
                results.append(Insight(
                    icon: "trophy.fill",
                    text: "Record day! Best solar yield ever recorded: \(fmtWh(today.solarYield))",
                    mood: .positive
                ))
            }
        }

        // --- Record peak solar power ---
        if previous.count >= 2 {
            let prevPeakMax = previous.map(\.solarPeakPower).max() ?? 0
            if today.solarPeakPower > prevPeakMax && today.solarPeakPower > 0 {
                results.append(Insight(
                    icon: "sun.max.trianglebadge.exclamationmark",
                    text: "Peak solar power record: \(Int(today.solarPeakPower))W — highest ever seen",
                    mood: .positive
                ))
            }
        }

        // --- Yield vs yesterday ---
        if let yesterday = previous.last, yesterday.solarYield > 0 {
            let diff = ((today.solarYield - yesterday.solarYield) / yesterday.solarYield) * 100
            if diff > 20 {
                results.append(Insight(
                    icon: "arrow.up.right",
                    text: "Charged \(Int(diff))% more than yesterday (\(fmtWh(today.solarYield)) vs \(fmtWh(yesterday.solarYield)))",
                    mood: .positive
                ))
            } else if diff < -20 {
                results.append(Insight(
                    icon: "arrow.down.right",
                    text: "Charged \(Int(abs(diff)))% less than yesterday (\(fmtWh(today.solarYield)) vs \(fmtWh(yesterday.solarYield)))",
                    mood: .negative
                ))
            }
        }

        // --- Consecutive declining days ---
        if stats.count >= 3 {
            var decliningDays = 0
            for i in stride(from: stats.count - 1, through: 1, by: -1) {
                if stats[i].solarYield < stats[i - 1].solarYield {
                    decliningDays += 1
                } else {
                    break
                }
            }
            if decliningDays >= 2 {
                results.append(Insight(
                    icon: "chart.line.downtrend.xyaxis",
                    text: "\(decliningDays) days of declining solar — yields are trending down",
                    mood: .warning
                ))
            }
        }

        // --- SOC trend / empty projection ---
        if stats.count >= 2 {
            // Check consecutive days where SOC min kept dropping
            var negativeDays = 0
            for i in stride(from: stats.count - 1, through: 1, by: -1) {
                if stats[i].batterySOCMin < stats[i - 1].batterySOCMin {
                    negativeDays += 1
                } else {
                    break
                }
            }
            if negativeDays >= 2 {
                let dailyDrop = stats.last!.batterySOCMin - stats[stats.count - 1 - negativeDays].batterySOCMin
                let avgDrop = abs(dailyDrop) / Double(negativeDays)
                if avgDrop > 0 {
                    let daysToEmpty = Int(battery.soc / avgDrop)
                    if daysToEmpty <= 5 {
                        results.append(Insight(
                            icon: "battery.0",
                            text: "Battery trending down for \(negativeDays) days. At this rate, empty in ~\(daysToEmpty) days",
                            mood: .warning
                        ))
                    } else if daysToEmpty <= 14 {
                        results.append(Insight(
                            icon: "arrow.down",
                            text: "SOC dropping \(String(format: "%.0f", avgDrop))%/day for \(negativeDays) days — ~\(daysToEmpty) days of reserves",
                            mood: .negative
                        ))
                    }
                }
            }
        }

        // --- Record low SOC ---
        if previous.count >= 3 {
            let prevMinSOC = previous.map(\.batterySOCMin).min() ?? 100
            if today.batterySOCMin < prevMinSOC && today.batterySOCMin < 30 {
                results.append(Insight(
                    icon: "exclamationmark.triangle.fill",
                    text: "Battery hit \(String(format: "%.0f", today.batterySOCMin))% — lowest ever recorded",
                    mood: .warning
                ))
            }
        }

        // --- Great charging day ---
        if today.batterySOCMax - today.batterySOCMin > 40 {
            results.append(Insight(
                icon: "bolt.fill",
                text: "Big charge swing today: \(Int(today.batterySOCMin))% → \(Int(today.batterySOCMax))% (+\(Int(today.batterySOCMax - today.batterySOCMin))%)",
                mood: .positive
            ))
        }

        // --- Weekly average comparison ---
        if stats.count >= 8 {
            let weekAvg = stats.dropLast().suffix(7).map(\.solarYield).reduce(0, +) / 7
            if weekAvg > 0 {
                let ratio = today.solarYield / weekAvg
                if ratio > 1.5 {
                    results.append(Insight(
                        icon: "star.fill",
                        text: "Today is \(Int((ratio - 1) * 100))% above your weekly average (\(fmtWh(weekAvg))/day)",
                        mood: .positive
                    ))
                } else if ratio < 0.5 && today.solarYield > 0 {
                    results.append(Insight(
                        icon: "cloud.fill",
                        text: "Today is \(Int((1 - ratio) * 100))% below your weekly average (\(fmtWh(weekAvg))/day)",
                        mood: .negative
                    ))
                }
            }
        }

        // --- DC-DC / alternator detection ---
        if todayEnergy.dcdcAh > 0.5 {
            results.append(Insight(
                icon: "engine.combustion.fill",
                text: "DC-DC charger contributed ~\(fmtAh(todayEnergy.dcdcAh)) today (engine/alternator)",
                mood: .neutral
            ))
        }

        // --- Record charging day ---
        if previous.count >= 2 {
            let prevMax = previous.compactMap(\.chargedAh).max() ?? 0
            let todayVal = today.chargedAh ?? 0
            if todayVal > prevMax && todayVal > 2 {
                results.append(Insight(
                    icon: "trophy.fill",
                    text: "Record charging day! \(fmtAh(todayVal)) into the battery — best ever",
                    mood: .positive
                ))
            }
        }

        // --- Record discharging day ---
        if previous.count >= 2 {
            let prevMax = previous.compactMap(\.dischargedAh).max() ?? 0
            let todayVal = today.dischargedAh ?? 0
            if todayVal > prevMax && todayVal > 2 {
                results.append(Insight(
                    icon: "exclamationmark.triangle",
                    text: "Highest discharge day: \(fmtAh(todayVal)) consumed — more than any previous day",
                    mood: .warning
                ))
            }
        }

        // --- Net Ah balance (from BMV, always accurate) ---
        let netAh = todayEnergy.consumedAhNet
        if abs(netAh) > 1 {
            if netAh < 0 {
                // consumed_ah decreased = net charging
                results.append(Insight(
                    icon: "plus.circle",
                    text: "Net +\(fmtAh(abs(netAh))) today — battery is gaining charge",
                    mood: .positive
                ))
            } else {
                results.append(Insight(
                    icon: "minus.circle",
                    text: "Net -\(fmtAh(netAh)) today — consuming more than charging",
                    mood: .negative
                ))
            }
        }

        // --- Battery nearly full ---
        if solar.power > 0 && battery.soc > 95 {
            results.append(Insight(
                icon: "checkmark.seal.fill",
                text: "Battery nearly full at \(String(format: "%.0f", battery.soc))% — panels producing \(Int(solar.power))W",
                mood: .positive
            ))
        }

        // --- DC-DC currently active ---
        if battery.power > 50 && solar.power > 0 && battery.power > solar.power * 1.2 {
            let dcdcPower = Int(battery.power - solar.power)
            results.append(Insight(
                icon: "car.fill",
                text: "Engine running? ~\(dcdcPower)W extra charge beyond solar — likely DC-DC",
                mood: .neutral
            ))
        }

        return results
    }

    private func fmtWh(_ wh: Double) -> String {
        if wh >= 1000 {
            return String(format: "%.2f kWh", wh / 1000)
        }
        return "\(Int(wh)) Wh"
    }

    private func fmtAh(_ ah: Double) -> String {
        if ah >= 100 {
            return String(format: "%.0f Ah", ah)
        }
        return String(format: "%.1f Ah", ah)
    }
}
