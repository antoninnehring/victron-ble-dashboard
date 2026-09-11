import { chmodSync, existsSync, readFileSync, renameSync, writeFileSync } from "fs";
import { join } from "path";

export const CONFIG_FILENAME = "victron-config.json";
export const ROLES = ["bms", "solar", "monitor", "other"] as const;
export type DeviceRole = (typeof ROLES)[number];

export interface VictronDeviceConfig {
  address: string;
  key: string;
  name: string;
  role: DeviceRole;
}

export interface VictronInstallationConfig {
  installationName: string;
  devices: VictronDeviceConfig[];
  siteLat?: number;
  siteLon?: number;
  siteLabel?: string;
}

export interface SiteCoords {
  lat: number;
  lon: number;
  label: string | null;
}

export type ConfigSource = "json" | "env" | "none";

export interface LoadedInstallation extends VictronInstallationConfig {
  source: ConfigSource;
}

const MAC_RE = /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/;
const UUID_RE =
  /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
const KEY_RE = /^[0-9a-fA-F]+$/;

export function dashboardDir() {
  return process.cwd();
}

export function configPath() {
  const override = process.env.VICTRON_CONFIG?.trim();
  if (override) return override;
  return join(dashboardDir(), CONFIG_FILENAME);
}

export function envPath() {
  return join(dashboardDir(), ".env.local");
}

export function normalizeAddress(addr: string) {
  return addr.trim().toUpperCase();
}

export function normalizeKey(key: string) {
  return key.trim().replace(/[\s-]/g, "").toLowerCase();
}

export function isValidAddress(addr: string) {
  const a = addr.trim();
  return MAC_RE.test(a) || UUID_RE.test(a);
}

export function isValidKey(key: string) {
  const k = normalizeKey(key);
  return KEY_RE.test(k) && k.length % 2 === 0 && k.length >= 16 && k.length <= 64;
}

function asRole(role: string | undefined): DeviceRole {
  const r = (role || "other").toLowerCase();
  return (ROLES as readonly string[]).includes(r) ? (r as DeviceRole) : "other";
}

function cleanDevice(raw: unknown): VictronDeviceConfig | null {
  if (!raw || typeof raw !== "object") return null;
  const d = raw as Record<string, unknown>;
  const address = normalizeAddress(String(d.address ?? ""));
  const key = normalizeKey(String(d.key ?? ""));
  const name = String(d.name ?? "").trim() || address.slice(-8).replace(/:/g, "");
  const role = asRole(String(d.role ?? ""));
  if (!address || !key) return null;
  return { address, key, name, role };
}

function readSiteCoords(raw: unknown): Pick<VictronInstallationConfig, "siteLat" | "siteLon" | "siteLabel"> {
  if (!raw || typeof raw !== "object") return {};
  const obj = raw as Record<string, unknown>;
  const lat = Number(obj.siteLat);
  const lon = Number(obj.siteLon);
  if (!Number.isFinite(lat) || !Number.isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) {
    return {};
  }
  const label = typeof obj.siteLabel === "string" ? obj.siteLabel.trim() : "";
  return label ? { siteLat: lat, siteLon: lon, siteLabel: label } : { siteLat: lat, siteLon: lon };
}

function cleanInstallation(raw: unknown): VictronInstallationConfig {
  if (!raw || typeof raw !== "object") {
    return { installationName: "", devices: [] };
  }
  const obj = raw as Record<string, unknown>;
  const installationName = String(obj.installationName ?? "").trim();
  const devices: VictronDeviceConfig[] = [];
  const seen = new Set<string>();
  const list = Array.isArray(obj.devices) ? obj.devices : [];
  for (const item of list) {
    const cleaned = cleanDevice(item);
    if (!cleaned || seen.has(cleaned.address)) continue;
    seen.add(cleaned.address);
    devices.push(cleaned);
  }
  let bmsSeen = false;
  for (const d of devices) {
    if (d.role !== "bms") continue;
    if (bmsSeen) d.role = "monitor";
    else bmsSeen = true;
  }
  return { installationName, devices, ...readSiteCoords(raw) };
}

