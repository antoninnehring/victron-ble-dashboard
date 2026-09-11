import Foundation

enum BleDataFile {
    static var path: String { DashboardFiles.bleData.path }
}

struct VictronData: Codable {
    let overview: Overview
    let dailyStats: [DailyStat]
    let timeseries: [TimePoint]
    let todayEnergy: TodayEnergy
    let lastUpdated: Double
    let deviceCount: Int
    let installationName: String?
    let history: HistoryMeta?
    let sameHour: SameHour?

    struct HistoryMeta: Codable {
        let source: String?
        let label: String?
        let not: String?
        let days: Int?
    }

    struct SameHour: Codable {
        let clock: String
        let todayWh: Double
        let yesterdayWh: Double?
        let yesterdayAt: String?
        let diffPercent: Double?
        let available: Bool
        let weekAvgWh: Double?
        let weekDiffPercent: Double?
        let weekDays: Int?
        let recordWh: Double?
        let isRecord: Bool?
    }

    struct TodayEnergy: Codable {
        let chargedAh: Double
        let dischargedAh: Double
        let dcdcAh: Double
        let solarYield: Double
        let consumedAhNet: Double
        let acInWh: Double?
        let acOutWh: Double?
    }

    struct Overview: Codable {
        let battery: Battery
        let solar: Solar
        let inverter: Inverter
        let dcdc: DcDc?
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
        let loadA: Double?
    }

    struct Inverter: Codable {
        let ac_power: Double
        let ac_in_power: Double?
        let ac_in_state: String?
        let state: String?
        let ac_voltage: Double?
        let ac_current: Double?
    }

    struct DcDc: Codable {
        let power: Double?
        let input_voltage: Double?
        let output_voltage: Double?
        let output_current: Double?
        let state: String?
    }

    struct DeviceInfo: Codable {
        let address: String
        let name: String
        let last_seen: Double
        let fields: [String]?
        let type: String?
        let typeLabel: String?
        let model: String?
        let summary: String?
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
        let yield: Double?
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

    var resolvedSameHour: SameHour? {
        sameHour ?? SameHour.compute(todayWh: solar.yieldToday)
    }

