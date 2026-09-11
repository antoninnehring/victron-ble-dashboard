"use client";

import { useEffect, useState, useCallback } from "react";
import { formatDistanceToNow } from "date-fns";
import type { SystemOverview, DailyStats, Alert, TimePoint, HistoryMeta, RawDeviceSnapshot, SameHourCompare } from "@/lib/vrm-api";
import { EnergyFlowChart } from "@/components/energy-flow-chart";
import { DailyComparisonChart } from "@/components/daily-comparison-chart";
import { AlertPanel } from "@/components/alert-panel";
import { SolarForecast } from "@/components/solar-forecast";
import { SetupWizard, StartReaderPrompt } from "@/components/setup-wizard";
import { formatKwh, whToKwh } from "@/lib/energy";
import type { VictronInstallationConfig } from "@/lib/victron-config";

interface DashboardData {
  overview: SystemOverview;
  dailyStats: DailyStats[];
  timeseries?: TimePoint[];
  alerts: Alert[];
  lastUpdated: number;
  deviceCount: number;
  devicesStale?: boolean;
  bluetoothOff?: boolean;
  installationName?: string;
  history?: HistoryMeta;
  raw_devices?: Record<string, RawDeviceSnapshot>;
  sameHour?: SameHourCompare;
}

function BatteryGauge({ soc, remaining }: { soc: number; remaining: number }) {
  const color =
    soc > 60 ? "bg-emerald-500" : soc > 30 ? "bg-amber-500" : "bg-red-500";
  return (
    <div>
      <div className="flex items-center gap-3">
        <div className="w-full h-5 bg-gray-800 rounded-full overflow-hidden">
          <div
            className={`h-full ${color} rounded-full transition-all duration-1000`}
            style={{ width: `${soc}%` }}
          />
        </div>
        <span className="text-2xl font-mono font-bold min-w-[4ch] text-right">
          {soc}%
        </span>
      </div>
      {remaining > 0 && (
        <div className="text-xs text-gray-500 mt-1">
          ~{remaining >= 60 ? `${Math.floor(remaining / 60)}h ${remaining % 60}m` : `${remaining}m`} remaining
        </div>
      )}
    </div>
  );
}

function StatCard({
  title,
  value,
  unit,
  subtitle,
  icon,
  color = "text-gray-100",
}: {
  title: string;
  value: string | number;
  unit: string;
  subtitle?: string;
  icon: string;
  color?: string;
}) {
  return (
    <div className="bg-gray-900 border border-gray-800 rounded-2xl p-5 flex flex-col gap-2">
      <div className="flex items-center gap-2 text-gray-400 text-sm">
        <span className="text-lg">{icon}</span>
        {title}
      </div>
      <div className={`text-3xl font-bold font-mono ${color}`}>
        {typeof value === "number" ? value.toFixed(1) : value}
        <span className="text-base font-normal text-gray-500 ml-1">{unit}</span>
      </div>
      {subtitle && <div className="text-xs text-gray-500">{subtitle}</div>}
    </div>
  );
}

