#!/usr/bin/env python3
"""Scan for nearby Victron BLE devices and print their addresses."""

import asyncio
from bleak import BleakScanner

VICTRON_COMPANY_ID = 0x02E1  # Victron Energy manufacturer ID


async def scan():
    print("Scanning for Victron devices (30 seconds)...\n")

    found = {}

    def detection_callback(device, advertisement_data):
        if advertisement_data.manufacturer_data:
            for company_id in advertisement_data.manufacturer_data:
                if company_id == VICTRON_COMPANY_ID:
                    if device.address not in found:
                        found[device.address] = device.name or "Unknown"
                        print(f"  Found: {device.address}  name={device.name or 'Unknown'}  rssi={advertisement_data.rssi}dBm")

    scanner = BleakScanner(detection_callback=detection_callback)
    await scanner.start()
    await asyncio.sleep(30)
    await scanner.stop()

    if not found:
        print("No Victron devices found. Make sure:")
        print("  - Your device is powered on and nearby")
        print("  - Bluetooth is enabled on your Mac")
        print("  - Instant Readout is enabled in VictronConnect")
    else:
        print(f"\n Found {len(found)} device(s). Use these addresses in .env.local:")
        print("  VICTRON_DEVICES=ADDRESS=YOUR_ENCRYPTION_KEY")
        for addr, name in found.items():
            print(f"  # {name}")
            print(f"  # {addr}=<encryption_key_from_victronconnect>")


if __name__ == "__main__":
    asyncio.run(scan())
