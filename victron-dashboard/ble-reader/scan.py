#!/usr/bin/env python3
"""Scan for nearby Victron BLE devices and print their addresses."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys

from bleak import BleakScanner
from victron_ble.devices import detect_device_type

from device_types import classify_raw

VICTRON_COMPANY_ID = 0x02E1


def classify(raw: bytes) -> tuple[str | None, str, str | None]:
    try:
        klass = detect_device_type(raw)
    except Exception:
        klass = None
    detected = klass.__name__ if klass is not None else None
    return classify_raw(raw, detected)


async def scan_devices(timeout: float = 8.0) -> list[dict]:
    found: dict[str, dict] = {}

    def detection_callback(device, advertisement_data):
        if not advertisement_data.manufacturer_data:
            return
        raw = advertisement_data.manufacturer_data.get(VICTRON_COMPANY_ID)
        if raw is None:
            return
        addr = (device.address or "").upper()
        if not addr or addr in found:
            return
        type_name, role, label = classify(bytes(raw))
        rssi = advertisement_data.rssi
        found[addr] = {
            "address": addr,
            "name": device.name or "Unknown",
            "rssi": rssi,
            "type": type_name,
            "typeLabel": label,
            "suggestedRole": role,
        }

    scanner = BleakScanner(detection_callback=detection_callback)
    await scanner.start()
    try:
        await asyncio.sleep(timeout)
    finally:
        await scanner.stop()

    devices = sorted(
        found.values(),
        key=lambda d: (d.get("rssi") is None, -(d.get("rssi") or -999), d["address"]),
    )
    return devices


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan for Victron Instant Readout devices")
    parser.add_argument("--timeout", type=float, default=30, help="Scan duration in seconds")
    parser.add_argument("--json", action="store_true", help="Print a JSON object to stdout")
    args = parser.parse_args()

    try:
        devices = asyncio.run(scan_devices(timeout=args.timeout))
    except Exception as exc:
        msg = str(exc)
        lowered = msg.lower()
        if "turned off" in lowered or "powered off" in lowered or "not powered" in lowered:
            msg = "Bluetooth is off — turn it on in Control Center to scan."
        if args.json:
            print(json.dumps({"ok": False, "devices": [], "error": msg}))
            return 1
        print(f"Scan failed: {msg}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps({"ok": True, "devices": devices, "error": None}))
        return 0

    print(f"Scanning for Victron devices ({args.timeout:g} seconds)...\n")
    if not devices:
        print("No Victron devices found. Make sure:")
        print("  - Your device is powered on and nearby")
        print("  - Bluetooth is enabled on your Mac")
        print("  - Instant Readout is enabled in VictronConnect")
        print("  - VictronConnect is quit (it can steal the adapter)")
        return 0

    print(f"Found {len(devices)} device(s). Use these addresses in the setup wizard")
    print("or in victron-config.json / .env.local:\n")
    for dev in devices:
        label = dev.get("typeLabel") or "Unknown type"
        rssi = dev.get("rssi")
        rssi_s = f"  rssi={rssi}dBm" if rssi is not None else ""
        print(f"  {dev['address']}  name={dev['name']}  type={label}{rssi_s}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
