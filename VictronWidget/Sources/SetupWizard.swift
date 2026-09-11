import SwiftUI
import CoreBluetooth
import Combine
import AppKit

struct ScannedVictronDevice: Identifiable, Equatable {
    let address: String
    var advertisedName: String
    var rssi: Int?
    var typeLabel: String
    var suggestedRole: String

    var id: String { address }
}

private let typeMap: [UInt8: (label: String, role: String)] = [
    0x01: ("Solar charger / MPPT", "solar"),
    0x02: ("Battery monitor / SmartShunt", "bms"),
    0x03: ("Phoenix inverter", "other"),
    0x04: ("Orion-Tr Smart DC-DC", "other"),
    0x05: ("Smart Lithium", "bms"),
    0x06: ("Inverter RS", "other"),
    0x08: ("AC charger", "other"),
    0x09: ("Smart Battery Protect", "other"),
    0x0A: ("Lynx Smart BMS / VE.Bus BMS", "bms"),
    0x0B: ("Multi RS", "other"),
    0x0C: ("VE.Bus inverter / MultiPlus", "other"),
    0x0D: ("DC energy meter", "monitor"),
    0x0F: ("Orion XS DC-DC", "other"),
]
private let senseModelIds: Set<UInt16> = [0xA3A4, 0xA3A5]

