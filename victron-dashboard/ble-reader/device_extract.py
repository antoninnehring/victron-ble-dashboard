#!/usr/bin/env python3
"""Map every victron_ble DeviceData getter into JSON-safe device records."""

from __future__ import annotations

import math
from enum import Enum
from typing import Any, Optional

from device_types import (
    BATTERY_AUTHORITY_TYPES,
    DCDC_TYPES,
    INVERTER_TYPES,
    SOLAR_TYPES,
    TYPE_LABELS,
    type_from_data_class,
)

HISTORY_LABEL = "Days this Mac observed while scanning"
HISTORY_NOT = "VictronConnect stored trends or VRM cloud history"


def _jsonable(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, Enum):
        return value.name
    if isinstance(value, float):
        if math.isnan(value):
            return None
        if math.isinf(value):
            return "<2.61" if value < 0 else ">3.85"
        return value
    if isinstance(value, (int, str, bool)):
        return value
    if isinstance(value, (list, tuple)):
        return [_jsonable(v) for v in value]
    if isinstance(value, dict):
        return {str(k): _jsonable(v) for k, v in value.items()}
    return str(value)


def _call(parsed: Any, name: str, default: Any = None) -> Any:
    method = getattr(parsed, name, None)
    if not callable(method):
        return default
    try:
        return method()
    except Exception:
        return default


def all_getters(parsed: Any) -> dict[str, Any]:
    """Every public get_* on the DeviceData instance, JSON-safe."""
    out: dict[str, Any] = {}
    for name in dir(parsed):
        if not name.startswith("get_") or name in ("get_model_id",):
            continue
        method = getattr(parsed, name, None)
        if not callable(method):
            continue
        try:
            out[name[4:]] = _jsonable(method())
        except Exception:
            continue
    return out


def _enum_name(value: Any) -> Optional[str]:
    if value is None:
        return None
    name = getattr(value, "name", None)
    return str(name) if name else str(value)


def _num(value: Any) -> Optional[float]:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
            return None
        return float(value)
    return None


def _nonzero_alarm(name: Optional[str]) -> Optional[str]:
    if not name:
        return None
    if name in ("NO_ALARM", "NO_ERROR", "NO_REASON", "None", "UNKNOWN"):
        return None
    return name


def yield_today_wh(parsed: Any, type_name: str) -> Optional[float]:
    """Normalize yield-today to watt-hours (Multi RS reports kWh)."""
    raw = _num(_call(parsed, "get_yield_today"))
    if raw is None:
        return None
    if type_name == "MultiRS":
        return raw * 1000.0
    return raw


