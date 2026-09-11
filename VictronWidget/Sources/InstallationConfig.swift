import Foundation
import AppKit

extension Notification.Name {
    static let openInstallationWizard = Notification.Name("openInstallationWizard")
    static let installationDidChange = Notification.Name("installationDidChange")
}

enum DashboardFiles {
    static var directory: URL {
        if let env = ProcessInfo.processInfo.environment["VICTRON_BLE_DATA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return URL(fileURLWithPath: env).deletingLastPathComponent()
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let candidates = [
            cwd.appendingPathComponent("victron-dashboard"),
            cwd,
            cwd.appendingPathComponent("../victron-dashboard"),
            home.appendingPathComponent("Fabrique/victron shit/victron-dashboard"),
            home.appendingPathComponent("victron-dashboard"),
        ]
        for url in candidates {
            let dir = url.standardizedFileURL
            let reader = dir.appendingPathComponent("ble-reader").path
            if fm.fileExists(atPath: reader) { return dir }
        }
        return home.appendingPathComponent("victron-dashboard")
    }

    static var bleData: URL {
        directory.appendingPathComponent("ble-data.json")
    }

    static var config: URL {
        if let env = ProcessInfo.processInfo.environment["VICTRON_CONFIG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return directory.appendingPathComponent("victron-config.json")
    }

    static var envLocal: URL {
        directory.appendingPathComponent(".env.local")
    }

    static var scanScript: URL {
        directory.appendingPathComponent("ble-reader/scan.py")
    }
}

struct VictronDeviceConfig: Codable, Identifiable, Equatable {
    var address: String
    var key: String
    var name: String
    var role: String

    var id: String { address.uppercased() }

    var roleLabel: String {
        switch role {
        case "bms": return "BMS / shunt"
        case "solar": return "Solar"
        case "monitor": return "Monitor"
        default: return "Other"
        }
    }
}

struct VictronInstallation: Codable, Equatable {
    var installationName: String
    var devices: [VictronDeviceConfig]
    var siteLat: Double? = nil
    var siteLon: Double? = nil
    var siteLabel: String? = nil
}

enum InstallationConfig {
    static var isConfigured: Bool {
        !(load()?.devices.isEmpty ?? true)
    }

    static func load() -> VictronInstallation? {
        if let json = loadJSON(), !json.devices.isEmpty {
            return json
        }
        if let env = loadEnv(), !env.devices.isEmpty {
            return env
        }
        return loadJSON() ?? loadEnv()
    }

    static func loadJSON() -> VictronInstallation? {
        let url = DashboardFiles.config
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(VictronInstallation.self, from: data)
        else { return nil }
        return normalized(decoded)
    }

    static func save(_ installation: VictronInstallation) throws {
        var cleaned = normalized(installation)
        if cleaned.siteLat == nil, let existing = loadJSON() {
            cleaned.siteLat = existing.siteLat
            cleaned.siteLon = existing.siteLon
            cleaned.siteLabel = existing.siteLabel
        }
        guard !cleaned.installationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SaveError.missingName
        }
        guard !cleaned.devices.isEmpty else {
            throw SaveError.missingDevices
        }
        for device in cleaned.devices {
            if !isValidAddress(device.address) { throw SaveError.badAddress }
            if !isValidKey(device.key) { throw SaveError.badKey }
            if device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SaveError.missingDeviceName
            }
        }
        let data = try JSONEncoder.pretty.encode(cleaned)
        let url = DashboardFiles.config
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: [.atomic])
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        try FileManager.default.setAttributes(attrs, ofItemAtPath: tmp.path)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        try? fm.setAttributes(attrs, ofItemAtPath: url.path)
        NotificationCenter.default.post(name: .installationDidChange, object: nil)
    }

    static func isValidAddress(_ address: String) -> Bool {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let mac = #"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#
        let uuid = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
        return a.range(of: mac, options: .regularExpression) != nil
            || a.range(of: uuid, options: .regularExpression) != nil
    }

    static func isValidKey(_ key: String) -> Bool {
        let k = normalizeKey(key)
        guard k.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil else { return false }
        return k.count % 2 == 0 && k.count >= 16 && k.count <= 64
    }

    static func normalizeKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    static func keyWarning(_ key: String) -> String? {
        let k = normalizeKey(key)
        if k.isEmpty { return "Enter the Instant Readout key" }
        if !isValidKey(k) { return "Must be 16–64 hex characters" }
        if k.count != 32 { return "Usually 32 hex characters" }
        return nil
    }

    enum SaveError: LocalizedError {
        case missingName, missingDevices, badAddress, badKey, missingDeviceName

        var errorDescription: String? {
            switch self {
            case .missingName: return "Installation name is required"
            case .missingDevices: return "Select at least one device"
            case .badAddress: return "Each device needs a MAC address or UUID"
            case .badKey: return "Each Instant Readout key must be 16–64 hex characters"
            case .missingDeviceName: return "Each device needs a name"
            }
        }
    }

    private static func normalized(_ installation: VictronInstallation) -> VictronInstallation {
        var seen = Set<String>()
        var devices: [VictronDeviceConfig] = []
        var bmsSeen = false
        for var device in installation.devices {
            device.address = device.address.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            device.key = normalizeKey(device.key)
            device.name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let role = ["bms", "solar", "monitor", "other"].contains(device.role) ? device.role : "other"
            device.role = role
            if device.address.isEmpty || device.key.isEmpty { continue }
            if seen.contains(device.address) { continue }
            if device.role == "bms" {
                if bmsSeen { device.role = "monitor" }
                else { bmsSeen = true }
            }
            if device.name.isEmpty {
                device.name = String(device.address.suffix(8)).replacingOccurrences(of: ":", with: "")
            }
            seen.insert(device.address)
            devices.append(device)
        }
        return VictronInstallation(
            installationName: installation.installationName.trimmingCharacters(in: .whitespacesAndNewlines),
            devices: devices,
            siteLat: installation.siteLat,
            siteLon: installation.siteLon,
            siteLabel: installation.siteLabel
        )
    }

    private static func loadEnv() -> VictronInstallation? {
        guard let text = try? String(contentsOf: DashboardFiles.envLocal, encoding: .utf8) else {
            return nil
        }
        var keys: [String: String] = [:]
        var names: [String: String] = [:]
        var bms = ""
        var installationName = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "VICTRON_DEVICES": keys = parseKV(val)
            case "VICTRON_DEVICE_NAMES": names = parseKV(val)
            case "VICTRON_BMS_ADDRESS": bms = val.uppercased()
            case "VICTRON_INSTALLATION_NAME": installationName = val
            default: break
            }
        }
        guard !keys.isEmpty else { return nil }
        let devices = keys.map { addr, key in
            VictronDeviceConfig(
                address: addr,
                key: normalizeKey(key),
                name: names[addr] ?? String(addr.suffix(8)).replacingOccurrences(of: ":", with: ""),
                role: addr == bms ? "bms" : "other"
            )
        }
        return VictronInstallation(installationName: installationName, devices: devices)
    }

    private static func parseKV(_ raw: String) -> [String: String] {
        var items: [String: String] = [:]
        for entry in raw.split(separator: ",") {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let addr = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces).uppercased()
            let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !addr.isEmpty, !val.isEmpty { items[addr] = val }
        }
        return items
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