function writeConfigFile(payload: VictronInstallationConfig) {
  const path = configPath();
  const tmp = `${path}.tmp`;
  const body: VictronInstallationConfig = {
    installationName: payload.installationName,
    devices: payload.devices,
  };
  if (payload.siteLat != null && payload.siteLon != null) {
    body.siteLat = payload.siteLat;
    body.siteLon = payload.siteLon;
    if (payload.siteLabel) body.siteLabel = payload.siteLabel;
  }
  writeFileSync(tmp, `${JSON.stringify(body, null, 2)}\n`, { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
  chmodSync(path, 0o600);
}

export function loadSiteLocation(): SiteCoords | null {
  const jsonCfg = loadFromJson();
  if (jsonCfg?.siteLat != null && jsonCfg.siteLon != null) {
    return {
      lat: jsonCfg.siteLat,
      lon: jsonCfg.siteLon,
      label: jsonCfg.siteLabel ?? null,
    };
  }
  return null;
}

export function persistSiteLocation(lat: number, lon: number, label?: string | null) {
  const existing = loadFromJson();
  writeConfigFile({
    installationName: existing?.installationName ?? "",
    devices: existing?.devices ?? [],
    siteLat: lat,
    siteLon: lon,
    siteLabel: label?.trim() || existing?.siteLabel,
  });
}

function parseKvList(raw: string) {
  const items: Record<string, string> = {};
  for (const entry of raw.split(",")) {
    const trimmed = entry.trim();
    const eq = trimmed.indexOf("=");
    if (eq <= 0) continue;
    const addr = trimmed.slice(0, eq).trim().toUpperCase();
    const val = trimmed.slice(eq + 1).trim();
    if (addr && val) items[addr] = val;
  }
  return items;
}

function parseEnvFile(text: string) {
  const env: Record<string, string> = {};
  for (const rawLine of text.split("\n")) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    const val = line.slice(eq + 1).trim();
    if (!(key in env)) env[key] = val;
  }
  return env;
}

function loadFromJson(): LoadedInstallation | null {
  const path = configPath();
  if (!existsSync(path)) return null;
  try {
    const raw = JSON.parse(readFileSync(path, "utf-8"));
    return { ...cleanInstallation(raw), source: "json" };
  } catch {
    return null;
  }
}

function loadFromEnv(): LoadedInstallation {
  const path = envPath();
  const env = existsSync(path)
    ? { ...parseEnvFile(readFileSync(path, "utf-8")), ...process.env }
    : { ...process.env };
  const keys = parseKvList(String(env.VICTRON_DEVICES ?? ""));
  const names = parseKvList(String(env.VICTRON_DEVICE_NAMES ?? ""));
  const bms = normalizeAddress(String(env.VICTRON_BMS_ADDRESS ?? ""));
  const installationName = String(env.VICTRON_INSTALLATION_NAME ?? "").trim();
  const devices: VictronDeviceConfig[] = Object.entries(keys).map(([address, key]) => ({
    address,
    key: normalizeKey(key),
    name: names[address] || address.slice(-8).replace(/:/g, ""),
    role: bms && address === bms ? "bms" : "other",
  }));
  return {
    installationName,
    devices,
    source: devices.length ? "env" : "none",
  };
}

export function loadInstallation(): LoadedInstallation {
  const jsonCfg = loadFromJson();
  if (jsonCfg && jsonCfg.devices.length) return jsonCfg;
  const envCfg = loadFromEnv();
  if (envCfg.devices.length) return envCfg;
  if (jsonCfg) return jsonCfg;
  return { installationName: "", devices: [], source: "none" };
}

export function isConfigured(inst?: LoadedInstallation) {
  return (inst ?? loadInstallation()).devices.length > 0;
}

export function saveInstallation(data: unknown): LoadedInstallation {
  const cleaned = cleanInstallation(data);
  if (!cleaned.installationName) {
    throw new Error("Installation name is required");
  }
  if (!cleaned.devices.length) {
    throw new Error("Select at least one device");
  }
  for (const dev of cleaned.devices) {
    if (!isValidAddress(dev.address)) {
      throw new Error("Each device needs a MAC address or UUID");
    }
    if (!isValidKey(dev.key)) {
      throw new Error("Each Instant Readout key must be 16–64 hex characters");
    }
    if (!dev.name.trim()) {
      throw new Error("Each device needs a name");
    }
  }
  const existing = loadFromJson();
  const payload: VictronInstallationConfig = {
    installationName: cleaned.installationName,
    devices: cleaned.devices,
    siteLat: cleaned.siteLat ?? existing?.siteLat,
    siteLon: cleaned.siteLon ?? existing?.siteLon,
    siteLabel: cleaned.siteLabel ?? existing?.siteLabel,
  };
  writeConfigFile(payload);
  return { ...payload, source: "json" };
}