def extract_device_data(parsed: Any) -> dict[str, Any]:
    """Full Instant Readout snapshot plus overview buckets for the merged UI."""
    type_name = type_from_data_class(parsed)
    getters = all_getters(parsed)
    model = _call(parsed, "get_model_name") or getters.get("model_name") or ""
    data: dict[str, Any] = {
        "type": type_name,
        "typeLabel": TYPE_LABELS.get(type_name, type_name),
        "model": model,
        "fields": getters,
    }

    charge_state = _enum_name(_call(parsed, "get_charge_state")) or _enum_name(
        _call(parsed, "get_device_state")
    )
    charger_error = _enum_name(
        _call(parsed, "get_charger_error") or _call(parsed, "get_error_code")
    )
    if charger_error:
        data["chargerError"] = charger_error

    alarm = _enum_name(_call(parsed, "get_alarm")) or _enum_name(
        _call(parsed, "get_alarm_reason")
    )
    if _nonzero_alarm(alarm):
        data["alarm"] = alarm
    elif alarm:
        data["alarm"] = alarm

    warning = _enum_name(_call(parsed, "get_warning_reason"))
    if _nonzero_alarm(warning):
        data["warning"] = warning

    off_reason = _enum_name(_call(parsed, "get_off_reason"))
    if _nonzero_alarm(off_reason):
        data["offReason"] = off_reason

    flags = _call(parsed, "get_alarm_flags")
    if flags not in (None, 0):
        data["alarm_flags"] = flags
    err_flags = _call(parsed, "get_error_flags")
    if err_flags not in (None, 0):
        data["error_flags"] = err_flags
    error = _call(parsed, "get_error")
    if error not in (None, 0):
        data["vebusError"] = error

    solar_power = _num(_call(parsed, "get_solar_power"))
    if solar_power is None:
        solar_power = _num(_call(parsed, "get_pv_power"))
    yield_wh = yield_today_wh(parsed, type_name)
    load_a = _num(_call(parsed, "get_external_device_load"))
    if solar_power is not None or yield_wh is not None:
        solar: dict[str, Any] = {
            "power": solar_power or 0.0,
            "yieldToday": yield_wh or 0.0,
        }
        if load_a is not None:
            solar["loadA"] = load_a
        data["solar"] = solar

    batt: dict[str, Any] = {}
    voltage = _num(_call(parsed, "get_voltage"))
    if voltage is None:
        voltage = _num(_call(parsed, "get_battery_voltage"))
    current = _num(_call(parsed, "get_current"))
    if current is None:
        current = _num(_call(parsed, "get_battery_current"))
    if current is None:
        current = _num(_call(parsed, "get_battery_charging_current"))
    soc = _num(_call(parsed, "get_soc"))
    temp = _num(_call(parsed, "get_battery_temperature"))
    if temp is None:
        temp = _num(_call(parsed, "get_temperature"))
    consumed = _num(_call(parsed, "get_consumed_ah"))
    remaining = _num(_call(parsed, "get_remaining_mins"))
    starter = _num(_call(parsed, "get_starter_voltage"))
    midpoint = _num(_call(parsed, "get_midpoint_voltage"))
    aux_mode = _enum_name(_call(parsed, "get_aux_mode"))

    if voltage is not None:
        batt["voltage"] = voltage
    if current is not None:
        batt["current"] = current
    if soc is not None:
        batt["soc"] = soc
    if temp is not None:
        batt["temperature"] = temp
    if consumed is not None:
        batt["consumed_ah"] = consumed
    if remaining is not None:
        batt["remaining_mins"] = remaining
    if charge_state and type_name in ("SolarCharger", "AcCharger", "DcDcConverter", "OrionXS", "VEBus", "MultiRS", "Inverter"):
        batt["state"] = charge_state
    if starter is not None:
        batt["starter_voltage"] = starter
    if midpoint is not None:
        batt["midpoint_voltage"] = midpoint
    if aux_mode:
        batt["aux_mode"] = aux_mode
    if batt:
        data["battery"] = batt

    inv: dict[str, Any] = {}
    ac_out = _num(_call(parsed, "get_ac_out_power"))
    if ac_out is None:
        ac_out = _num(_call(parsed, "get_active_ac_out_power"))
    ac_in = _num(_call(parsed, "get_ac_in_power"))
    if ac_in is None:
        ac_in = _num(_call(parsed, "get_active_ac_in_power"))
    ac_va = _num(_call(parsed, "get_ac_apparent_power"))
    ac_v = _num(_call(parsed, "get_ac_voltage"))
    ac_i = _num(_call(parsed, "get_ac_current")) if type_name in INVERTER_TYPES else None
    ac_in_state = _enum_name(_call(parsed, "get_ac_in_state")) or _enum_name(
        _call(parsed, "get_active_ac_in")
    )
    if type_name not in INVERTER_TYPES:
        ac_out = None
        ac_in = None
        ac_va = None
        ac_v = None
        ac_i = None
        ac_in_state = None
    if ac_out is not None:
        inv["ac_power"] = ac_out
    elif ac_va is not None:
        inv["ac_power"] = ac_va
        inv["ac_apparent_power"] = ac_va
    if ac_in is not None:
        inv["ac_in_power"] = ac_in
    if ac_in_state:
        inv["ac_in_state"] = ac_in_state
    if ac_v is not None:
        inv["ac_voltage"] = ac_v
    if ac_i is not None:
        inv["ac_current"] = ac_i
    if charge_state and type_name in INVERTER_TYPES:
        inv["state"] = charge_state
    if inv:
        data["inverter"] = inv

    if type_name in DCDC_TYPES:
        in_v = _num(_call(parsed, "get_input_voltage"))
        in_i = _num(_call(parsed, "get_input_current"))
        out_v = _num(_call(parsed, "get_output_voltage"))
        out_i = _num(_call(parsed, "get_output_current"))
        dcdc: dict[str, Any] = {}
        if in_v is not None:
            dcdc["input_voltage"] = in_v
        if in_i is not None:
            dcdc["input_current"] = in_i
        if out_v is not None:
            dcdc["output_voltage"] = out_v
        if out_i is not None:
            dcdc["output_current"] = out_i
        if out_v is not None and out_i is not None:
            dcdc["power"] = out_v * out_i
        if charge_state:
            dcdc["state"] = charge_state
        if charger_error:
            dcdc["error"] = charger_error
        if off_reason:
            dcdc["off_reason"] = off_reason
        data["dcdc"] = dcdc

    if type_name == "AcCharger":
        charger: dict[str, Any] = {}
        for idx in (1, 2, 3):
            v = _num(_call(parsed, "get_output_voltage%d" % idx))
            i = _num(_call(parsed, "get_output_current%d" % idx))
            if v is not None:
                charger["voltage%d" % idx] = v
            if i is not None:
                charger["current%d" % idx] = i
        ac_in_i = _num(_call(parsed, "get_ac_current"))
        if ac_in_i is not None:
            charger["ac_current"] = ac_in_i
        if temp is not None:
            charger["temperature"] = temp
        if charge_state:
            charger["state"] = charge_state
        if charger_error:
            charger["error"] = charger_error
        data["charger"] = charger

    if type_name == "SmartLithium":
        cells = _call(parsed, "get_cell_voltages") or []
        lithium: dict[str, Any] = {
            "cell_voltages": _jsonable(cells),
            "balancer": _enum_name(_call(parsed, "get_balancer_status")),
            "bms_flags": _call(parsed, "get_bms_flags"),
            "error_flags": _call(parsed, "get_error_flags"),
        }
        if voltage is not None:
            lithium["voltage"] = voltage
        if temp is not None:
            lithium["temperature"] = temp
        data["lithium"] = lithium

    if type_name == "SmartBatteryProtect":
        protect: dict[str, Any] = {
            "device_state": charge_state,
            "output_state": _enum_name(_call(parsed, "get_output_state")),
            "input_voltage": _num(_call(parsed, "get_input_voltage")),
            "output_voltage": _num(_call(parsed, "get_output_voltage")),
            "alarm": alarm,
            "warning": warning,
            "error": charger_error,
            "off_reason": off_reason,
        }
        data["protect"] = {k: v for k, v in protect.items() if v is not None}

    if type_name == "DcEnergyMeter":
        meter: dict[str, Any] = {
            "meter_type": _enum_name(_call(parsed, "get_meter_type")),
            "voltage": voltage,
            "current": current,
            "aux_mode": aux_mode,
        }
        if starter is not None:
            meter["starter_voltage"] = starter
        if temp is not None:
            meter["temperature"] = temp
        data["meter"] = {k: v for k, v in meter.items() if v is not None}

    if type_name == "BatterySense":
        sense = {}
        if voltage is not None:
            sense["voltage"] = voltage
        if temp is not None:
            sense["temperature"] = temp
        data["sense"] = sense

    data["summary"] = _summary(data)
    return data