function DeviceStatus({ devices }: { devices: SystemOverview["devices"] }) {
  const entries = Object.entries(devices ?? {});
  if (entries.length === 0) return null;

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-2xl p-5">
      <h3 className="text-sm font-medium text-gray-400 mb-3">Connected Devices</h3>
      <div className="space-y-3">
        {entries.map(([id, dev]) => {
          const age = (Date.now() - (dev.last_seen || 0) * 1000) / 1000;
          const alive = age < 120;
          return (
            <div key={id} className="flex items-start gap-3 text-sm">
              <div className={`mt-1.5 h-2 w-2 rounded-full shrink-0 ${alive ? "bg-emerald-500" : "bg-gray-600"}`} />
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                  <span className="text-gray-200">{dev.name || id}</span>
                  {dev.typeLabel && (
                    <span className="text-xs text-gray-500">{dev.typeLabel}</span>
                  )}
                  <span className="font-mono text-gray-600 text-xs">{dev.address}</span>
                </div>
                {dev.summary && (
                  <div className="text-xs text-gray-400 mt-0.5">{dev.summary}</div>
                )}
                {dev.model && !dev.model.startsWith("<Unknown") && (
                  <div className="text-xs text-gray-600 mt-0.5">{dev.model}</div>
                )}
              </div>
              <span className="ml-auto text-xs text-gray-600 shrink-0">
                {alive ? `${Math.round(age)}s ago` : "stale"}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function num(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function ExtraDeviceGrid({
  overview,
  rawDevices,
}: {
  overview: SystemOverview;
  rawDevices?: Record<string, RawDeviceSnapshot>;
}) {
  const cards: { title: string; lines: string[] }[] = [];
  const dcdc = overview.dcdc;
  if (dcdc && ((dcdc.power ?? 0) > 1 || (dcdc.output_voltage ?? 0) > 0)) {
    const lines = [];
            if (dcdc.state) lines.push(dcdc.state.replace(/_/g, " "));
    if (dcdc.power) lines.push(`${dcdc.power.toFixed(0)} W out`);
    if (dcdc.input_voltage) lines.push(`${dcdc.input_voltage.toFixed(1)} V in`);
    if (dcdc.output_voltage) lines.push(`${dcdc.output_voltage.toFixed(1)} V out`);
    if (dcdc.output_current) lines.push(`${dcdc.output_current.toFixed(1)} A out`);
    cards.push({ title: "Orion / DC-DC", lines });
  }
  const inv = overview.inverter;
  if (inv && ((inv.ac_in_power ?? 0) !== 0 || inv.ac_in_state || inv.ac_voltage)) {
    const lines = [];
    if (inv.state) lines.push(inv.state.replace(/_/g, " "));
    if (inv.ac_in_state) lines.push(`AC in: ${inv.ac_in_state.replace(/_/g, " ")}`);
    if (inv.ac_in_power) lines.push(`${inv.ac_in_power.toFixed(0)} W in`);
    if (inv.ac_power) lines.push(`${inv.ac_power.toFixed(0)} W out`);
    if (inv.ac_voltage) lines.push(`${inv.ac_voltage.toFixed(0)} V AC`);
    if (inv.ac_current) lines.push(`${inv.ac_current.toFixed(1)} A AC`);
    cards.push({ title: "Inverter / VE.Bus", lines });
  }
  for (const raw of Object.values(rawDevices ?? {})) {
    const kind = raw.type || "";
    if (kind === "SmartLithium" && raw.lithium) {
      const li = raw.lithium as Record<string, unknown>;
      const lines: string[] = [];
      const v = num(li.voltage);
      const t = num(li.temperature);
      if (v != null) lines.push(`${v.toFixed(2)} V`);
      if (t != null) lines.push(`${t.toFixed(0)} C`);
      if (typeof li.balancer === "string") lines.push(String(li.balancer).toLowerCase());
      const cells = Array.isArray(li.cell_voltages)
        ? li.cell_voltages.filter((c): c is number => typeof c === "number")
        : [];
      if (cells.length) {
        lines.push(`cells ${Math.min(...cells).toFixed(2)}–${Math.max(...cells).toFixed(2)} V`);
      }
      cards.push({ title: (raw.typeLabel as string) || "Smart Lithium", lines });
    }
    if (kind === "AcCharger" && raw.charger) {
      const ch = raw.charger;
      const lines: string[] = [];
      if (typeof ch.state === "string") lines.push(ch.state.replace(/_/g, " "));
      const v1 = num(ch.voltage1);
      const i1 = num(ch.current1);
      if (v1 != null) lines.push(`${v1.toFixed(1)} V`);
      if (i1 != null) lines.push(`${i1.toFixed(1)} A`);
      const ac = num(ch.ac_current);
      if (ac != null) lines.push(`${ac.toFixed(1)} A AC`);
      cards.push({ title: "AC charger", lines });
    }
    if (kind === "SmartBatteryProtect" && raw.protect) {
      const p = raw.protect;
      const lines: string[] = [];
      if (typeof p.output_state === "string") lines.push(`output ${p.output_state.toLowerCase()}`);
      const vin = num(p.input_voltage);
      const vout = num(p.output_voltage);
      if (vin != null) lines.push(`${vin.toFixed(1)} V in`);
      if (vout != null) lines.push(`${vout.toFixed(1)} V out`);
      if (typeof p.alarm === "string" && p.alarm !== "NO_ALARM") lines.push(p.alarm);
      cards.push({ title: "Battery Protect", lines });
    }
    if (kind === "DcEnergyMeter" && raw.meter) {
      const m = raw.meter;
      const lines: string[] = [];
      if (typeof m.meter_type === "string") lines.push(m.meter_type.replace(/_/g, " "));
      const v = num(m.voltage);
      const i = num(m.current);
      if (v != null) lines.push(`${v.toFixed(1)} V`);
      if (i != null) lines.push(`${i.toFixed(1)} A`);
      cards.push({ title: "DC energy meter", lines });
    }
  }
  if (!cards.length) return null;
  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-4">
              {cards.map((card, i) => (
        <div key={`${card.title}-${i}`} className="bg-gray-900 border border-gray-800 rounded-2xl p-5">
          <div className="text-sm text-gray-400 mb-2">{card.title}</div>
          <div className="space-y-1 text-sm font-mono text-gray-200">
            {card.lines.map((line) => (
              <div key={line}>{line}</div>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

function HistoryCaption({ history, days }: { history?: HistoryMeta; days: number }) {
  const label = history?.label || "Days this Mac observed while scanning";
  const not = history?.not || "VictronConnect stored trends or VRM cloud history";
  return (
    <p className="text-xs text-gray-600">
      {label} ({days} day{days === 1 ? "" : "s"}). Not {not.toLowerCase()}.
    </p>
  );
}

export default function Home() {
  const [data, setData] = useState<DashboardData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [setup, setSetup] = useState<{
    configured: boolean;
    config: VictronInstallationConfig;
  } | null>(null);
  const [showWizard, setShowWizard] = useState(false);

  const fetchSetup = useCallback(async () => {
    try {
      const res = await fetch("/api/setup", { cache: "no-store" });
      const json = await res.json();
      setSetup({
        configured: Boolean(json.configured),
        config: json.config ?? { installationName: "", devices: [] },
      });
    } catch {
      setSetup({ configured: false, config: { installationName: "", devices: [] } });
    }
  }, []);

  const fetchData = useCallback(async () => {
    try {
      const res = await fetch("/api/vrm", {
        cache: "no-store",
        headers: { "Cache-Control": "no-cache" },
      });
      const json = await res.json();
      if (json.error) {
        setError(json.error);
      } else {
        setData(json);
        setError(null);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to fetch");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchSetup();
    if (typeof window !== "undefined") {
      const params = new URLSearchParams(window.location.search);
      if (params.get("setup") === "1") setShowWizard(true);
    }
  }, [fetchSetup]);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 15_000);

    // Refresh immediately when tab becomes visible after sleep/background
    const onVisible = () => {
      if (document.visibilityState === "visible") fetchData();
    };
    document.addEventListener("visibilitychange", onVisible);

    return () => {
      clearInterval(interval);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [fetchData]);

  if ((showWizard && setup === null) || ((loading && !data) && setup === null)) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="animate-pulse text-gray-400 text-lg">
          Connecting to Victron BLE...
        </div>
      </div>
    );
  }

  if (showWizard || (setup && !setup.configured && !data)) {
    return (
      <SetupWizard
        initial={setup?.config ?? null}
        onCancel={setup?.configured || data ? () => setShowWizard(false) : undefined}
        onSaved={(config) => {
          setSetup({ configured: true, config });
          setShowWizard(false);
          if (typeof window !== "undefined") {
            const url = new URL(window.location.href);
            url.searchParams.delete("setup");
            window.history.replaceState({}, "", url.pathname);
          }
          fetchData();
        }}
      />
    );
  }

  if ((loading && !data) || setup === null) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="animate-pulse text-gray-400 text-lg">
          Connecting to Victron BLE...
        </div>
      </div>
    );
  }

  if (!data && error === "no-ble-data") {
    return (
      <StartReaderPrompt
        installationName={setup.config.installationName}
        onRetry={fetchData}
        onEdit={() => setShowWizard(true)}
      />
    );
  }

  if (!data) {
    return (
      <div className="min-h-screen flex items-center justify-center p-8">
        <div className="bg-red-950/50 border border-red-800 rounded-2xl p-6 max-w-md">
          <h2 className="text-red-400 font-bold text-lg mb-2">Connection Error</h2>
          <p className="text-red-300 text-sm">{error}</p>
          <button
            onClick={fetchData}
            className="mt-4 px-4 py-2 bg-red-900 hover:bg-red-800 rounded-lg text-sm transition-colors"
          >
            Retry
          </button>
        </div>
      </div>
    );
  }

  const { overview, dailyStats = [], alerts = [] } = data;
  const isStale = !!data.devicesStale;
  const battery = overview?.battery ?? {
    soc: 0,
    voltage: 0,
    current: 0,
    power: 0,
    state: "Unknown",
    temperature: 0,
    consumed_ah: 0,
    remaining_mins: 0,
  };
  const solar = overview?.solar ?? { power: 0, yieldToday: 0 };
  const inverter = overview?.inverter ?? { ac_power: 0 };
  const sameHour = data.sameHour;
  const yieldDiff = sameHour?.available ? sameHour.diffPercent : null;

  const batteryDirection = isStale
    ? "Offline"
    : battery.power > 50
      ? "Charging"
      : battery.power < -50
        ? "Discharging"
        : "Idle";
  const historyDays = data.history?.days ?? dailyStats.length;

  return (
    <div className="min-h-screen p-4 md:p-6 max-w-7xl mx-auto space-y-6">
      {data.bluetoothOff && (
        <div className="bg-amber-950/60 border border-amber-700 rounded-xl px-4 py-3 text-sm text-amber-200">
          Bluetooth is off — turn it on in Control Center to read Victron devices.
        </div>
      )}
      {/* Header */}
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">
            {data.installationName || setup?.config.installationName || "Victron Dashboard"}
          </h1>
          <p className={`text-sm ${isStale ? "text-amber-500" : "text-gray-500"}`}>
            {isStale ? "Offline" : "BLE Instant Readout"} &middot; Updated{" "}
            {formatDistanceToNow(data.lastUpdated, { addSuffix: true })}
            {" "}&middot; {data.deviceCount} device{data.deviceCount !== 1 ? "s" : ""}
            {historyDays > 0 ? ` · ${historyDays} day${historyDays === 1 ? "" : "s"} on this Mac` : ""}
          </p>
        </div>
        <div className="flex items-center gap-3">
          <button
            type="button"
            onClick={() => setShowWizard(true)}
            className="text-sm text-gray-500 hover:text-gray-300"
          >
            Edit installation
          </button>
          <div className={`h-2 w-2 rounded-full ${isStale ? "bg-amber-500" : "bg-emerald-500 animate-pulse"}`} />
          <span className="text-sm text-gray-400">{batteryDirection}</span>
        </div>
      </header>

      {/* Battery Section */}
      <section className={`bg-gray-900 border border-gray-800 rounded-2xl p-5 ${isStale ? "opacity-50" : ""}`}>
        <div className="flex items-center gap-2 text-gray-400 text-sm mb-3">
          <span className="text-lg">🔋</span> Battery
          <span className="ml-auto text-xs text-gray-600">
            {isStale ? "offline" : battery.state}
          </span>
        </div>
        {isStale ? (
          <div className="text-3xl font-mono font-bold text-gray-600">-- %</div>
        ) : (
          <BatteryGauge soc={battery.soc} remaining={battery.remaining_mins} />
        )}
        <div className="grid grid-cols-4 gap-4 mt-4 text-center">
          <div>
            <div className="text-xs text-gray-500">Voltage</div>
            <div className="font-mono">{isStale ? "--" : `${battery.voltage.toFixed(1)}V`}</div>
          </div>
          <div>
            <div className="text-xs text-gray-500">Current</div>
            <div className="font-mono">{isStale ? "--" : `${battery.current.toFixed(1)}A`}</div>
          </div>
          <div>
            <div className="text-xs text-gray-500">Power</div>
            <div className="font-mono">
              {isStale ? "--" : `${battery.power > 0 ? "+" : ""}${battery.power.toFixed(0)}W`}
            </div>
          </div>
          <div>
            <div className="text-xs text-gray-500">Temp</div>
            <div className="font-mono">{isStale ? "--" : `${battery.temperature.toFixed(0)}C`}</div>
          </div>
        </div>
        {!isStale && battery.consumed_ah > 0 && (
          <div className="text-xs text-gray-600 mt-2 text-center">
            Consumed: {battery.consumed_ah.toFixed(1)} Ah
          </div>
        )}
      </section>

      {/* Main Stats Grid */}
      <div className={`grid grid-cols-2 md:grid-cols-4 gap-4 ${isStale ? "opacity-50" : ""}`}>
        <StatCard
          icon="☀️"
          title="Solar Power"
          value={isStale ? "--" : solar.power}
          unit="W"
          color={isStale ? "text-gray-600" : "text-amber-400"}
        />
        <StatCard
          icon="⚡"
          title="Today's Yield"
          value={isStale ? "--" : formatKwh(whToKwh(solar.yieldToday))}
          unit="kWh"
          subtitle={
            isStale ? undefined :
            yieldDiff !== null
              ? `${yieldDiff > 0 ? "+" : ""}${yieldDiff.toFixed(0)}% vs this time yesterday`
              : undefined
          }
          color={isStale ? "text-gray-600" : "text-amber-400"}
        />
        <StatCard
          icon="🏠"
          title="AC Load"
          value={isStale ? "--" : inverter.ac_power}
          unit="W"
          color={isStale ? "text-gray-600" : "text-blue-400"}
        />
        <StatCard
          icon="🔋"
          title="Battery"
          value={isStale ? "--" : battery.power}
          unit="W"
          subtitle={batteryDirection}
          color={
            isStale ? "text-gray-600"
            : battery.power > 0
              ? "text-emerald-400"
              : battery.power < 0
                ? "text-red-400"
                : "text-gray-400"
          }
        />
      </div>

      <SolarForecast
        yieldTodayWh={solar.yieldToday}
        timeseries={data.timeseries ?? []}
        dataIsLive={!isStale}
      />

      <ExtraDeviceGrid
        overview={
          overview ?? {
            battery,
            solar,
            inverter,
            alarm: "None",
            devices: {},
          }
        }
        rawDevices={data.raw_devices}
      />

      {/* Charts */}
      {dailyStats.length > 1 && (
        <div className="space-y-2">
          <HistoryCaption history={data.history} days={historyDays} />
          <div className="grid md:grid-cols-2 gap-6">
            <EnergyFlowChart dailyStats={dailyStats} />
            <DailyComparisonChart dailyStats={dailyStats} />
          </div>
        </div>
      )}

      {/* Alerts */}
      <AlertPanel alerts={alerts} />

      {/* Connected Devices */}
      <DeviceStatus devices={overview?.devices ?? {}} />
    </div>
  );
}
