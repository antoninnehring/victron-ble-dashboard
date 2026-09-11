# Victron BLE dashboard

Local dashboard for Victron Instant Readout devices over Bluetooth. A Python reader decrypts BLE advertisements, writes JSON, and a Next.js app (plus optional macOS / iOS widgets) displays battery, solar, and a weather-based yield forecast.

Nothing here talks to Victron VRM. Your encryption keys stay on the machine that runs the reader.

## Requirements

- Node.js 20+
- Python 3.10+ with Bluetooth access
- VictronConnect, so you can copy Instant Readout keys
- macOS is the tested Bluetooth stack (CoreBluetooth via Bleak). Linux can work with BlueZ; Windows is untested.

## 1. Clone and install

```bash
git clone https://github.com/antoninnehring/victron-ble-dashboard.git
cd victron-ble-dashboard/victron-dashboard
npm install
pip3 install -r ble-reader/requirements.txt
```

## 2. Encryption keys (VictronConnect)

Instant Readout must be enabled on each device.

1. Open **VictronConnect**
2. Tap the device
3. **Settings → Product Info → Instant Readout**
4. Show / copy the encryption key

You also need the BLE address the reader will see. On macOS that is often a UUID, not the printed MAC.

```bash
python3 ble-reader/scan.py
```

Keep VictronConnect closed while scanning and while the reader runs; it can steal the adapter.

## 3. Configure env (no secrets in git)

```bash
cp .env.example .env.local
```

Edit `.env.local`:

```
VICTRON_DEVICES=<address>=<encryption_key>,<address>=<encryption_key>
BLE_INTERVAL=15
```

Optional:

- `VICTRON_BMS_ADDRESS` — shunt/BMS whose SOC/current/voltage should win
- `VICTRON_DEVICE_NAMES` — `ADDRESS=Friendly Name,...`
- `SITE_LAT` / `SITE_LON` — installation coordinates for the solar forecast
- `SITE_CAPACITY_W` — array nameplate in watts if you do not want peak-power inference

Do not commit `.env.local`.

## 4. Start the BLE reader

From `victron-dashboard/`:

```bash
python3 ble-reader/reader.py
```

Or `ble-reader/run.sh`. Leave it running. It writes `ble-data.json` and `ble-history.json` next to the Next.js app (those files are gitignored).

If Bluetooth dies or the Mac sleeps, the reader restarts the scanner instead of staying stuck on the last failure.

## 5. Start the dashboard

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000). The first visit shows a setup screen until `ble-data.json` exists.

### Solar forecast

The `/api/forecast` route uses [Open-Meteo](https://open-meteo.com/) (no API key). Set `SITE_LAT` and `SITE_LON` in `.env.local`, or click **Use my location** in the browser. The estimate uses sun angle, season, cloud/GHI, and yesterday’s actual yield when history exists.

## macOS menubar widget

`VictronWidget/` is a SwiftPM menubar app. It reads the same `ble-data.json`. Click the menu extra, or the Dock icon, for the larger panel.

```bash
cd VictronWidget
swift build -c release
```

Point it at the JSON file (first match wins):

1. `VICTRON_BLE_DATA` — absolute path
2. `victron-dashboard/ble-data.json` next to this repo
3. `~/victron-dashboard/ble-data.json`
4. the original local path, if that file still exists

Example:

```bash
VICTRON_BLE_DATA="$PWD/../victron-dashboard/ble-data.json" \
  .build/release/VictronWidget
```

## iOS widget (optional)

`VictronWidgetIOS/` is an Xcode / XcodeGen project. The iPhone app points at your dashboard URL (`http://<lan-ip>:3000`) and the widget extension reads `/api/vrm`. The Mac running the dashboard must be reachable on the LAN; Instant Readout keys never leave the reader host.

```bash
cd VictronWidgetIOS
xcodegen generate
open VictronWidget.xcodeproj
```

## Layout

```
victron-dashboard/          Next.js UI + API
  ble-reader/               Python BLE decoder
  .env.example              placeholders only
VictronWidget/              macOS menubar + dock panel
VictronWidgetIOS/           iOS app + Lock Screen / Home Screen widgets
```

## Troubleshooting

- **No devices in scan** — Instant Readout on, device powered, Bluetooth on, VictronConnect quit.
- **Decode errors / wrong key** — key must match that device’s Instant Readout secret; one key per address.
- **Dashboard says no BLE data** — reader must be running from `victron-dashboard/` so it writes `ble-data.json` there.
- **Stale / stuck readings** — reader restarts the scanner after empty cycles, adapter errors, and sleep. Restart `reader.py` if the adapter itself is wedged (`blueutil --power 0 && blueutil --power 1` on a Mac).
- **Forecast asks for location** — allow the browser, or set `SITE_LAT` / `SITE_LON`.
