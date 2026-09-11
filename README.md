# Victron BLE dashboard

Local dashboard for Victron Instant Readout devices over Bluetooth. A Python reader decrypts BLE advertisements, writes JSON, and a Next.js app (plus optional macOS / iOS widgets) displays battery, solar, and a weather-based yield forecast.

Nothing here talks to Victron VRM. Your encryption keys stay on the machine that runs the reader.

## History (what this app can and cannot read)

**Instant Readout is a live snapshot**, not VictronConnect stored trends and not VRM.

| Source | What you get |
| --- | --- |
| BLE advertisements | Live SOC, volts, amps, solar watts, **yield today**, remaining time, alarms. No multi-year log. |
| `ble-history.json` / dashboard charts | Days **this Mac was scanning**. Yield, peak power, SOC min/max, charge/discharge Ah, AC energy if a VE.Bus device reports it. |
| VictronConnect stored trends | On the phone/tablet that connected to the device. This app cannot read that. |
| VRM cloud | Needs a GX device + VRM login. This project does not call VRM (no tokens in `.env`). |

Solar chargers expose yield **today**, not last winter. BMV/BMS expose current consumed Ah, not a full history dump. If the Mac sleeps, those hours are missing from the local file.

## Instant Readout devices this reader parses

The BLE decoder maps every getter in `victron_ble` (`SolarCharger`, `BatteryMonitor`, `LynxSmartBMS`, `VEBus`, `Inverter`, `DcDcConverter`, `OrionXS`, `AcCharger`, `SmartLithium`, `SmartBatteryProtect`, `BatterySense`, `DcEnergyMeter`, `MultiRS`).

Scan/wizard labels match those types (plus Inverter RS advertisements, which Victron broadcasts but `victron_ble` does not decrypt).

**Still not visible over BLE Instant Readout** (need VE.Direct, a GX / VRM, or VictronConnect connected): Cerbo/Ekrano GX itself, EV Charging Station, VM-3P75CT (wired Instant Readout only), Peak Power Pack, most VE.Direct-only BlueSolar units unless they have a VE.Direct Bluetooth dongle, Inverter RS payload (advertised, not decoded).

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

## 2. First installation (wizard)

Start the dashboard, then open it in a browser. With no devices configured it opens a setup wizard:

1. **Installation name** — van / house / boat (shown in the dashboard and macOS panel)
2. **Discover devices** — 8s BLE scan; select which to include, or type an address
3. **Encryption keys** — VictronConnect → device → Settings → Product Info → Instant Readout
4. **Names + BMS** — name each device; pick the shunt/BMS whose SOC should win
5. **Save** — writes `victron-config.json` (gitignored, mode 0600)

Re-open later with **Edit installation** in the dashboard header, `?setup=1`, or **Edit** in the macOS panel. Saving does not wipe `ble-history.json`.

Keep VictronConnect closed while scanning and while the reader runs; it can steal the adapter.

### Existing `.env.local` setups

The reader still loads `VICTRON_DEVICES` / `VICTRON_DEVICE_NAMES` / `VICTRON_BMS_ADDRESS` if no JSON config exists. Open **Edit installation** (fields are pre-filled from env) and save once to migrate. After that, `victron-config.json` wins. Do not commit that file.

Manual fallback remains:

```bash
cp victron-config.example.json victron-config.json
# or
cp .env.example .env.local
```

Optional env still used for forecast coordinates:

- `SITE_LAT` / `SITE_LON`
- `SITE_CAPACITY_W`
- `BLE_INTERVAL`
- `VICTRON_INSTALLATION_NAME` (only if you have not saved JSON yet)

## 3. Start the BLE reader

From `victron-dashboard/`:

```bash
python3 ble-reader/reader.py
```

Or `ble-reader/run.sh`. Leave it running. It writes `ble-data.json` and `ble-history.json` next to the Next.js app (those files are gitignored).

If Bluetooth dies or the Mac sleeps, the reader restarts the scanner instead of staying stuck on the last failure.

## 4. Start the dashboard

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000). The first visit runs the installation wizard until devices are saved. After that, start the reader if `ble-data.json` is missing.

### Solar forecast

The `/api/forecast` route uses [Open-Meteo](https://open-meteo.com/) (no API key). It resolves location from `SITE_LAT` / `SITE_LON`, then `victron-config.json`, then this Mac’s public IP. No browser or widget location permission. The estimate uses sun angle, season, cloud/GHI, and yesterday’s actual yield when history exists.

## macOS menubar widget

`VictronWidget/` is a SwiftPM menubar app. It reads the same `ble-data.json`. Click the menu extra, or the Dock icon, for the larger panel. On first launch with no devices it opens a setup wizard window; **Edit** in the header re-opens it. The 16:9 telemetry panel is unchanged.

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
  victron-config.example.json
  .env.example              placeholders only
VictronWidget/              macOS menubar + dock panel + setup wizard
VictronWidgetIOS/           iOS app + Lock Screen / Home Screen widgets
```

## Troubleshooting

- **No devices in scan** — Instant Readout on, device powered, Bluetooth on, VictronConnect quit.
- **Decode errors / wrong key** — key must match that device’s Instant Readout secret; one key per address.
- **Dashboard says no BLE data** — reader must be running from `victron-dashboard/` so it writes `ble-data.json` there.
- **Stale / stuck readings** — reader restarts the scanner after empty cycles, adapter errors, and sleep. Restart `reader.py` if the adapter itself is wedged (`blueutil --power 0 && blueutil --power 1` on a Mac).
- **Forecast has no location** — set `SITE_LAT` / `SITE_LON` in `.env.local`, or let the dashboard cache the Mac’s public-IP location in `victron-config.json`.
