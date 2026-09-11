# Victron BLE dashboard

Live numbers from your Victron solar and battery gear, over Bluetooth. No Cerbo/GX box. No VRM account.

You get a **macOS menu-bar panel** and a **local web dashboard**. It also guesses today’s and this week’s solar from the weather. History is only the days this Mac was actually scanning — not VictronConnect’s stored trends.

This is **not** a VictronConnect replacement. You still copy Instant Readout keys from VictronConnect once.

## What it looks like

The menu extra is a bolt + SOC. **Blue** when the battery is charging, **orange** when it’s discharging.

<p>
  <img src="docs/screenshots/menubar-charging.png" alt="Menu extra while charging: blue bolt and 44%" width="220">
  <img src="docs/screenshots/menubar-live.png" alt="Live menu extra while discharging: orange bolt and 44%" width="220">
</p>

Charging (blue) is the same extra, tinted — this Mac was discharging when the shots were taken, so there is no live charging capture. The orange one is live.

The 16:9 panel (Input / Battery / Output + forecast). Live, discharging:

![macOS panel](docs/screenshots/panel.png)

The web dashboard on this Mac (`localhost`):

![Web dashboard](docs/screenshots/dashboard.png)

## Who it’s for

People with an off-grid, van, boat, or cabin Victron kit (SmartSolar, BMV / SmartShunt, BMS, MultiPlus, and similar) who keep a **Mac nearby** that can hear the devices.

## Platform

- **macOS** — this is the app. Menubar widget + Python BLE reader.
- **Browser** — dashboard at `http://localhost:3000` on that Mac.
- **iOS (optional)** — Lock Screen / Home Screen widget that talks to the Mac on your LAN.
- **Not** a first-class Windows or Linux app.

Encryption keys stay on the Mac. Nothing is sent to Victron’s cloud.

## Setup

You need Node.js 20+, Python 3.10+, and VictronConnect (for the keys).

```bash
git clone https://github.com/antoninnehring/victron-ble-dashboard.git
cd victron-ble-dashboard/victron-dashboard
npm install
pip3 install -r ble-reader/requirements.txt
```

1. **Keys** — VictronConnect → device → Settings → Product Info → Instant Readout. Quit VictronConnect after that so it doesn’t steal Bluetooth.
2. **Reader** — `python3 ble-reader/reader.py` (leave it running).
3. **Dashboard** — `npm run dev`, then open [http://localhost:3000](http://localhost:3000). A setup wizard scans for devices and saves them to `victron-config.json` (gitignored).

That’s it. Re-open the wizard later with **Edit installation**, or **Edit** in the menu-bar panel.

### Menu bar (macOS)

```bash
cd VictronWidget
swift build -c release
.build/release/VictronWidget
```

It reads the same `ble-data.json` the reader writes.

### iPhone widget (optional)

```bash
cd VictronWidgetIOS
xcodegen generate
open VictronWidget.xcodeproj
```

Point the app at `http://<your-mac-lan-ip>:3000`. Keys never leave the Mac.

## If something’s wrong

- No devices in the scan — Instant Readout on, gear powered, Bluetooth on, VictronConnect quit.
- Dashboard says no BLE data — the reader must be running from `victron-dashboard/`.
- Forecast looks lost — set `SITE_LAT` / `SITE_LON` in `.env.local`, or let it use this Mac’s public IP.
