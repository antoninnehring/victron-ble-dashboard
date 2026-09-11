# Victron dashboard (Next.js)

Web UI for the Mac BLE reader. Who it’s for and how to install: [root README](../README.md).

```bash
npm install
pip3 install -r ble-reader/requirements.txt
python3 ble-reader/reader.py   # leave running
npm run dev                    # http://localhost:3000
```

First visit opens a setup wizard. Keys go in `victron-config.json` (gitignored) — never commit that file.
