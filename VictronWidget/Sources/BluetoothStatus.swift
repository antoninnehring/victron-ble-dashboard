import SwiftUI
import Combine
import Foundation

@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
func IOBluetoothPreferenceGetControllerPowerState() -> Int32

/// Adapter power only — not “no advertisements”.
final class BluetoothStatus: ObservableObject {
    static let shared = BluetoothStatus()

    @Published private(set) var isPoweredOn = true

    var isPoweredOff: Bool { !isPoweredOn }

    private init() {
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        let nc = NotificationCenter.default
        nc.addObserver(forName: .init("IOBluetoothHostControllerPoweredOnNotification"), object: nil, queue: .main) { [weak self] _ in
            self?.isPoweredOn = true
        }
        nc.addObserver(forName: .init("IOBluetoothHostControllerPoweredOffNotification"), object: nil, queue: .main) { [weak self] _ in
            self?.isPoweredOn = false
        }
    }

    func refresh() {
        isPoweredOn = IOBluetoothPreferenceGetControllerPowerState() != 0
    }
}

struct BluetoothOffBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 12, weight: .medium))
            Text("Bluetooth is off — turn it on in Control Center to read Victron devices.")
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }
}
