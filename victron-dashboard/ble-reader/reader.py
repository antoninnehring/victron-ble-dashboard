#!/usr/bin/env python3
"""
Continuously reads Victron BLE advertisements and writes data to a JSON file
that the macOS menubar widget consumes.
"""

from __future__ import annotations

import asyncio
import ctypes
import json
import os
import sys
import time
from pathlib import Path
from datetime import datetime, date

from bleak import BleakScanner
from victron_ble.devices import detect_device_type

from device_extract import (
    HISTORY_LABEL,
    HISTORY_NOT,
    extract_device_data,
    merge_overview,
)
from same_hour import compute_same_hour
from installation_config import (
    bms_address,
    config_mtime,
    device_keys,
    device_names,
    installation_name,
    load_dotenv_file,
    load_installation,
)

DATA_FILE = Path(__file__).parent.parent / "ble-data.json"
HISTORY_FILE = Path(__file__).parent.parent / "ble-history.json"

VICTRON_COMPANY_ID = 0x02E1
STALE_AFTER_S = 120
EMPTY_CYCLES_BEFORE_RESTART = 8
PERIODIC_RESTART_S = 15 * 60
SCANNER_OP_TIMEOUT = 20
BT_OFF_MSG = "Bluetooth is off — turn it on in Control Center to read Victron devices."


def macos_bluetooth_powered():
    """True/False if we can read the adapter, else None."""
    try:
        lib = ctypes.cdll.LoadLibrary(
            "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"
        )
        lib.IOBluetoothPreferenceGetControllerPowerState.restype = ctypes.c_int
        return lib.IOBluetoothPreferenceGetControllerPowerState() != 0
    except Exception:
        return None


def is_bluetooth_off_error(exc: BaseException) -> bool:
    msg = str(exc).lower()
    return "turned off" in msg or "powered off" in msg or "not powered" in msg


def describe_installation(inst: dict) -> None:
    name = installation_name(inst) or "(unnamed)"
    source = inst.get("_source") or "unknown"
    devices = inst.get("devices") or []
    print(f"Installation: {name}  [{source}, {len(devices)} device(s)]")
    for dev in devices:
        print(f"  {dev.get('name') or '?'}  {dev.get('address')}  role={dev.get('role')}")


