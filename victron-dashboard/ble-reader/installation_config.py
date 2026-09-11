#!/usr/bin/env python3
"""Load/save Victron installation config (JSON, with .env.local fallback).

Never log encryption keys.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any

DASHBOARD_DIR = Path(__file__).resolve().parent.parent
ENV_FILE = DASHBOARD_DIR / ".env.local"
ROLES = ("bms", "solar", "monitor", "other")

_ADDR_MAC = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")
_ADDR_UUID = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
_KEY_HEX = re.compile(r"^[0-9a-fA-F]+$")


def config_path() -> Path:
    override = os.environ.get("VICTRON_CONFIG", "").strip()
    if override:
        return Path(override).expanduser()
    return DASHBOARD_DIR / "victron-config.json"


def load_dotenv_file(path: Path | None = None) -> None:
    """Populate os.environ from .env.local without overwriting existing vars."""
    env_file = path or ENV_FILE
    if not env_file.exists():
        return
    try:
        text = env_file.read_text()
    except OSError:
        return
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        os.environ.setdefault(key.strip(), val.strip())


def parse_kv_list(raw: str) -> dict[str, str]:
    """Parse ADDRESS=value,ADDRESS=value lists (keys, names)."""
    items: dict[str, str] = {}
    for entry in (raw or "").split(","):
        entry = entry.strip()
        if "=" not in entry:
            continue
        addr, val = entry.split("=", 1)
        addr, val = addr.strip().upper(), val.strip()
        if addr and val:
            items[addr] = val
    return items


def normalize_address(addr: str) -> str:
    return (addr or "").strip().upper()


def is_valid_address(addr: str) -> bool:
    a = (addr or "").strip()
    return bool(_ADDR_MAC.match(a) or _ADDR_UUID.match(a))


def is_valid_key(key: str) -> bool:
    k = (key or "").strip().replace(" ", "").replace("-", "")
    if not _KEY_HEX.match(k):
        return False
    if len(k) % 2 != 0:
        return False
    return 16 <= len(k) <= 64


def normalize_key(key: str) -> str:
    return (key or "").strip().replace(" ", "").replace("-", "").lower()


def _clean_role(role: str | None) -> str:
    r = (role or "other").strip().lower()
    return r if r in ROLES else "other"


def _clean_device(raw: Any) -> dict[str, str] | None:
    if not isinstance(raw, dict):
        return None
    address = normalize_address(str(raw.get("address") or ""))
    key = normalize_key(str(raw.get("key") or ""))
    name = str(raw.get("name") or "").strip()
    role = _clean_role(str(raw.get("role") or ""))
    if not address or not key:
        return None
    if not name:
        name = address[-8:].replace(":", "")
    return {"address": address, "key": key, "name": name, "role": role}


def _clean_installation(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        return {"installationName": "", "devices": []}
    name = str(raw.get("installationName") or "").strip()
    devices: list[dict[str, str]] = []
    seen: set[str] = set()
    for item in raw.get("devices") or []:
        cleaned = _clean_device(item)
        if cleaned is None:
            continue
        if cleaned["address"] in seen:
            continue
        seen.add(cleaned["address"])
        devices.append(cleaned)
    bms_count = sum(1 for d in devices if d["role"] == "bms")
    if bms_count > 1:
        found = False
        for d in devices:
            if d["role"] == "bms":
                if found:
                    d["role"] = "monitor"
                else:
                    found = True
    return {"installationName": name, "devices": devices}


def _load_json() -> dict[str, Any] | None:
    path = config_path()
    if not path.exists():
        return None
    try:
        raw = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None
    cleaned = _clean_installation(raw)
    cleaned["_source"] = "json"
    return cleaned


def _load_env() -> dict[str, Any]:
    keys = parse_kv_list(os.environ.get("VICTRON_DEVICES", ""))
    names = parse_kv_list(os.environ.get("VICTRON_DEVICE_NAMES", ""))
    bms = normalize_address(os.environ.get("VICTRON_BMS_ADDRESS", ""))
    installation = (os.environ.get("VICTRON_INSTALLATION_NAME") or "").strip()
    devices: list[dict[str, str]] = []
    for addr, key in keys.items():
        role = "bms" if bms and addr == bms else "other"
        devices.append(
            {
                "address": addr,
                "key": normalize_key(key),
                "name": names.get(addr) or addr[-8:].replace(":", ""),
                "role": role,
            }
        )
    return {
        "installationName": installation,
        "devices": devices,
        "_source": "env" if devices else "none",
    }


def load_installation() -> dict[str, Any]:
    """JSON wins when it lists devices; otherwise fall back to VICTRON_* env."""
    json_cfg = _load_json()
    if json_cfg and json_cfg.get("devices"):
        return json_cfg
    env_cfg = _load_env()
    if env_cfg.get("devices"):
        return env_cfg
    if json_cfg is not None:
        return json_cfg
    return {"installationName": "", "devices": [], "_source": "none"}


def config_mtime() -> float | None:
    path = config_path()
    try:
        return path.stat().st_mtime if path.exists() else None
    except OSError:
        return None


def save_installation(data: Any) -> dict[str, Any]:
    """Write victron-config.json (0600). Raises ValueError on invalid input."""
    cleaned = _clean_installation(data)
    if not cleaned["installationName"]:
        raise ValueError("Installation name is required")
    if not cleaned["devices"]:
        raise ValueError("Select at least one device")
    for dev in cleaned["devices"]:
        if not is_valid_address(dev["address"]):
            raise ValueError("Each device needs a MAC address or UUID")
        if not is_valid_key(dev["key"]):
            raise ValueError(
                "Each Instant Readout key must be 16–64 hex characters"
            )
        if not dev["name"].strip():
            raise ValueError("Each device needs a name")
    path = config_path()
    payload = {
        "installationName": cleaned["installationName"],
        "devices": cleaned["devices"],
    }
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2) + "\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)
    cleaned["_source"] = "json"
    return cleaned


def device_keys(inst: dict[str, Any] | None = None) -> dict[str, str]:
    cfg = inst if inst is not None else load_installation()
    return {d["address"]: d["key"] for d in cfg.get("devices") or []}


def device_names(inst: dict[str, Any] | None = None) -> dict[str, str]:
    cfg = inst if inst is not None else load_installation()
    return {d["address"]: d["name"] for d in cfg.get("devices") or []}


def bms_address(inst: dict[str, Any] | None = None) -> str:
    cfg = inst if inst is not None else load_installation()
    for d in cfg.get("devices") or []:
        if d.get("role") == "bms":
            return d["address"]
    return ""


def installation_name(inst: dict[str, Any] | None = None) -> str:
    cfg = inst if inst is not None else load_installation()
    return str(cfg.get("installationName") or "").strip()
