"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { DeviceRole, VictronInstallationConfig } from "@/lib/victron-config";

const STEPS = [
  { id: "name", label: "Installation" },
  { id: "discover", label: "Devices" },
  { id: "keys", label: "Keys" },
  { id: "names", label: "Names" },
] as const;

type StepId = (typeof STEPS)[number]["id"];

export type ScannedDevice = {
  address: string;
  name: string;
  rssi: number | null;
  type: string | null;
  typeLabel: string | null;
  suggestedRole: string;
};

type DraftDevice = {
  address: string;
  key: string;
  name: string;
  role: DeviceRole;
  advertisedName: string;
  typeLabel: string;
};

const MAC_RE = /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/;
const UUID_RE =
  /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
const KEY_RE = /^[0-9a-fA-F]+$/;

function isValidAddress(addr: string) {
  const a = addr.trim();
  return MAC_RE.test(a) || UUID_RE.test(a);
}

function normalizeKey(key: string) {
  return key.trim().replace(/[\s-]/g, "");
}

function keyError(key: string): string | null {
  const k = normalizeKey(key);
  if (!k) return "Enter the Instant Readout key";
  if (!KEY_RE.test(k) || k.length % 2 !== 0) return "Must be hexadecimal";
  if (k.length < 16 || k.length > 64) return "Expected 16–64 hex characters";
  if (k.length !== 32) return "Usually 32 hex characters — check VictronConnect";
  return null;
}

function isKeyAcceptable(key: string) {
  const err = keyError(key);
  return err === null || err.startsWith("Usually");
}

function asRole(role: string | undefined): DeviceRole {
  if (role === "bms" || role === "solar" || role === "monitor" || role === "other") {
    return role;
  }
  return "other";
}

function fromSaved(
  config: VictronInstallationConfig | null,
  scanned: ScannedDevice[]
): { installationName: string; devices: DraftDevice[] } {
  const scanByAddr = new Map(scanned.map((d) => [d.address.toUpperCase(), d]));
  const devices = (config?.devices ?? []).map((d) => {
    const scan = scanByAddr.get(d.address.toUpperCase());
    return {
      address: d.address.toUpperCase(),
      key: d.key,
      name: d.name,
      role: asRole(d.role),
      advertisedName: scan?.name || d.name,
      typeLabel: scan?.typeLabel || "",
    };
  });
  return {
    installationName: config?.installationName ?? "",
    devices,
  };
}

function RoleBadge({ role }: { role: string }) {
  const label =
    role === "bms"
      ? "BMS / shunt"
      : role === "solar"
        ? "Solar"
        : role === "monitor"
          ? "Monitor"
          : "Other";
  return (
    <span className="text-[11px] uppercase tracking-wide text-gray-500">{label}</span>
  );
}