def load_history():
    """Load daily history from disk."""
    if HISTORY_FILE.exists():
        try:
            return json.loads(HISTORY_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {"days": {}}


def save_history(history):
    try:
        HISTORY_FILE.write_text(json.dumps(history, indent=2))
    except OSError as exc:
        print(f"  History write failed: {exc}")


def update_daily_history(history, device_data, raw_devices=None, interval_s=15):
    """Track daily min/max/accumulations and intraday time series.

    This is a local log of days *this Mac* was scanning Instant Readout ads.
    It is not VictronConnect stored trends or VRM cloud history.
    """
    today = date.today().isoformat()
    now_hour = datetime.now().strftime("%H:%M")
    raw_devices = raw_devices or {}

    if today not in history["days"]:
        history["days"][today] = {
            "date": today,
            "solar_yield_max": 0,
            "battery_soc_min": 100,
            "battery_soc_max": 0,
            "solar_power_max": 0,
            "samples": 0,
            "charged_ah": 0,
            "discharged_ah": 0,
            "dcdc_ah": 0,
            "ac_in_wh": 0,
            "ac_out_wh": 0,
            "consumed_ah_start": None,
            "last_sample_ts": 0,
            "timeseries": [],
            "devices": {},
        }

    day = history["days"][today]
    day["samples"] += 1
    now_ts = time.time()

    solar_yield = device_data.get("solar", {}).get("yieldToday", 0) or 0
    if solar_yield > day["solar_yield_max"]:
        day["solar_yield_max"] = solar_yield

    soc = device_data.get("battery", {}).get("soc", 0) or 0
    if soc > 0:
        day["battery_soc_min"] = min(day["battery_soc_min"], soc)
        day["battery_soc_max"] = max(day["battery_soc_max"], soc)

    solar_power = device_data.get("solar", {}).get("power", 0) or 0
    day["solar_power_max"] = max(day.get("solar_power_max", 0), solar_power)

    consumed_ah_now = device_data.get("battery", {}).get("consumed_ah", 0) or 0
    if day.get("consumed_ah_start") is None and consumed_ah_now != 0:
        day["consumed_ah_start"] = consumed_ah_now

    day.setdefault("charged_ah", 0)
    day.setdefault("discharged_ah", 0)
    day.setdefault("dcdc_ah", 0)
    day.setdefault("ac_in_wh", 0)
    day.setdefault("ac_out_wh", 0)
    day.setdefault("last_sample_ts", 0)
    day.setdefault("devices", {})

    batt_current = device_data.get("battery", {}).get("current", 0) or 0
    batt_power = device_data.get("battery", {}).get("power", 0) or 0
    ac_out = device_data.get("inverter", {}).get("ac_power", 0) or 0
    ac_in = device_data.get("inverter", {}).get("ac_in_power", 0) or 0
    dcdc_power = device_data.get("dcdc", {}).get("power", 0) or 0
    last_ts = day["last_sample_ts"]
    gap = now_ts - last_ts if last_ts > 0 else 999

    if gap < 60:
        hours = interval_s / 3600.0
        if batt_current > 0:
            day["charged_ah"] += batt_current * hours
        elif batt_current < 0:
            day["discharged_ah"] += abs(batt_current) * hours

        voltage = device_data.get("battery", {}).get("voltage", 26) or 26
        if dcdc_power > 0 and voltage > 0:
            day["dcdc_ah"] += (dcdc_power / voltage) * hours
        elif batt_power > 0 and batt_power > solar_power * 1.1:
            solar_current = solar_power / voltage if voltage > 0 else 0
            dcdc_current = max(0, batt_current - solar_current)
            day["dcdc_ah"] += dcdc_current * hours

        if ac_out:
            day["ac_out_wh"] += abs(ac_out) * hours
        if ac_in:
            day["ac_in_wh"] += abs(ac_in) * hours

    day["last_sample_ts"] = now_ts

    for name, raw in raw_devices.items():
        slot = day["devices"].setdefault(
            name,
            {
                "type": raw.get("type"),
                "yield_today_max": 0,
                "power_max": 0,
                "soc_min": None,
                "soc_max": None,
                "ac_out_wh": 0,
            },
        )
        slot["type"] = raw.get("type") or slot.get("type")
        y = (raw.get("solar") or {}).get("yieldToday") or 0
        p = (raw.get("solar") or {}).get("power") or (raw.get("dcdc") or {}).get("power") or 0
        slot["yield_today_max"] = max(slot.get("yield_today_max") or 0, y)
        slot["power_max"] = max(slot.get("power_max") or 0, p)
        raw_soc = (raw.get("battery") or {}).get("soc")
        if raw_soc:
            slot["soc_min"] = raw_soc if slot.get("soc_min") is None else min(slot["soc_min"], raw_soc)
            slot["soc_max"] = raw_soc if slot.get("soc_max") is None else max(slot["soc_max"], raw_soc)
        if gap < 60:
            hours = interval_s / 3600.0
            ac = (raw.get("inverter") or {}).get("ac_power") or 0
            if ac:
                slot["ac_out_wh"] = (slot.get("ac_out_wh") or 0) + abs(ac) * hours

    if "timeseries" not in day:
        day["timeseries"] = []
    ts = day["timeseries"]

    point = {
        "t": now_hour,
        "solar": solar_power,
        "current": batt_current,
        "soc": soc,
        "acOut": ac_out,
        "dcdcW": dcdc_power,
        "yield": solar_yield,
    }

    if not ts or day["samples"] % 20 == 0:
        ts.append(point)
    else:
        ts[-1] = point

    dates = sorted(history["days"].keys())
    if len(dates) > 30:
        for old_date in dates[:-30]:
            del history["days"][old_date]

    save_history(history)
    return history


def decode_advertisement(raw_data: bytes, encryption_key: str):
    """Decode a Victron BLE advertisement (only type 0x10 instant readout)."""
    try:
        if len(raw_data) < 5 or raw_data[0] != 0x10:
            return None
        device_klass = detect_device_type(raw_data)
        if device_klass is None:
            return None
        device = device_klass(encryption_key)
        parsed = device.parse(raw_data)
        return parsed
    except Exception as e:
        if "Incorrect advertisement key" not in str(e):
            print(f"  Decode error: {e}")
        return None


# extract_device_data lives in device_extract.py (every Instant Readout getter).


class VictronBLEReader:
    def __init__(self, inst: dict | None = None):
        self.device_keys: dict[str, str] = {}
        self.bms_address = ""
        self.configured_names: dict[str, str] = {}
        self.installation_name = ""
        self.device_data: dict[str, dict] = {}
        self.device_names: dict[str, str] = {}
        self.last_update: dict[str, float] = {}
        self.heard_after_start = False
        self.history = load_history()
        self._config_mtime = config_mtime()
        self.apply_installation(inst if inst is not None else load_installation())

    def apply_installation(self, inst: dict) -> None:
        keys = device_keys(inst)
        names = device_names(inst)
        self.device_keys = keys
        self.bms_address = bms_address(inst)
        self.configured_names = {k.upper(): v for k, v in names.items()}
        self.installation_name = installation_name(inst)
        for addr in list(self.device_data):
            if addr not in self.device_keys:
                self.device_data.pop(addr, None)
                self.device_names.pop(addr, None)
                self.last_update.pop(addr, None)
        for addr, name in self.configured_names.items():
            self.device_names[addr] = name

    def maybe_reload_config(self) -> None:
        mtime = config_mtime()
        if mtime == self._config_mtime:
            return
        self._config_mtime = mtime
        inst = load_installation()
        if not inst.get("devices"):
            return
        self.apply_installation(inst)
        ts = datetime.now().strftime("%H:%M:%S")
        print(f"[{ts}] Reloaded installation config")
        describe_installation(inst)

    def newest_seen_age(self) -> float:
        if not self.last_update:
            return float("inf")
        return time.time() - max(self.last_update.values())

    def devices_are_stale(self) -> bool:
        return self.newest_seen_age() > STALE_AFTER_S

    def detection_callback(self, device, advertisement_data):
        try:
            if not advertisement_data.manufacturer_data:
                return

            raw = advertisement_data.manufacturer_data.get(VICTRON_COMPANY_ID)
            if raw is None:
                return

            addr = device.address.upper()
            key = self.device_keys.get(addr)
            if key is None:
                return

            if addr not in self.device_names:
                self.device_names[addr] = self.configured_names.get(
                    addr, device.name or addr[-8:]
                )

            parsed = decode_advertisement(raw, key)
            if parsed is None:
                return

            extracted = extract_device_data(parsed)
            if not extracted or not extracted.get("type"):
                return

            if addr not in self.device_data:
                self.device_data[addr] = {}
            self.device_data[addr].update(extracted)
            self.last_update[addr] = time.time()
            self.heard_after_start = True
        except Exception as exc:
            print(f"  Callback error: {exc}")

    def get_merged_data(self) -> dict:
        """Merge all device data into a single overview."""
        return merge_overview(
            self.device_data,
            self.device_names,
            self.last_update,
            self.bms_address,
        )

    def write_data(self, bluetooth_off=False):
        merged = self.get_merged_data()
        if not self.devices_are_stale():
            try:
                named = {
                    self.device_names.get(addr, addr): data
                    for addr, data in self.device_data.items()
                }
                interval = int(os.environ.get("BLE_INTERVAL", "15"))
                self.history = update_daily_history(
                    self.history, merged, named, interval_s=interval
                )
            except Exception as exc:
                print(f"  History update failed: {exc}")

        daily_stats = []
        for day_date in sorted(self.history["days"].keys()):
            day = self.history["days"][day_date]
            daily_stats.append({
                "date": day["date"],
                "solarYield": day["solar_yield_max"],
                "solarPeakPower": day["solar_power_max"],
                "batterySOCMin": day["battery_soc_min"],
                "batterySOCMax": day["battery_soc_max"],
                "chargedAh": day.get("charged_ah", 0),
                "dischargedAh": day.get("discharged_ah", 0),
                "dcdcAh": day.get("dcdc_ah", 0),
                "acInWh": day.get("ac_in_wh", 0),
                "acOutWh": day.get("ac_out_wh", 0),
                "samples": day["samples"],
            })

        # Get today's intraday timeseries and energy totals
        today_key = date.today().isoformat()
        timeseries = []
        today_energy = {
            "chargedAh": 0,
            "dischargedAh": 0,
            "dcdcAh": 0,
            "solarYield": 0,
            "consumedAhNet": 0,
            "acInWh": 0,
            "acOutWh": 0,
        }
        if today_key in self.history["days"]:
            today_data = self.history["days"][today_key]
            timeseries = today_data.get("timeseries", [])
            # Net consumed_ah change from BMV (always accurate, device-tracked)
            consumed_start = today_data.get("consumed_ah_start")
            consumed_now = merged.get("battery", {}).get("consumed_ah", 0)
            net_ah = 0
            if consumed_start is not None and consumed_now != 0:
                net_ah = consumed_now - consumed_start

            today_energy = {
                "chargedAh": today_data.get("charged_ah", 0),
                "dischargedAh": today_data.get("discharged_ah", 0),
                "dcdcAh": today_data.get("dcdc_ah", 0),
                "solarYield": today_data.get("solar_yield_max", 0),
                "consumedAhNet": net_ah,
                "acInWh": today_data.get("ac_in_wh", 0),
                "acOutWh": today_data.get("ac_out_wh", 0),
            }

        live_yield = merged.get("solar", {}).get("yieldToday") or today_energy.get("solarYield") or 0
        same_hour = compute_same_hour(
            self.history.get("days") or {},
            today_iso=today_key,
            clock=datetime.now().strftime("%H:%M"),
            today_wh=live_yield,
        )

        output = {
            "overview": merged,
            "raw_devices": {
                self.device_names.get(addr, addr): data
                for addr, data in self.device_data.items()
            },
            "dailyStats": daily_stats,
            "timeseries": timeseries,
            "todayEnergy": today_energy,
            "sameHour": same_hour,
            "lastUpdated": time.time() * 1000,
            "deviceCount": len(self.device_data),
            "bluetoothOff": bluetooth_off,
            "installationName": self.installation_name,
            "history": {
                "source": "local-ble",
                "label": HISTORY_LABEL,
                "not": HISTORY_NOT,
                "days": len(daily_stats),
            },
        }

        tmp = DATA_FILE.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(output, indent=2, allow_nan=False))
        tmp.replace(DATA_FILE)

    async def _stop_scanner(self, scanner):
        if scanner is None:
            return
        try:
            await asyncio.wait_for(scanner.stop(), timeout=SCANNER_OP_TIMEOUT)
        except Exception:
            pass

    def _backoff(self, failures: int) -> float:
        if failures <= 0:
            return 0
        return min(30, 2 ** min(failures, 4))

    async def _start_scanner(self, reason: str, backoff: float = 0):
        ts = datetime.now().strftime("%H:%M:%S")
        if backoff > 0:
            print(f"[{ts}] Restarting BLE scanner ({reason}), waiting {backoff:.0f}s...")
            await asyncio.sleep(backoff)
        else:
            print(f"[{ts}] Starting BLE scanner ({reason})...")
        try:
            scanner = BleakScanner(detection_callback=self.detection_callback)
            await asyncio.wait_for(scanner.start(), timeout=SCANNER_OP_TIMEOUT)
        except Exception as exc:
            await self._stop_scanner(locals().get("scanner"))
            raise
        self.heard_after_start = False
        return scanner

    async def run(self):
        interval = int(os.environ.get("BLE_INTERVAL", "15"))
        print(f"\nStarting BLE reader (writing every {interval}s to {DATA_FILE})")
        print("Press Ctrl+C to stop\n")

        scanner = None
        empty_cycles = 0
        failures = 0
        last_restart = 0.0

        try:
            while True:
                try:
                    ts = datetime.now().strftime("%H:%M:%S")
                    powered = macos_bluetooth_powered()
                    bluetooth_off = powered is False
                    if bluetooth_off:
                        print(f"[{ts}] {BT_OFF_MSG}")
                        await self._stop_scanner(scanner)
                        scanner = None
                        try:
                            self.write_data(bluetooth_off=True)
                        except Exception as exc:
                            print(f"[{ts}] Write failed (keeping last file): {exc}")
                        await asyncio.sleep(interval)
                        continue

                    reason = None
                    if scanner is None:
                        reason = "not running"
                    elif (
                        not self.heard_after_start
                        or not self.device_data
                        or self.devices_are_stale()
                    ):
                        empty_cycles += 1
                        if empty_cycles >= EMPTY_CYCLES_BEFORE_RESTART:
                            reason = f"{empty_cycles} empty/stale cycles"
                    else:
                        empty_cycles = 0

                    if (
                        reason is None
                        and last_restart
                        and time.time() - last_restart >= PERIODIC_RESTART_S
                    ):
                        reason = "periodic"

                    if reason:
                        await self._stop_scanner(scanner)
                        scanner = None
                        try:
                            scanner = await self._start_scanner(
                                reason, self._backoff(failures)
                            )
                            failures = 0
                            empty_cycles = 0
                            last_restart = time.time()
                        except Exception as exc:
                            failures += 1
                            if is_bluetooth_off_error(exc):
                                print(f"[{ts}] {BT_OFF_MSG}")
                                try:
                                    self.write_data(bluetooth_off=True)
                                except Exception:
                                    pass
                            else:
                                print(f"[{ts}] Scanner start failed: {exc}")
                            continue

                    self.maybe_reload_config()

                    loop_start = time.time()
                    await asyncio.sleep(interval)
                    elapsed = time.time() - loop_start
                    ts = datetime.now().strftime("%H:%M:%S")

                    if elapsed > interval * 3:
                        print(
                            f"[{ts}] Wake detected ({elapsed:.0f}s gap), "
                            "restarting BLE scanner..."
                        )
                        await self._stop_scanner(scanner)
                        scanner = None
                        try:
                            scanner = await self._start_scanner(
                                f"wake/gap {elapsed:.0f}s"
                            )
                            failures = 0
                            empty_cycles = 0
                            last_restart = time.time()
                        except Exception as exc:
                            failures += 1
                            if is_bluetooth_off_error(exc):
                                print(f"[{ts}] {BT_OFF_MSG}")
                            else:
                                print(f"[{ts}] Scanner start failed: {exc}")

                    if self.device_data:
                        try:
                            self.write_data(bluetooth_off=False)
                        except Exception as exc:
                            print(f"[{ts}] Write failed (keeping last file): {exc}")
                        merged = self.get_merged_data()
                        soc = merged["battery"]["soc"]
                        solar = merged["solar"]["power"]
                        batt_v = merged["battery"]["voltage"]
                        current = merged["battery"]["current"]
                        stale = " stale" if self.devices_are_stale() else ""
                        print(
                            f"[{ts}] SOC={soc}%  Solar={solar}W  {batt_v}V {current}A  "
                            f"Devices={len(self.device_data)}{stale}"
                        )
                    else:
                        print(f"[{ts}] Waiting for BLE data...")
                except asyncio.CancelledError:
                    raise
                except KeyboardInterrupt:
                    raise
                except Exception as exc:
                    failures += 1
                    ts = datetime.now().strftime("%H:%M:%S")
                    if is_bluetooth_off_error(exc):
                        print(f"[{ts}] {BT_OFF_MSG}")
                        try:
                            self.write_data(bluetooth_off=True)
                        except Exception:
                            pass
                    else:
                        print(f"[{ts}] BLE loop error: {exc}")
                    await self._stop_scanner(scanner)
                    scanner = None
                    await asyncio.sleep(self._backoff(failures))
        except KeyboardInterrupt:
            print("\nStopping...")
        finally:
            await self._stop_scanner(scanner)


def main():
    load_dotenv_file()
    inst = load_installation()
    if not inst.get("devices"):
        print("ERROR: no Victron devices configured")
        print("Open the dashboard setup wizard, or add VICTRON_DEVICES to .env.local")
        print("(copy victron-config.example.json to victron-config.json).")
        sys.exit(1)

    describe_installation(inst)
    reader = VictronBLEReader(inst)
    asyncio.run(reader.run())


if __name__ == "__main__":
    main()
