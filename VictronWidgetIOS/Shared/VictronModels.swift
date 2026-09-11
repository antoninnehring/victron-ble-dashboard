import Foundation

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
    var netPower: Double { battery.power }

    var yieldDiffPercent: Double? {
        guard dailyStats.count >= 2 else { return nil }
        let today = dailyStats[dailyStats.count - 1]
        let yesterday = dailyStats[dailyStats.count - 2]
        guard yesterday.solarYield > 0 else { return nil }
        return ((today.solarYield - yesterday.solarYield) / yesterday.solarYield) * 100
    }
}

// App group for sharing data between app and widget
let appGroupID = "group.com.victron.widget"

enum VictronAPI {
    static var baseURL: String {
        UserDefaults(suiteName: appGroupID)?.string(forKey: "apiBaseURL")
            ?? "http://localhost:3000"
    }

    static func setBaseURL(_ url: String) {
        UserDefaults(suiteName: appGroupID)?.set(url, forKey: "apiBaseURL")
    }

    static func fetch() async throws -> VictronData {
        let url = URL(string: "\(baseURL)/api/vrm")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(VictronData.self, from: data)
    }
}
