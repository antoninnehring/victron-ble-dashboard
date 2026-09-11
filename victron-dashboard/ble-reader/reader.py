#!/usr/bin/env python3
"""
Continuously reads Victron BLE advertisements and writes data to a JSON file
that the macOS menubar widget consumes.
"""

import asyncio
import json
import os
import sys
import time
from pathlib import Path
from datetime import datetime, date

from bleak import BleakScanner
from victron_ble.devices import detect_device_type

DATA_FILE = Path(__file__).parent.parent / "ble-data.json"
HISTORY_FILE = Path(__file__).parent.parent / "ble-history.json"

VICTRON_COMPANY_ID = 0x02E1
STALE_AFTER_S = 120
EMPTY_CYCLES_BEFORE_RESTART = 8
PERIODIC_RESTART_S = 15 * 60


def parse_kv_list(raw: str) -> dict:
    """Parse ADDRESS=value,ADDRESS=value lists (keys, names)."""
    items = {}
    for entry in (raw or "").split(","):
        entry = entry.strip()
        if "=" not in entry:
            continue
        addr, val = entry.split("=", 1)
        addr, val = addr.strip().upper(), val.strip()
        if addr and val:
            items[addr] = val
    return items


def parse_device_config():
    """Parse VICTRON_DEVICES env var: ADDRESS=KEY,ADDRESS=KEY,..."""
    devices = parse_kv_list(os.environ.get("VICTRON_DEVICES", ""))
    if not devices:
        print("ERROR: VICTRON_DEVICES not set in .env.local")
        print("Run 'python3 scan.py' first to find your device addresses,")
        print("then add them with encryption keys to .env.local")
        sys.exit(1)

    print(f"Configured {len(devices)} device(s):")
    for addr in devices:
        print(f"  {addr}")
    return devices