final class VictronBLEScanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var devices: [ScannedVictronDevice] = []
    @Published var isScanning = false
    @Published var errorMessage: String?
    @Published var bluetoothOff = false

    private var central: CBCentralManager?
    private var found: [String: ScannedVictronDevice] = [:]
    private var timeoutWork: DispatchWorkItem?

    func start(timeout: TimeInterval = 8) {
        timeoutWork?.cancel()
        errorMessage = nil
        bluetoothOff = false
        found = [:]
        devices = []
        isScanning = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            startIfReady()
        }
        let work = DispatchWorkItem { [weak self] in
            self?.stop()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func stop() {
        timeoutWork?.cancel()
        timeoutWork = nil
        central?.stopScan()
        isScanning = false
        if devices.isEmpty, errorMessage == nil, !bluetoothOff {
            errorMessage = "No Victron devices found. Quit VictronConnect or enter an address manually."
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothOff = false
            startIfReady()
        case .poweredOff:
            bluetoothOff = true
            isScanning = false
            errorMessage = "Bluetooth is off — turn it on in Control Center to scan."
        case .unauthorized:
            isScanning = false
            errorMessage = "Bluetooth permission denied for this app."
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              mfg.count >= 2
        else { return }
        let company = UInt16(mfg[0]) | (UInt16(mfg[1]) << 8)
        guard company == 0x02E1 else { return }

        let address = peripheral.identifier.uuidString.uppercased()
        if found[address] != nil { return }

        let local = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? local ?? "Unknown"
        var typeLabel = ""
        var role = "other"
        if mfg.count >= 7 {
            let modelId = UInt16(mfg[4]) | (UInt16(mfg[5]) << 8)
            if senseModelIds.contains(modelId) {
                typeLabel = "Smart Battery Sense"
                role = "monitor"
            } else {
                let mode = mfg[6]
                if let mapped = typeMap[mode] {
                    typeLabel = mapped.label
                    role = mapped.role
                }
            }
        }
        let item = ScannedVictronDevice(
            address: address,
            advertisedName: name,
            rssi: RSSI.intValue,
            typeLabel: typeLabel,
            suggestedRole: role
        )
        found[address] = item
        devices = found.values.sorted { ($0.rssi ?? -999) > ($1.rssi ?? -999) }
    }

    private func startIfReady() {
        guard isScanning, let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
}

private enum WizardStep: Int, CaseIterable {
    case name, discover, keys, names
    var title: String {
        switch self {
        case .name: return "Installation"
        case .discover: return "Devices"
        case .keys: return "Keys"
        case .names: return "Names"
        }
    }
}

struct SetupWizardView: View {
    var onComplete: () -> Void
    var onCancel: (() -> Void)? = nil

    @StateObject private var scanner = VictronBLEScanner()
    @State private var step: WizardStep = .name
    @State private var installationName = ""
    @State private var devices: [VictronDeviceConfig] = []
    @State private var selected: Set<String> = []
    @State private var advertised: [String: String] = [:]
    @State private var typeLabels: [String: String] = [:]
    @State private var manualAddress = ""
    @State private var errorMessage: String?
    @State private var showKeys = false
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            progress
            Divider()
            Group {
                switch step {
                case .name: nameStep
                case .discover: discoverStep
                case .keys: keysStep
                case .names: namesStep
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
        .background(VisualEffectBackground())
        .onAppear { bootstrap() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(InstallationConfig.isConfigured ? "EDIT INSTALLATION" : "FIRST INSTALLATION")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.tertiary)
            Text("Victron BLE setup")
                .font(.hero(22))
            Text("Name the site, pick devices, paste Instant Readout keys. History is kept when you re-run this.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ForEach(WizardStep.allCases, id: \.rawValue) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Rectangle()
                        .fill(item.rawValue <= step.rawValue ? Color.orange : Color.primary.opacity(0.12))
                        .frame(height: 3)
                        .clipShape(Capsule())
                    Text("\(item.rawValue + 1). \(item.title)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(item == step ? Color.orange : .secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Installation name")
                .font(.system(size: 13, weight: .medium))
            TextField("Van, house, boat…", text: $installationName)
                .textFieldStyle(.roundedBorder)
            Text("Shown in the panel header and the dashboard.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var discoverStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Select every Victron device to include.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(scanner.isScanning ? "Scanning…" : "Scan again") {
                    scanner.start()
                }
                .disabled(scanner.isScanning)
            }
            if scanner.bluetoothOff {
                BluetoothOffBanner()
            }
            if let err = scanner.errorMessage ?? errorMessage {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(listedDevices, id: \.address) { item in
                        Button {
                            toggle(item.address)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selected.contains(item.address) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selected.contains(item.address) ? Color.orange : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .foregroundStyle(.primary)
                                    Text(item.address)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    if !item.type.isEmpty {
                                        Text(item.type)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if let rssi = item.rssi {
                                    Text("\(rssi) dBm")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selected.contains(item.address) ? Color.orange.opacity(0.12) : Color.primary.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                TextField("Manual address (MAC or UUID)", text: $manualAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { addManual() }
                Button("Add", action: addManual)
            }
        }
        .onAppear {
            if scanner.devices.isEmpty, !scanner.isScanning {
                scanner.start()
            }
        }
        .onChange(of: scanner.devices) { _, devices in
            mergeScanned(devices)
        }
    }

    private var keysStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VictronConnect → device → Settings → Product Info → Instant Readout.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button(showKeys ? "Hide keys" : "Show keys") { showKeys.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(selectedDevices) { device in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(device.name.isEmpty ? (advertised[device.address] ?? "Device") : device.name)
                                .font(.system(size: 13, weight: .medium))
                            Text(device.address)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            SecureOrPlainField(text: bindingKey(device.address), show: showKeys)
                            if let warn = InstallationConfig.keyWarning(device.key) {
                                Text(warn)
                                    .font(.system(size: 11))
                                    .foregroundStyle(warn.contains("Usually") ? Color.orange : Color.orange)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                }
            }
        }
    }

    private var namesStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Give each device a name. Pick the BMS / shunt that should win for SOC.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(selectedDevices) { device in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(device.address)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            TextField("Device name", text: bindingName(device.address))
                                .textFieldStyle(.roundedBorder)
                            HStack(spacing: 6) {
                                ForEach(["bms", "solar", "monitor", "other"], id: \.self) { role in
                                    Button(role == "bms" ? "BMS / shunt" : role.capitalized) {
                                        setRole(device.address, role)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule().fill(device.role == role ? Color.orange.opacity(0.22) : Color.primary.opacity(0.06))
                                    )
                                }
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(step == .name ? "Cancel" : "Back") {
                if step == .name {
                    onCancel?()
                } else if let prev = WizardStep(rawValue: step.rawValue - 1) {
                    step = prev
                    errorMessage = nil
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(step == .name && onCancel == nil)
            Spacer()
            Button(step == .names ? "Save installation" : "Continue") {
                advance()
            }
            .buttonStyle(.plain)
            .foregroundStyle(canAdvance ? Color.orange : .secondary)
            .disabled(!canAdvance)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var selectedDevices: [VictronDeviceConfig] {
        devices.filter { selected.contains($0.address) }
    }

    private var listedDevices: [(address: String, name: String, type: String, rssi: Int?)] {
        var rows: [(address: String, name: String, type: String, rssi: Int?)] = scanner.devices.map {
            ($0.address, $0.advertisedName, $0.typeLabel, $0.rssi)
        }
        let seen = Set(rows.map(\.address))
        for device in devices where selected.contains(device.address) && !seen.contains(device.address) {
            rows.append((device.address, advertised[device.address] ?? device.name, typeLabels[device.address] ?? "", nil))
        }
        return rows
    }

    private var canAdvance: Bool {
        switch step {
        case .name:
            return !installationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .discover:
            return !selected.isEmpty
        case .keys:
            return selectedDevices.allSatisfy { InstallationConfig.isValidKey($0.key) }
        case .names:
            return selectedDevices.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    private func bootstrap() {
        guard !didLoad else { return }
        didLoad = true
        if let existing = InstallationConfig.load() {
            installationName = existing.installationName
            devices = existing.devices
            selected = Set(existing.devices.map(\.address))
            for device in existing.devices {
                advertised[device.address] = device.name
            }
        }
    }

    private func mergeScanned(_ scanned: [ScannedVictronDevice]) {
        for item in scanned {
            advertised[item.address] = item.advertisedName
            typeLabels[item.address] = item.typeLabel
            if let idx = devices.firstIndex(where: { $0.address == item.address }) {
                if devices[idx].name.isEmpty { devices[idx].name = item.advertisedName }
            } else {
                devices.append(
                    VictronDeviceConfig(
                        address: item.address,
                        key: "",
                        name: item.advertisedName,
                        role: item.suggestedRole
                    )
                )
            }
        }
        if selected.isEmpty, !InstallationConfig.isConfigured {
            selected = Set(scanned.map(\.address))
        }
    }

    private func toggle(_ address: String) {
        if selected.contains(address) { selected.remove(address) }
        else { selected.insert(address) }
    }

    private func addManual() {
        let address = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard InstallationConfig.isValidAddress(address) else {
            errorMessage = "Enter a MAC (AA:BB:CC:DD:EE:FF) or the UUID from a scan."
            return
        }
        errorMessage = nil
        if !devices.contains(where: { $0.address == address }) {
            devices.append(VictronDeviceConfig(address: address, key: "", name: "", role: "other"))
        }
        selected.insert(address)
        advertised[address] = advertised[address] ?? "Manual"
        manualAddress = ""
    }

    private func bindingKey(_ address: String) -> Binding<String> {
        Binding(
            get: { devices.first(where: { $0.address == address })?.key ?? "" },
            set: { value in
                if let idx = devices.firstIndex(where: { $0.address == address }) {
                    devices[idx].key = value
                }
            }
        )
    }

    private func bindingName(_ address: String) -> Binding<String> {
        Binding(
            get: { devices.first(where: { $0.address == address })?.name ?? "" },
            set: { value in
                if let idx = devices.firstIndex(where: { $0.address == address }) {
                    devices[idx].name = value
                }
            }
        )
    }

    private func setRole(_ address: String, _ role: String) {
        for idx in devices.indices {
            guard selected.contains(devices[idx].address) else { continue }
            if devices[idx].address == address {
                devices[idx].role = role
            } else if role == "bms", devices[idx].role == "bms" {
                devices[idx].role = "monitor"
            }
        }
    }

    private func advance() {
        errorMessage = nil
        if step == .names {
            let payload = VictronInstallation(
                installationName: installationName,
                devices: selectedDevices
            )
            do {
                try InstallationConfig.save(payload)
                onComplete()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        if let next = WizardStep(rawValue: step.rawValue + 1) {
            step = next
        }
    }
}

private struct SecureOrPlainField: View {
    @Binding var text: String
    var show: Bool

    var body: some View {
        if show {
            TextField("32-character hex key", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        } else {
            SecureField("32-character hex key", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}