def _fmt(value: Optional[float], suffix: str, digits: int = 1) -> Optional[str]:
    if value is None:
        return None
    if digits == 0:
        return "%d%s" % (int(round(value)), suffix)
    return ("%." + str(digits) + "f%s") % (value, suffix)


def _summary(data: dict[str, Any]) -> str:
    parts: list[str] = []
    solar = data.get("solar") or {}
    if solar:
        p = _fmt(solar.get("power"), "W", 0)
        y = solar.get("yieldToday")
        if p:
            parts.append(p)
        if y:
            parts.append("%.2f kWh today" % (float(y) / 1000.0))
    dcdc = data.get("dcdc") or {}
    if dcdc.get("power") is not None:
        parts.append(_fmt(dcdc.get("power"), "W DC-DC", 0) or "")
    elif dcdc.get("output_voltage") is not None:
        parts.append(_fmt(dcdc.get("output_voltage"), "V out", 1) or "")
    inv = data.get("inverter") or {}
    if inv.get("ac_power") is not None:
        parts.append(_fmt(inv.get("ac_power"), "W AC", 0) or "")
    if inv.get("ac_in_state"):
        parts.append("AC in " + str(inv["ac_in_state"]).replace("_", " ").lower())
    charger = data.get("charger") or {}
    if charger.get("voltage1") is not None:
        parts.append(_fmt(charger.get("voltage1"), "V", 1) or "")
    if charger.get("current1") is not None:
        parts.append(_fmt(charger.get("current1"), "A", 1) or "")
    lithium = data.get("lithium") or {}
    if lithium.get("voltage") is not None:
        parts.append(_fmt(lithium.get("voltage"), "V", 2) or "")
    if lithium.get("balancer"):
        parts.append(str(lithium["balancer"]).lower())
    protect = data.get("protect") or {}
    if protect.get("output_state"):
        parts.append("output " + str(protect["output_state"]).lower())
    if protect.get("input_voltage") is not None:
        parts.append(_fmt(protect.get("input_voltage"), "V in", 1) or "")
    meter = data.get("meter") or {}
    if meter.get("meter_type"):
        parts.append(str(meter["meter_type"]).replace("_", " ").title())
    if meter.get("current") is not None:
        parts.append(_fmt(meter.get("current"), "A", 1) or "")
    sense = data.get("sense") or {}
    if sense:
        if sense.get("voltage") is not None:
            parts.append(_fmt(sense.get("voltage"), "V", 2) or "")
        if sense.get("temperature") is not None:
            parts.append(_fmt(sense.get("temperature"), "C", 0) or "")
    batt = data.get("battery") or {}
    if data.get("type") in BATTERY_AUTHORITY_TYPES or (
        batt.get("soc") is not None and "solar" not in data
    ):
        if batt.get("soc") is not None:
            parts.append(_fmt(batt.get("soc"), "%", 0) or "")
        if batt.get("voltage") is not None:
            parts.append(_fmt(batt.get("voltage"), "V", 1) or "")
        if batt.get("current") is not None:
            parts.append(_fmt(batt.get("current"), "A", 1) or "")
    elif batt.get("state") and not parts:
        parts.append(str(batt["state"]).replace("_", " ").title())
    if data.get("chargerError") and _nonzero_alarm(data.get("chargerError")):
        parts.append("err " + str(data["chargerError"]))
    if data.get("alarm") and _nonzero_alarm(data.get("alarm")):
        parts.append(str(data["alarm"]))
    cleaned = [p for p in parts if p]
    if cleaned:
        return " · ".join(cleaned[:6])
    label = data.get("typeLabel") or data.get("type") or "Victron"
    model = data.get("model") or ""
    if model and not str(model).startswith("<Unknown"):
        return "%s · %s" % (label, model)
    return str(label)