def load_history():
    """Load daily history from disk."""
    if HISTORY_FILE.exists():
        try:
            return json.loads(HISTORY_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {"days": {}}


def save_history(history):
    HISTORY_FILE.write_text(json.dumps(history, indent=2))


def update_daily_history(history, device_data, interval_s=15):
    """Track daily min/max/accumulations and intraday time series."""
    today = date.today().isoformat()
    now_hour = datetime.now().strftime("%H:%M")

    if today not in history["days"]:
        history["days"][today] = {
            "date": today,
            "solar_yield_max": 0,
            "battery_soc_min": 100,
            "battery_soc_max": 0,
            "solar_power_max": 0,
            "samples": 0,
            "charged_ah": 0,         # gross Ah into battery (from current integration)
            "discharged_ah": 0,      # gross Ah out of battery
            "dcdc_ah": 0,            # estimated DC-DC / alternator Ah
            "consumed_ah_start": None,  # BMV consumed_ah at start of day (device-tracked)
            "last_sample_ts": 0,
            "timeseries": [],
        }

    day = history["days"][today]
    day["samples"] += 1
    now_ts = time.time()

    solar_yield = device_data.get("solar", {}).get("yieldToday", 0)
    if solar_yield > day["solar_yield_max"]:
        day["solar_yield_max"] = solar_yield

    soc = device_data.get("battery", {}).get("soc", 0)
    if soc > 0:
        day["battery_soc_min"] = min(day["battery_soc_min"], soc)
        day["battery_soc_max"] = max(day["battery_soc_max"], soc)

    solar_power = device_data.get("solar", {}).get("power", 0)
    day["solar_power_max"] = max(day["solar_power_max"], solar_power)

    # Record BMV consumed_ah at start of day for accurate net reference
    consumed_ah_now = device_data.get("battery", {}).get("consumed_ah", 0)
    if day.get("consumed_ah_start") is None and consumed_ah_now != 0:
        day["consumed_ah_start"] = consumed_ah_now

    # Ensure accumulators exist (handles old history entries)
    day.setdefault("charged_ah", 0)
    day.setdefault("discharged_ah", 0)
    day.setdefault("dcdc_ah", 0)
    day.setdefault("last_sample_ts", 0)

    # Accumulate charge/discharge Ah from current — only if continuous
    # (skip if gap > 60s, meaning mac was sleeping)
    batt_current = device_data.get("battery", {}).get("current", 0)
    batt_power = device_data.get("battery", {}).get("power", 0)
    last_ts = day["last_sample_ts"]
    gap = now_ts - last_ts if last_ts > 0 else 999

    if gap < 60:
        hours = interval_s / 3600.0
        if batt_current > 0:
            day["charged_ah"] += batt_current * hours
        elif batt_current < 0:
            day["discharged_ah"] += abs(batt_current) * hours

        # DC-DC inference: charging current that solar can't explain
        # Compare battery charge power vs solar power
        if batt_power > 0 and batt_power > solar_power * 1.1:
            # Excess current beyond what solar provides
            voltage = device_data.get("battery", {}).get("voltage", 26)
            solar_current = solar_power / voltage if voltage > 0 else 0
            dcdc_current = max(0, batt_current - solar_current)
            day["dcdc_ah"] += dcdc_current * hours

    day["last_sample_ts"] = now_ts

    # Intraday time series: one point per ~5 minutes (20 samples at 15s)
    if "timeseries" not in day:
        day["timeseries"] = []
    ts = day["timeseries"]

    point = {
        "t": now_hour,
        "solar": solar_power,
        "current": batt_current,
        "soc": soc,
    }

    if not ts or day["samples"] % 20 == 0:
        ts.append(point)
    else:
        ts[-1] = point

    # Keep only last 30 days
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


def extract_device_data(parsed) -> dict:
    """Extract relevant fields from a parsed Victron BLE device."""
    data = {}

    # Solar charger
    if hasattr(parsed, "get_solar_power"):
        solar_power = parsed.get_solar_power()
        data["solar"] = {
            "power": solar_power if solar_power is not None else 0,
            "yieldToday": parsed.get_yield_today() if hasattr(parsed, "get_yield_today") else 0,
        }

    if hasattr(parsed, "get_battery_voltage"):
        data.setdefault("battery", {})
        data["battery"]["voltage"] = parsed.get_battery_voltage() or 0

    if hasattr(parsed, "get_battery_charging_current"):
        data.setdefault("battery", {})
        data["battery"]["current"] = parsed.get_battery_charging_current() or 0

    if hasattr(parsed, "get_charge_state"):
        charge_state = parsed.get_charge_state()
        data.setdefault("battery", {})
        data["battery"]["state"] = str(charge_state.name) if charge_state else "Unknown"

    # BMV / BMS: get_voltage(), get_current()
    if hasattr(parsed, "get_voltage"):
        data.setdefault("battery", {})
        data["battery"]["voltage"] = parsed.get_voltage() or 0

    if hasattr(parsed, "get_current"):
        data.setdefault("battery", {})
        data["battery"]["current"] = parsed.get_current() or 0

    if hasattr(parsed, "get_soc"):
        data.setdefault("battery", {})
        data["battery"]["soc"] = parsed.get_soc() or 0

    for temp_method in ("get_battery_temperature", "get_temperature"):
        if hasattr(parsed, temp_method):
            temp = getattr(parsed, temp_method)()
            if temp is not None:
                data.setdefault("battery", {})
                data["battery"]["temperature"] = temp
                break

    if hasattr(parsed, "get_consumed_ah"):
        data.setdefault("battery", {})
        data["battery"]["consumed_ah"] = parsed.get_consumed_ah() or 0

    if hasattr(parsed, "get_remaining_mins"):
        data.setdefault("battery", {})
        data["battery"]["remaining_mins"] = parsed.get_remaining_mins() or 0

    if hasattr(parsed, "get_ac_out_power"):
        data["inverter"] = {"ac_power": parsed.get_ac_out_power() or 0}

    if hasattr(parsed, "get_alarm"):
        alarm = parsed.get_alarm()
        data["alarm"] = str(alarm.name) if alarm else "None"

    if hasattr(parsed, "get_alarm_flags"):
        flags = parsed.get_alarm_flags()
        if flags and flags != 0:
            data["alarm_flags"] = flags

    return data


class VictronBLEReader:
    def __init__(self, device_keys: dict, bms_address: str = "", device_names: dict | None = None):
        self.device_keys = device_keys
        self.bms_address = (bms_address or "").strip().upper()
        self.configured_names = {k.upper(): v for k, v in (device_names or {}).items()}
        self.device_data: dict[str, dict] = {}
        self.device_names: dict[str, str] = {}
        self.last_update: dict[str, float] = {}
        self.history = load_history()

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
            if not extracted:
                return

            if addr not in self.device_data:
                self.device_data[addr] = {}
            self.device_data[addr].update(extracted)
            self.last_update[addr] = time.time()
        except Exception as exc:
            print(f"  Callback error: {exc}")

    def get_merged_data(self) -> dict:
        """Merge all device data into a single overview."""
        merged = {
            "battery": {
                "soc": 0, "voltage": 0, "current": 0, "power": 0,
                "state": "Unknown", "temperature": 0,
                "consumed_ah": 0, "remaining_mins": 0,
            },
            "solar": {"power": 0, "yieldToday": 0},
            "inverter": {"ac_power": 0},
            "alarm": "None",
            "devices": {},
        }

        for addr, data in self.device_data.items():
            name = self.device_names.get(addr, addr[-8:].replace(":", ""))
            merged["devices"][name] = {
                "address": addr,
                "name": name,
                "last_seen": self.last_update.get(addr, 0),
                "fields": list(data.keys()),
            }

            if "battery" in data and (not self.bms_address or addr != self.bms_address):
                for k, v in data["battery"].items():
                    if k == "soc":
                        continue
                    if isinstance(v, (int, float)) and v != 0:
                        merged["battery"][k] = v
                    elif isinstance(v, str) and v != "Unknown":
                        merged["battery"][k] = v

            if "solar" in data:
                merged["solar"]["power"] += data["solar"].get("power", 0)
                merged["solar"]["yieldToday"] = max(
                    merged["solar"]["yieldToday"],
                    data["solar"].get("yieldToday", 0),
                )

            if "inverter" in data:
                merged["inverter"]["ac_power"] += data["inverter"].get("ac_power", 0)

            if "alarm" in data and data["alarm"] not in ("None", "NO_ALARM"):
                merged["alarm"] = data["alarm"]

        # Optional BMS/shunt is authoritative for battery readings — apply last.
        # No != 0 guard: 0A current or 0V is a valid BMS reading.
        if self.bms_address and self.bms_address in self.device_data:
            bms_batt = self.device_data[self.bms_address].get("battery", {})
            for k, v in bms_batt.items():
                if isinstance(v, (int, float)):
                    merged["battery"][k] = v
                elif isinstance(v, str) and v != "Unknown":
                    merged["battery"][k] = v
            bms_v = bms_batt.get("voltage", 0)
            bms_i = bms_batt.get("current", 0)
            merged["battery"]["power"] = bms_v * bms_i
        else:
            merged["battery"]["power"] = (
                merged["battery"]["voltage"] * merged["battery"]["current"]
            )

        return merged

    def write_data(self):
        merged = self.get_merged_data()
        self.history = update_daily_history(self.history, merged)

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
                "samples": day["samples"],
            })

        # Get today's intraday timeseries and energy totals
        today_key = date.today().isoformat()
        timeseries = []
        today_energy = {"chargedAh": 0, "dischargedAh": 0, "dcdcAh": 0, "solarYield": 0, "consumedAhNet": 0}
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
            }

        output = {
            "overview": merged,
            "raw_devices": {self.device_names.get(addr, addr): data for addr, data in self.device_data.items()},
            "dailyStats": daily_stats,
            "timeseries": timeseries,
            "todayEnergy": today_energy,
            "lastUpdated": time.time() * 1000,
            "deviceCount": len(self.device_data),
        }

        tmp = DATA_FILE.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(output, indent=2))
        tmp.replace(DATA_FILE)

    async def _stop_scanner(self, scanner):
        if scanner is None:
            return
        try:
            await scanner.stop()
        except Exception:
            pass

    async def _start_scanner(self, reason: str, backoff: float = 0):
        ts = datetime.now().strftime("%H:%M:%S")
        if backoff > 0:
            print(f"[{ts}] Restarting BLE scanner ({reason}), waiting {backoff:.0f}s...")
            await asyncio.sleep(backoff)
        else:
            print(f"[{ts}] Starting BLE scanner ({reason})...")
        scanner = BleakScanner(detection_callback=self.detection_callback)
        await scanner.start()
        return scanner

    async def run(self):
        interval = int(os.environ.get("BLE_INTERVAL", "15"))
        print(f"\nStarting BLE reader (writing every {interval}s to {DATA_FILE})")
        print("Press Ctrl+C to stop\n")

        scanner = None
        empty_cycles = 0
        failures = 0
        last_restart = time.time()

        try:
            scanner = await self._start_scanner("initial")
            while True:
                try:
                    loop_start = time.time()
                    await asyncio.sleep(interval)
                    elapsed = time.time() - loop_start
                    ts = datetime.now().strftime("%H:%M:%S")
                    reason = None

                    if elapsed > interval * 3:
                        reason = f"wake/gap {elapsed:.0f}s"
                    elif not self.device_data or self.devices_are_stale():
                        empty_cycles += 1
                        if empty_cycles >= EMPTY_CYCLES_BEFORE_RESTART:
                            reason = f"{empty_cycles} empty/stale cycles"
                    else:
                        empty_cycles = 0

                    if reason is None and time.time() - last_restart >= PERIODIC_RESTART_S:
                        reason = "periodic"

                    if reason:
                        await self._stop_scanner(scanner)
                        backoff = min(30, 2 ** min(failures, 4)) if failures else 0
                        try:
                            scanner = await self._start_scanner(reason, backoff)
                            failures = 0
                            empty_cycles = 0
                            last_restart = time.time()
                        except Exception as exc:
                            failures += 1
                            scanner = None
                            print(f"[{ts}] Scanner start failed: {exc}")
                            continue

                    if self.device_data:
                        try:
                            self.write_data()
                        except OSError as exc:
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
                    print(f"[{ts}] BLE loop error: {exc}")
                    await self._stop_scanner(scanner)
                    try:
                        scanner = await self._start_scanner(
                            "after error", min(30, 2 ** min(failures, 4))
                        )
                        last_restart = time.time()
                    except Exception as start_exc:
                        scanner = None
                        print(f"[{ts}] Scanner restart failed: {start_exc}")
        except KeyboardInterrupt:
            print("\nStopping...")
        finally:
            await self._stop_scanner(scanner)


def main():
    env_file = Path(__file__).parent.parent / ".env.local"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, val = line.split("=", 1)
                os.environ.setdefault(key.strip(), val.strip())

    devices = parse_device_config()
    bms = os.environ.get("VICTRON_BMS_ADDRESS", "").strip()
    names = parse_kv_list(os.environ.get("VICTRON_DEVICE_NAMES", ""))
    reader = VictronBLEReader(devices, bms_address=bms, device_names=names)
    asyncio.run(reader.run())


if __name__ == "__main__":
    main()