    var yieldDiffPercent: Double? {
        guard let sh = resolvedSameHour, sh.available, let diff = sh.diffPercent else { return nil }
        return diff
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

        // --- Record solar yield at this hour (never unfinished today vs a completed day) ---
        if let sh = resolvedSameHour, sh.isRecord == true, sh.todayWh > 0 {
            results.append(Insight(
                icon: "trophy.fill",
                text: "Record at this hour! Best yield by this time of day: \(fmtWh(sh.todayWh))",
                mood: .positive
            ))
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

        // --- Yield vs yesterday at this hour ---
        if let sh = resolvedSameHour, sh.available, let diff = sh.diffPercent, let yWh = sh.yesterdayWh {
            if diff > 20 {
                results.append(Insight(
                    icon: "arrow.up.right",
                    text: "Charged \(Int(diff))% more than yesterday at this hour (\(fmtWh(sh.todayWh)) vs \(fmtWh(yWh)))",
                    mood: .positive
                ))
            } else if diff < -20 {
                results.append(Insight(
                    icon: "arrow.down.right",
                    text: "Charged \(Int(abs(diff)))% less than yesterday at this hour (\(fmtWh(sh.todayWh)) vs \(fmtWh(yWh)))",
                    mood: .negative
                ))
            }
        }

        // --- Consecutive declining days (today only via same-hour; never unfinished vs full day) ---
        if previous.count >= 2 {
            var decliningDays = 0
            for i in stride(from: previous.count - 1, through: 1, by: -1) {
                if previous[i].solarYield < previous[i - 1].solarYield {
                    decliningDays += 1
                } else {
                    break
                }
            }
            if let sh = resolvedSameHour, sh.available, let yWh = sh.yesterdayWh, sh.todayWh < yWh {
                decliningDays += 1
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

        // --- Weekly average at this hour (completed days only; never punish an unfinished morning) ---
        if let sh = resolvedSameHour, let weekAvg = sh.weekAvgWh, weekAvg > 0, let weekDiff = sh.weekDiffPercent {
            if weekDiff > 50 {
                results.append(Insight(
                    icon: "star.fill",
                    text: "At this hour, today is \(Int(weekDiff))% above your weekly average (\(fmtWh(weekAvg)))",
                    mood: .positive
                ))
            } else if weekDiff < -50 && sh.todayWh > 0 {
                results.append(Insight(
                    icon: "cloud.fill",
                    text: "At this hour, today is \(Int(abs(weekDiff)))% below your weekly average (\(fmtWh(weekAvg)))",
                    mood: .negative
                ))
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

extension VictronData.SameHour {
    private static let maxSampleAgeMin = 60
    private static let maxIntegrationGapMin = 30
    private static let minCompareWh = 50.0
    private static let minWeekDays = 3

    private struct HistoryFile: Codable {
        let days: [String: HistoryDay]
    }

    private struct HistoryDay: Codable {
        let timeseries: [HistoryPoint]?
        let solar_yield_max: Double?
    }

    private struct HistoryPoint: Codable {
        let t: String
        let solar: Double?
        let yield: Double?
    }

    static func compute(todayWh: Double, now: Date = Date()) -> VictronData.SameHour? {
        let url = DashboardFiles.directory.appendingPathComponent("ble-history.json")
        guard let raw = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(HistoryFile.self, from: raw)
        else { return nil }

        let calendar = Calendar.current
        let todayIso = isoDate(now, calendar: calendar)
        let clock = String(format: "%02d:%02d", calendar.component(.hour, from: now), calendar.component(.minute, from: now))
        let yesterdayIso = isoDate(calendar.date(byAdding: .day, value: -1, to: now) ?? now, calendar: calendar)

        let yHit = yieldAtClock(file.days[yesterdayIso], clock: clock)
        let yesterdayWh = yHit?.wh
        let diff = yesterdayWh.flatMap { pctDiff(today: todayWh, other: $0) }

        let allPrior = file.days.keys.filter { $0 < todayIso }.sorted()
        let weekDates = Set(allPrior.suffix(7))
        var recordYields: [Double] = []
        var weekYields: [Double] = []
        for dayIso in allPrior {
            guard let hit = yieldAtClock(file.days[dayIso], clock: clock), hit.wh >= minCompareWh else { continue }
            recordYields.append(hit.wh)
            if weekDates.contains(dayIso) { weekYields.append(hit.wh) }
        }
        let weekAvg = weekYields.count >= minWeekDays ? weekYields.reduce(0, +) / Double(weekYields.count) : nil
        let weekDiff = weekAvg.flatMap { pctDiff(today: todayWh, other: $0) }
        let recordWh = recordYields.max()
        let isRecord = recordWh != nil && recordYields.count >= 2 && todayWh >= minCompareWh && todayWh > (recordWh ?? .infinity)

        return VictronData.SameHour(
            clock: clock,
            todayWh: (todayWh * 10).rounded() / 10,
            yesterdayWh: yesterdayWh.map { ($0 * 10).rounded() / 10 },
            yesterdayAt: yHit?.at,
            diffPercent: diff.map { ($0 * 10).rounded() / 10 },
            available: diff != nil,
            weekAvgWh: weekAvg.map { ($0 * 10).rounded() / 10 },
            weekDiffPercent: weekDiff.map { ($0 * 10).rounded() / 10 },
            weekDays: weekAvg != nil ? weekYields.count : 0,
            recordWh: recordWh.map { ($0 * 10).rounded() / 10 },
            isRecord: isRecord
        )
    }

    private static func isoDate(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func parseMinutes(_ t: String) -> Int? {
        let parts = t.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1].prefix(2)) else { return nil }
        return h * 60 + m
    }

    private static func pctDiff(today: Double, other: Double) -> Double? {
        guard other >= minCompareWh else { return nil }
        return ((today - other) / other) * 100
    }

    private static func yieldAtClock(_ day: HistoryDay?, clock: String) -> (wh: Double, at: String)? {
        guard let day, let clockM = parseMinutes(clock) else { return nil }
        let eligible = (day.timeseries ?? []).filter { point in
            guard let minutes = parseMinutes(point.t) else { return false }
            return minutes <= clockM
        }
        guard let last = eligible.last, let lastM = parseMinutes(last.t), clockM - lastM <= maxSampleAgeMin else { return nil }
        if let snapped = last.yield { return (snapped, last.t) }
        guard eligible.count >= 2 else { return nil }
        var total = 0.0
        var used = 0
        for i in 1..<eligible.count {
            guard let t0 = parseMinutes(eligible[i - 1].t), let t1 = parseMinutes(eligible[i].t) else { continue }
            let dt = t1 - t0
            if dt <= 0 || dt > maxIntegrationGapMin { continue }
            let w0 = eligible[i - 1].solar ?? 0
            let w1 = eligible[i].solar ?? 0
            total += (w0 + w1) / 2 * (Double(dt) / 60)
            used += 1
        }
        guard used > 0 else { return nil }
        return (total, last.t)
    }
}