export function SetupWizard({
  initial,
  onSaved,
  onCancel,
}: {
  initial: VictronInstallationConfig | null;
  onSaved: (config: VictronInstallationConfig) => void;
  onCancel?: () => void;
}) {
  const editing = (initial?.devices.length ?? 0) > 0;
  const seeded = fromSaved(initial, []);
  const [step, setStep] = useState<StepId>(editing ? "name" : "name");
  const [installationName, setInstallationName] = useState(seeded.installationName);
  const [devices, setDevices] = useState<DraftDevice[]>(seeded.devices);
  const [selected, setSelected] = useState<Set<string>>(
    () => new Set(seeded.devices.map((d) => d.address))
  );
  const [scanned, setScanned] = useState<ScannedDevice[]>([]);
  const [scanning, setScanning] = useState(false);
  const [scanError, setScanError] = useState<string | null>(null);
  const [manualAddress, setManualAddress] = useState("");
  const [manualError, setManualError] = useState<string | null>(null);
  const [showKeys, setShowKeys] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [hasScanned, setHasScanned] = useState(false);

  const stepIndex = STEPS.findIndex((s) => s.id === step);

  const selectedDevices = useMemo(() => {
    const byAddr = new Map(devices.map((d) => [d.address, d]));
    return Array.from(selected)
      .map((addr) => byAddr.get(addr))
      .filter((d): d is DraftDevice => Boolean(d));
  }, [devices, selected]);

  const upsertDevice = useCallback((partial: Partial<DraftDevice> & { address: string }) => {
    const address = partial.address.toUpperCase();
    setDevices((prev) => {
      const idx = prev.findIndex((d) => d.address === address);
      if (idx === -1) {
        return [
          ...prev,
          {
            key: "",
            name: "",
            role: "other",
            advertisedName: "",
            typeLabel: "",
            ...partial,
            address,
          },
        ];
      }
      const next = [...prev];
      next[idx] = { ...next[idx], ...partial, address };
      return next;
    });
  }, []);

  const runScan = useCallback(async () => {
    setScanning(true);
    setScanError(null);
    try {
      const res = await fetch("/api/setup/scan", { method: "POST" });
      const json = await res.json();
      const found: ScannedDevice[] = Array.isArray(json.devices) ? json.devices : [];
      setScanned(found);
      setHasScanned(true);
      if (!json.ok && json.error) setScanError(json.error);
      else if (!found.length) {
        setScanError(
          "No Victron devices found. Quit VictronConnect, keep Instant Readout on, or enter an address manually."
        );
      }
      setDevices((prev) => {
        const byAddr = new Map(prev.map((d) => [d.address, d]));
        for (const item of found) {
          const address = item.address.toUpperCase();
          const existing = byAddr.get(address);
          byAddr.set(address, {
            address,
            key: existing?.key ?? "",
            name: existing?.name || item.name || "",
            role: existing?.role ?? asRole(item.suggestedRole),
            advertisedName: item.name || existing?.advertisedName || "",
            typeLabel: item.typeLabel || existing?.typeLabel || "",
          });
        }
        return Array.from(byAddr.values());
      });
      if (!editing && found.length) {
        setSelected((prev) => {
          if (prev.size) return prev;
          return new Set(found.map((d) => d.address.toUpperCase()));
        });
      }
    } catch (e) {
      setHasScanned(true);
      setScanError(e instanceof Error ? e.message : "Scan failed");
    } finally {
      setScanning(false);
    }
  }, [editing]);

  useEffect(() => {
    if (step === "discover" && !hasScanned && !scanning) {
      void runScan();
    }
  }, [step, hasScanned, scanning, runScan]);

  const addManual = () => {
    const address = manualAddress.trim().toUpperCase();
    if (!isValidAddress(address)) {
      setManualError("Enter a MAC (AA:BB:CC:DD:EE:FF) or the UUID from a scan.");
      return;
    }
    setManualError(null);
    upsertDevice({
      address,
      name: devices.find((d) => d.address === address)?.name || "",
      advertisedName: "Manual",
      typeLabel: "",
      role: devices.find((d) => d.address === address)?.role || "other",
    });
    setSelected((prev) => new Set(prev).add(address));
    setManualAddress("");
  };

  const toggleSelect = (address: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(address)) next.delete(address);
      else next.add(address);
      return next;
    });
  };

  const canNext = () => {
    if (step === "name") return installationName.trim().length > 0;
    if (step === "discover") return selected.size > 0;
    if (step === "keys") return selectedDevices.every((d) => isKeyAcceptable(d.key));
    if (step === "names") {
      return selectedDevices.every((d) => d.name.trim().length > 0);
    }
    return false;
  };

  const goNext = () => {
    if (step === "name") setStep("discover");
    else if (step === "discover") setStep("keys");
    else if (step === "keys") setStep("names");
  };

  const goBack = () => {
    if (step === "discover") setStep("name");
    else if (step === "keys") setStep("discover");
    else if (step === "names") setStep("keys");
  };

  const setBms = (address: string) => {
    setDevices((prev) =>
      prev.map((d) => {
        if (!selected.has(d.address)) return d;
        if (d.address === address) return { ...d, role: "bms" };
        if (d.role === "bms") {
          const fallback =
            d.typeLabel.toLowerCase().includes("solar") || /solar|mppt/i.test(d.name)
              ? "solar"
              : "monitor";
          return { ...d, role: fallback };
        }
        return d;
      })
    );
  };

  const setRole = (address: string, role: DeviceRole) => {
    if (role === "bms") {
      setBms(address);
      return;
    }
    setDevices((prev) => prev.map((d) => (d.address === address ? { ...d, role } : d)));
  };

  const save = async () => {
    setSaving(true);
    setSaveError(null);
    const payload: VictronInstallationConfig = {
      installationName: installationName.trim(),
      devices: selectedDevices.map((d) => ({
        address: d.address,
        key: normalizeKey(d.key).toLowerCase(),
        name: d.name.trim(),
        role: d.role,
      })),
    };
    try {
      const res = await fetch("/api/setup/save", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const json = await res.json();
      if (!res.ok || !json.ok) {
        setSaveError(json.error || "Could not save configuration");
        return;
      }
      onSaved(json.config as VictronInstallationConfig);
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : "Could not save configuration");
    } finally {
      setSaving(false);
    }
  };

  const listed = useMemo(() => {
    const scanAddrs = new Set(scanned.map((d) => d.address.toUpperCase()));
    const extras = devices.filter((d) => selected.has(d.address) && !scanAddrs.has(d.address));
    return [
      ...scanned.map((s) => {
        const address = s.address.toUpperCase();
        const draft = devices.find((d) => d.address === address);
        return {
          address,
          advertisedName: s.name,
          typeLabel: s.typeLabel || "",
          rssi: s.rssi,
          selected: selected.has(address),
          existing: Boolean(draft?.key),
        };
      }),
      ...extras.map((d) => ({
        address: d.address,
        advertisedName: d.advertisedName || d.name || "Manual",
        typeLabel: d.typeLabel || "",
        rssi: null as number | null,
        selected: true,
        existing: Boolean(d.key),
      })),
    ];
  }, [scanned, devices, selected]);

  return (
    <div className="min-h-screen flex items-center justify-center p-6">
      <div className="w-full max-w-xl bg-gray-900 border border-gray-800 rounded-2xl p-6 md:p-8 space-y-6">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-xs uppercase tracking-widest text-gray-500">
              {editing ? "Edit installation" : "First installation"}
            </p>
            <h1 className="text-2xl font-bold mt-1">Victron BLE setup</h1>
            <p className="text-sm text-gray-400 mt-1">
              Name the site, pick devices, paste Instant Readout keys. History is kept when you re-run this.
            </p>
          </div>
          {onCancel && (
            <button
              type="button"
              onClick={onCancel}
              className="text-sm text-gray-500 hover:text-gray-300"
            >
              Close
            </button>
          )}
        </div>

        <ol className="flex gap-2">
          {STEPS.map((s, i) => {
            const active = s.id === step;
            const done = i < stepIndex;
            return (
              <li key={s.id} className="flex-1">
                <div
                  className={`h-1 rounded-full ${
                    active || done ? "bg-amber-500" : "bg-gray-800"
                  }`}
                />
                <div
                  className={`mt-2 text-[11px] uppercase tracking-wide ${
                    active ? "text-amber-400" : done ? "text-gray-400" : "text-gray-600"
                  }`}
                >
                  {i + 1}. {s.label}
                </div>
              </li>
            );
          })}
        </ol>

        {step === "name" && (
          <div className="space-y-3">
            <label className="block text-sm text-gray-300" htmlFor="installation-name">
              Installation name
            </label>
            <input
              id="installation-name"
              value={installationName}
              onChange={(e) => setInstallationName(e.target.value)}
              placeholder="Van, house, boat…"
              className="w-full bg-gray-950 border border-gray-800 rounded-xl px-4 py-3 text-lg outline-none focus:border-amber-600"
              autoFocus
            />
            <p className="text-xs text-gray-500">
              Shown in the macOS panel header and the dashboard.
            </p>
          </div>
        )}

        {step === "discover" && (
          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <p className="text-sm text-gray-400">
                Select every Instant Readout device: MPPT, BMV/SmartShunt, Lynx/VE.Bus BMS, MultiPlus, Orion, Phoenix, Smart Lithium, AC charger, Battery Protect.
              </p>
              <button
                type="button"
                onClick={() => void runScan()}
                disabled={scanning}
                className="text-sm px-3 py-1.5 rounded-lg bg-gray-800 hover:bg-gray-700 disabled:opacity-50"
              >
                {scanning ? "Scanning…" : "Scan again"}
              </button>
            </div>
            {scanning && (
              <p className="text-sm text-amber-400">Listening for Instant Readout advertisements (~8s)…</p>
            )}
            {scanError && <p className="text-sm text-amber-300">{scanError}</p>}
            <div className="space-y-2 max-h-72 overflow-y-auto">
              {listed.length === 0 && !scanning && (
                <p className="text-sm text-gray-500">Nothing listed yet. Scan or add a device manually.</p>
              )}
              {listed.map((item) => (
                <label
                  key={item.address}
                  className={`flex items-start gap-3 rounded-xl border px-3 py-3 cursor-pointer ${
                    item.selected ? "border-amber-700 bg-amber-950/20" : "border-gray-800 bg-gray-950"
                  }`}
                >
                  <input
                    type="checkbox"
                    checked={item.selected}
                    onChange={() => toggleSelect(item.address)}
                    className="mt-1"
                  />
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <span className="font-medium truncate">{item.advertisedName}</span>
                      {item.typeLabel && (
                        <span className="text-xs text-gray-500 truncate">{item.typeLabel}</span>
                      )}
                    </div>
                    <div className="font-mono text-xs text-gray-500 truncate">{item.address}</div>
                  </div>
                  {item.rssi != null && (
                    <span className="text-xs text-gray-600 font-mono">{item.rssi} dBm</span>
                  )}
                </label>
              ))}
            </div>
            <div className="flex gap-2">
              <input
                value={manualAddress}
                onChange={(e) => setManualAddress(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    addManual();
                  }
                }}
                placeholder="Manual address (MAC or UUID)"
                className="flex-1 bg-gray-950 border border-gray-800 rounded-xl px-3 py-2 text-sm font-mono outline-none focus:border-amber-600"
              />
              <button
                type="button"
                onClick={addManual}
                className="px-3 py-2 rounded-xl bg-gray-800 hover:bg-gray-700 text-sm"
              >
                Add
              </button>
            </div>
            {manualError && <p className="text-xs text-red-400">{manualError}</p>}
          </div>
        )}

        {step === "keys" && (
          <div className="space-y-4">
            <p className="text-sm text-gray-400">
              VictronConnect → device → Settings → Product Info → Instant Readout → show encryption key.
            </p>
            <button
              type="button"
              onClick={() => setShowKeys((v) => !v)}
              className="text-xs text-gray-500 hover:text-gray-300"
            >
              {showKeys ? "Hide keys" : "Show keys"}
            </button>
            <div className="space-y-3 max-h-80 overflow-y-auto">
              {selectedDevices.map((dev) => {
                const err = keyError(dev.key);
                const warn = err?.startsWith("Usually");
                return (
                  <div key={dev.address} className="bg-gray-950 border border-gray-800 rounded-xl p-3 space-y-2">
                    <div className="text-sm font-medium">{dev.name || dev.advertisedName || "Device"}</div>
                    <div className="font-mono text-xs text-gray-500">{dev.address}</div>
                    <input
                      type={showKeys ? "text" : "password"}
                      autoComplete="off"
                      spellCheck={false}
                      value={dev.key}
                      onChange={(e) => upsertDevice({ address: dev.address, key: e.target.value })}
                      placeholder="32-character hex key"
                      className="w-full bg-gray-900 border border-gray-800 rounded-lg px-3 py-2 font-mono text-sm outline-none focus:border-amber-600"
                    />
                    {err && (
                      <p className={`text-xs ${warn ? "text-amber-400" : "text-red-400"}`}>{err}</p>
                    )}
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {step === "names" && (
          <div className="space-y-4">
            <p className="text-sm text-gray-400">
              Give each device a name. Pick the BMS / shunt that should win for SOC, current, and voltage.
            </p>
            <div className="space-y-3 max-h-80 overflow-y-auto">
              {selectedDevices.map((dev) => (
                <div key={dev.address} className="bg-gray-950 border border-gray-800 rounded-xl p-3 space-y-3">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-xs font-mono text-gray-500 truncate">{dev.address}</span>
                    <RoleBadge role={dev.role} />
                  </div>
                  <input
                    value={dev.name}
                    onChange={(e) => upsertDevice({ address: dev.address, name: e.target.value })}
                    placeholder={dev.advertisedName || "Device name"}
                    className="w-full bg-gray-900 border border-gray-800 rounded-lg px-3 py-2 outline-none focus:border-amber-600"
                  />
                  <div className="flex flex-wrap gap-2">
                    {(["bms", "solar", "monitor", "other"] as DeviceRole[]).map((role) => (
                      <button
                        key={role}
                        type="button"
                        onClick={() => setRole(dev.address, role)}
                        className={`text-xs px-2 py-1 rounded-lg border ${
                          dev.role === role
                            ? "border-amber-600 bg-amber-950/40 text-amber-300"
                            : "border-gray-800 text-gray-500 hover:border-gray-600"
                        }`}
                      >
                        {role === "bms" ? "BMS / shunt" : role}
                      </button>
                    ))}
                  </div>
                </div>
              ))}
            </div>
            {saveError && <p className="text-sm text-red-400">{saveError}</p>}
          </div>
        )}

        <div className="flex items-center justify-between pt-2">
          <button
            type="button"
            onClick={step === "name" ? onCancel : goBack}
            disabled={step === "name" && !onCancel}
            className="px-4 py-2 rounded-lg text-sm text-gray-400 hover:text-gray-200 disabled:opacity-30"
          >
            {step === "name" ? "Cancel" : "Back"}
          </button>
          {step !== "names" ? (
            <button
              type="button"
              onClick={goNext}
              disabled={!canNext()}
              className="px-4 py-2 rounded-lg text-sm bg-amber-600 hover:bg-amber-500 disabled:opacity-40 disabled:hover:bg-amber-600"
            >
              Continue
            </button>
          ) : (
            <button
              type="button"
              onClick={() => void save()}
              disabled={!canNext() || saving}
              className="px-4 py-2 rounded-lg text-sm bg-amber-600 hover:bg-amber-500 disabled:opacity-40"
            >
              {saving ? "Saving…" : "Save installation"}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

export function StartReaderPrompt({
  installationName,
  onRetry,
  onEdit,
}: {
  installationName?: string;
  onRetry: () => void;
  onEdit: () => void;
}) {
  return (
    <div className="min-h-screen flex items-center justify-center p-8">
      <div className="max-w-lg bg-gray-900 border border-gray-800 rounded-2xl p-8 space-y-5">
        <h1 className="text-2xl font-bold">{installationName || "Victron"}</h1>
        <p className="text-gray-400">
          Devices are configured. Start the BLE reader so the dashboard can show live data.
        </p>
        <div className="bg-gray-950 rounded-lg p-3 font-mono text-sm">
          <p>python3 ble-reader/reader.py</p>
        </div>
        <p className="text-xs text-gray-500">
          Keep it running. It writes <span className="font-mono">ble-data.json</span> without changing history.
        </p>
        <div className="flex gap-3">
          <button
            onClick={onRetry}
            className="px-4 py-2 bg-amber-600 hover:bg-amber-500 rounded-lg text-sm"
          >
            Retry now
          </button>
          <button
            onClick={onEdit}
            className="px-4 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg text-sm"
          >
            Edit installation
          </button>
        </div>
      </div>
    </div>
  );
}
