# Victron dashboard (Next.js)

Web UI and API for the local BLE reader. Setup lives in the [root README](../README.md).

```bash
cp .env.example .env.local   # add Instant Readout keys, never commit this file
pip3 install -r ble-reader/requirements.txt
python3 ble-reader/reader.py   # leave running
npm install
npm run dev                    # http://localhost:3000
```

`SITE_LAT` / `SITE_LON` in `.env.local` pin the solar forecast. If unset, the server uses the Mac’s public IP (and caches it in `victron-config.json`).
