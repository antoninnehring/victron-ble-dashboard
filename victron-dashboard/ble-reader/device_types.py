#!/usr/bin/env python3
"""Victron Instant Readout BLE type map (victron_ble + official device list)."""

from __future__ import annotations

from typing import Any, Optional

# Advertisement mode byte (payload[4]) → victron_ble class name.
# Mode 0x6 Inverter RS is advertised but not parsed by victron_ble.
MODE_TO_TYPE = {
    0x1: "SolarCharger",
    0x2: "BatteryMonitor",
    0x3: "Inverter",
    0x4: "DcDcConverter",
    0x5: "SmartLithium",
    0x6: "InverterRS",
    0x8: "AcCharger",
    0x9: "SmartBatteryProtect",
    0xA: "LynxSmartBMS",
    0xB: "MultiRS",
    0xC: "VEBus",
    0xD: "DcEnergyMeter",
    0xF: "OrionXS",
}

# Smart Battery Sense is a BatteryMonitor-mode ad with a model override.
SENSE_MODEL_IDS = {0xA3A4, 0xA3A5}

TYPE_TO_ROLE = {
    "SolarCharger": "solar",
    "BatteryMonitor": "bms",
    "LynxSmartBMS": "bms",
    "SmartLithium": "bms",
    "DcEnergyMeter": "monitor",
    "BatterySense": "monitor",
    "AcCharger": "other",
    "DcDcConverter": "other",
    "Inverter": "other",
    "InverterRS": "other",
    "MultiRS": "other",
    "OrionXS": "other",
    "SmartBatteryProtect": "other",
    "VEBus": "other",
}

TYPE_LABELS = {
    "SolarCharger": "Solar charger / MPPT",
    "BatteryMonitor": "Battery monitor / SmartShunt",
    "LynxSmartBMS": "Lynx Smart BMS / VE.Bus BMS",
    "SmartLithium": "Smart Lithium",
    "DcEnergyMeter": "DC energy meter",
    "BatterySense": "Smart Battery Sense",
    "AcCharger": "AC charger (Blue Smart / Phoenix)",
    "DcDcConverter": "Orion-Tr Smart DC-DC",
    "Inverter": "Phoenix inverter",
    "InverterRS": "Inverter RS (advertised, not decoded)",
    "MultiRS": "Multi RS",
    "OrionXS": "Orion XS DC-DC",
    "SmartBatteryProtect": "Smart Battery Protect",
    "VEBus": "VE.Bus inverter / MultiPlus",
}

# victron_ble DeviceData class name → short type used in JSON.
DATA_CLASS_TO_TYPE = {
    "SolarChargerData": "SolarCharger",
    "BatteryMonitorData": "BatteryMonitor",
    "LynxSmartBMSData": "LynxSmartBMS",
    "SmartLithiumData": "SmartLithium",
    "DcEnergyMeterData": "DcEnergyMeter",
    "BatterySenseData": "BatterySense",
    "AcChargerData": "AcCharger",
    "DcDcConverterData": "DcDcConverter",
    "InverterData": "Inverter",
    "MultiRSData": "MultiRS",
    "OrionXSData": "OrionXS",
    "SmartBatteryProtectData": "SmartBatteryProtect",
    "VEBusData": "VEBus",
}

BATTERY_AUTHORITY_TYPES = {
    "BatteryMonitor",
    "LynxSmartBMS",
    "VEBus",
    "SmartLithium",
}

SOLAR_TYPES = {"SolarCharger", "MultiRS"}
INVERTER_TYPES = {"VEBus", "Inverter", "MultiRS"}
DCDC_TYPES = {"DcDcConverter", "OrionXS"}


def type_from_data_class(parsed: Any) -> str:
    return DATA_CLASS_TO_TYPE.get(type(parsed).__name__, type(parsed).__name__)


def classify_raw(raw: bytes, detected_name: Optional[str] = None) -> tuple[Optional[str], str, Optional[str]]:
    """Return (type_name, role, type_label) for a Victron manufacturer payload."""
    type_name = detected_name
    if not type_name and raw and len(raw) >= 5:
        type_name = MODE_TO_TYPE.get(raw[4])
    if type_name == "BatteryMonitor" and len(raw) >= 4:
        model_id = int.from_bytes(raw[2:4], "little")
        if model_id in SENSE_MODEL_IDS:
            type_name = "BatterySense"
    if not type_name:
        return None, "other", None
    role = TYPE_TO_ROLE.get(type_name, "other")
    label = TYPE_LABELS.get(type_name)
    return type_name, role, label
