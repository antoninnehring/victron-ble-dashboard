"use client";

import { useEffect, useState, useCallback } from "react";
import { formatDistanceToNow } from "date-fns";
import type { SystemOverview, DailyStats, Alert, TimePoint } from "@/lib/vrm-api";
import { EnergyFlowChart } from "@/components/energy-flow-chart";
import { DailyComparisonChart } from "@/components/daily-comparison-chart";
import { AlertPanel } from "@/components/alert-panel";
import { SolarForecast } from "@/components/solar-forecast";
import { formatKwh, whToKwh } from "@/lib/energy";

interface DashboardData {
  overview: SystemOverview;
  dailyStats: DailyStats[];
  timeseries?: TimePoint[];
  alerts: Alert[];
  lastUpdated: number;
  deviceCount: number;
  devicesStale?: boolean;
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
  const entries = Object.entries(devices);
  if (entries.length === 0) return null;

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-2xl p-5">
      <h3 className="text-sm font-medium text-gray-400 mb-3">Connected Devices</h3>
      <div className="space-y-2">
        {entries.map(([id, dev]) => {
          const age = (Date.now() - dev.last_seen * 1000) / 1000;
          const alive = age < 120;
          return (
            <div key={id} className="flex items-center gap-3 text-sm">
              <div className={`h-2 w-2 rounded-full ${alive ? "bg-emerald-500" : "bg-gray-600"}`} />
              <span className="font-mono text-gray-300">{dev.address}</span>
              <span className="text-gray-600 text-xs">{dev.fields.join(", ")}</span>
              <span className="ml-auto text-xs text-gray-600">
                {alive ? `${Math.round(age)}s ago` : "stale"}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function BLESetupGuide() {
  return (
    <div className="min-h-screen flex items-center justify-center p-8">
      <div className="max-w-lg bg-gray-900 border border-gray-800 rounded-2xl p-8 space-y-6">
        <h1 className="text-2xl font-bold">Victron BLE Dashboard</h1>
        <p className="text-gray-400">
          This dashboard reads data directly from your Victron devices via Bluetooth.
        </p>

        <div className="space-y-4">
          <div>
            <h3 className="font-medium text-amber-400 mb-2">Step 1: Install Python dependencies</h3>
            <div className="bg-gray-950 rounded-lg p-3 font-mono text-sm">
              <p>cd ble-reader</p>
              <p>pip3 install -r requirements.txt</p>
            </div>
          </div>

          <div>
            <h3 className="font-medium text-amber-400 mb-2">Step 2: Scan for devices</h3>
            <div className="bg-gray-950 rounded-lg p-3 font-mono text-sm">
              <p>python3 ble-reader/scan.py</p>
            </div>
          </div>

          <div>
            <h3 className="font-medium text-amber-400 mb-2">Step 3: Get encryption keys</h3>
            <p className="text-sm text-gray-400">
              Open <strong>VictronConnect</strong> app &rarr; tap your device &rarr;
              Settings &rarr; Product Info &rarr; <strong>Instant Readout</strong> &rarr; Show encryption key
            </p>
          </div>

          <div>
            <h3 className="font-medium text-amber-400 mb-2">Step 4: Configure .env.local</h3>
            <div className="bg-gray-950 rounded-lg p-3 font-mono text-sm">
              <p className="text-gray-500"># address=encryption_key</p>
              <p>VICTRON_DEVICES=AA:BB:CC:DD:EE:FF=0123456789abcdef</p>
            </div>
          </div>

          <div>
            <h3 className="font-medium text-amber-400 mb-2">Step 5: Start the BLE reader</h3>
            <div className="bg-gray-950 rounded-lg p-3 font-mono text-sm">
              <p>python3 ble-reader/reader.py</p>
            </div>
            <p className="text-xs text-gray-500 mt-1">
              Keep this running in a separate terminal. It writes data that the dashboard reads.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}

export default function Home() {
  const [data, setData] = useState<DashboardData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const fetchData = useCallback(async () => {
    try {
      const res = await fetch("/api/vrm", { cache: "no-store" });
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

  if (loading && !data) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="animate-pulse text-gray-400 text-lg">
          Connecting to Victron BLE...
        </div>
      </div>
    );
  }

  if (!data && error === "no-ble-data") {
    return <BLESetupGuide />;
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

  const { overview, dailyStats, alerts } = data;
  const isStale = !!data.devicesStale;
  const today = dailyStats[dailyStats.length - 1];
  const yesterday = dailyStats[dailyStats.length - 2];
  const yieldDiff =
    today && yesterday && yesterday.solarYield > 0
      ? ((today.solarYield - yesterday.solarYield) / yesterday.solarYield) * 100
      : null;

  const batteryDirection = isStale
    ? "Offline"
    : overview.battery.power > 50
      ? "Charging"
      : overview.battery.power < -50
        ? "Discharging"
        : "Idle";

  return (
    <div className="min-h-screen p-4 md:p-6 max-w-7xl mx-auto space-y-6">
      {/* Header */}
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Victron Dashboard</h1>
          <p className={`text-sm ${isStale ? "text-amber-500" : "text-gray-500"}`}>
            {isStale ? "Offline" : "BLE"} &middot; Updated{" "}
            {formatDistanceToNow(data.lastUpdated, { addSuffix: true })}
            {" "}&middot; {data.deviceCount} device{data.deviceCount !== 1 ? "s" : ""}
          </p>
        </div>
        <div className="flex items-center gap-3">
          <div className={`h-2 w-2 rounded-full ${isStale ? "bg-amber-500" : "bg-emerald-500 animate-pulse"}`} />
          <span className="text-sm text-gray-400">{batteryDirection}</span>
        </div>
      </header>

      {/* Battery Section */}
      <section className={`bg-gray-900 border border-gray-800 rounded-2xl p-5 ${isStale ? "opacity-50" : ""}`}>
        <div className="flex items-center gap-2 text-gray-400 text-sm mb-3">
          <span className="text-lg">🔋</span> Battery
          <span className="ml-auto text-xs text-gray-600">
            {isStale ? "offline" : overview.battery.state}
          </span>
        </div>
        {isStale ? (
          <div className="text-3xl font-mono font-bold text-gray-600">-- %</div>
        ) : (
          <BatteryGauge soc={overview.battery.soc} remaining={overview.battery.remaining_mins} />
        )}
        <div className="grid grid-cols-4 gap-4 mt-4 text-center">
          <div>
            <div className="text-xs text-gray-500">Voltage</div>
            <div className="font-mono">{isStale ? "--" : `${overview.battery.voltage.toFixed(1)}V`}</div>
          </div>
          <div>
            <div className="text-xs text-gray-500">Current</div>
            <div className="font-mono">{isStale ? "--" : `${overview.battery.current.toFixed(1)}A`}</div>
          </div>
          <div>
            <div className="text-xs text-gray-500">Power</div>
            <div className="font-mono">
              {isStale ? "--" : `${overview.battery.power > 0 ? "+" : ""}${overview.battery.power.toFixed(0)}W`}
            </div>
          </div>
          <div>
            <div className="text-xs text-gray-500">Temp</div>
            <div className="font-mono">{isStale ? "--" : `${overview.battery.temperature.toFixed(0)}C`}</div>
          </div>
        </div>
        {!isStale && overview.battery.consumed_ah > 0 && (
          <div className="text-xs text-gray-600 mt-2 text-center">
            Consumed: {overview.battery.consumed_ah.toFixed(1)} Ah
          </div>
        )}
      </section>

      {/* Main Stats Grid */}
      <div className={`grid grid-cols-2 md:grid-cols-4 gap-4 ${isStale ? "opacity-50" : ""}`}>
        <StatCard
          icon="☀️"
          title="Solar Power"
          value={isStale ? "--" : overview.solar.power}
          unit="W"
          color={isStale ? "text-gray-600" : "text-amber-400"}
        />
        <StatCard
          icon="⚡"
          title="Today's Yield"
          value={isStale ? "--" : formatKwh(whToKwh(overview.solar.yieldToday))}
          unit="kWh"
          subtitle={
            isStale ? undefined :
            yieldDiff !== null
              ? `${yieldDiff > 0 ? "+" : ""}${yieldDiff.toFixed(0)}% vs yesterday`
              : undefined
          }
          color={isStale ? "text-gray-600" : "text-amber-400"}
        />
        <StatCard
          icon="🏠"
          title="AC Load"
          value={isStale ? "--" : overview.inverter.ac_power}
          unit="W"
          color={isStale ? "text-gray-600" : "text-blue-400"}
        />
        <StatCard
          icon="🔋"
          title="Battery"
          value={isStale ? "--" : overview.battery.power}
          unit="W"
          subtitle={batteryDirection}
          color={
            isStale ? "text-gray-600"
            : overview.battery.power > 0
              ? "text-emerald-400"
              : overview.battery.power < 0
                ? "text-red-400"
                : "text-gray-400"
          }
        />
      </div>

      <SolarForecast
        yieldTodayWh={overview.solar.yieldToday}
        timeseries={data.timeseries ?? []}
        dataIsLive={!isStale}
      />

      {/* Charts */}
      {dailyStats.length > 1 && (
        <div className="grid md:grid-cols-2 gap-6">
          <EnergyFlowChart dailyStats={dailyStats} />
          <DailyComparisonChart dailyStats={dailyStats} />
        </div>
      )}

      {/* Alerts */}
      <AlertPanel alerts={alerts} />

      {/* Connected Devices */}
      <DeviceStatus devices={overview.devices} />
    </div>
  );
}