def merge_overview(
    device_data: dict[str, dict],
    device_names: dict[str, str],
    last_update: dict[str, float],
    bms_address: str = "",
) -> dict[str, Any]:
    """Fold per-device snapshots into the dashboard overview without dropping extras."""
    merged: dict[str, Any] = {
        "battery": {
            "soc": 0,
            "voltage": 0,
            "current": 0,
            "power": 0,
            "state": "Unknown",
            "temperature": 0,
            "consumed_ah": 0,
            "remaining_mins": 0,
        },
        "solar": {"power": 0, "yieldToday": 0, "loadA": 0},
        "inverter": {"ac_power": 0, "ac_in_power": 0, "ac_in_state": "", "state": ""},
        "dcdc": {"power": 0, "input_voltage": 0, "output_voltage": 0, "output_current": 0, "state": ""},
        "alarm": "None",
        "devices": {},
    }

    has_shunt = False
    for addr, data in device_data.items():
        kind = data.get("type") or ""
        if kind in ("BatteryMonitor", "LynxSmartBMS") or (bms_address and addr == bms_address):
            has_shunt = True

    for addr, data in device_data.items():
        name = device_names.get(addr, addr[-8:].replace(":", ""))
        kind = data.get("type") or ""
        merged["devices"][name] = {
            "address": addr,
            "name": name,
            "last_seen": last_update.get(addr, 0),
            "fields": sorted(
                k
                for k in data.keys()
                if k not in ("fields", "summary", "type", "typeLabel", "model")
            ),
            "type": kind,
            "typeLabel": data.get("typeLabel") or "",
            "model": data.get("model") or "",
            "summary": data.get("summary") or "",
        }

        if "solar" in data:
            merged["solar"]["power"] += data["solar"].get("power", 0) or 0
            merged["solar"]["yieldToday"] = max(
                merged["solar"]["yieldToday"],
                data["solar"].get("yieldToday", 0) or 0,
            )
            merged["solar"]["loadA"] += data["solar"].get("loadA", 0) or 0

        if "inverter" in data:
            merged["inverter"]["ac_power"] += data["inverter"].get("ac_power", 0) or 0
            merged["inverter"]["ac_in_power"] += data["inverter"].get("ac_in_power", 0) or 0
            state = data["inverter"].get("ac_in_state")
            if state:
                merged["inverter"]["ac_in_state"] = state
            inv_state = data["inverter"].get("state")
            if inv_state:
                merged["inverter"]["state"] = inv_state
            for extra in ("ac_voltage", "ac_current", "ac_apparent_power"):
                if extra in data["inverter"]:
                    merged["inverter"][extra] = data["inverter"][extra]

        if "dcdc" in data:
            dcdc = data["dcdc"]
            merged["dcdc"]["power"] += dcdc.get("power", 0) or 0
            for key in ("input_voltage", "output_voltage", "output_current", "input_current", "state"):
                if dcdc.get(key) not in (None, "", 0):
                    merged["dcdc"][key] = dcdc[key]

        if "battery" in data:
            skip_current = has_shunt and kind in SOLAR_TYPES | DCDC_TYPES | {"AcCharger", "Inverter"}
            skip_soc = kind not in BATTERY_AUTHORITY_TYPES and not (
                bms_address and addr == bms_address
            )
            if not bms_address or addr != bms_address:
                for k, v in data["battery"].items():
                    if k == "soc" and skip_soc:
                        continue
                    if k == "current" and skip_current:
                        continue
                    if k in ("consumed_ah", "remaining_mins") and skip_soc:
                        continue
                    if isinstance(v, (int, float)) and v != 0:
                        merged["battery"][k] = v
                    elif isinstance(v, str) and v not in ("Unknown", "", None):
                        merged["battery"][k] = v

        alarm = data.get("alarm")
        if alarm and _nonzero_alarm(str(alarm)):
            merged["alarm"] = alarm
        err = data.get("chargerError")
        if err and _nonzero_alarm(str(err)):
            merged["alarm"] = err

    if bms_address and bms_address in device_data:
        bms_batt = device_data[bms_address].get("battery", {})
        for k, v in bms_batt.items():
            if isinstance(v, (int, float)):
                merged["battery"][k] = v
            elif isinstance(v, str) and v not in ("Unknown", ""):
                merged["battery"][k] = v
        bms_v = bms_batt.get("voltage", 0) or 0
        bms_i = bms_batt.get("current", 0) or 0
        merged["battery"]["power"] = bms_v * bms_i
    else:
        merged["battery"]["power"] = (
            (merged["battery"].get("voltage") or 0)
            * (merged["battery"].get("current") or 0)
        )

    return merged
