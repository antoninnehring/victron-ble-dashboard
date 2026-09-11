import { NextResponse } from "next/server";
import { readFileSync } from "fs";
import { join } from "path";

export const dynamic = "force-dynamic";

interface BLEData {
  overview: {
    battery: {
      soc: number;
      voltage: number;
      current: number;
      power: number;
      state: string;
      temperature: number;
      consumed_ah: number;
      remaining_mins: number;
    };
    solar: { power: number; yieldToday: number };
    inverter: { ac_power: number };
    alarm: string;
    devices: Record<string, { address: string; last_seen: number; fields: string[] }>;
  };
  dailyStats: {
    date: string;
    solarYield: number;
    solarPeakPower: number;
    batterySOCMin: number;
    batterySOCMax: number;
    samples: number;
  }[];
  lastUpdated: number;
  deviceCount: number;
}

function generateAlerts(data: BLEData) {
  const alerts: { id: string; level: "info" | "warning" | "critical"; title: string; message: string; timestamp: number }[] = [];
  const now = Date.now();
  const { overview, dailyStats } = data;

  // Stale data warning — based on when devices were actually last heard from, not file write time
  const newestDeviceSeen = Math.max(
    ...Object.values(overview.devices).map((d) => d.last_seen)
  );
  const deviceAgeSecs = now / 1000 - newestDeviceSeen;
  if (deviceAgeSecs > 120) {
    const ageMins = Math.round(deviceAgeSecs / 60);
    alerts.push({
      id: "stale-data",
      level: deviceAgeSecs > 300 ? "critical" : "warning",
      title: "Stale Data",
      message: `No device heard from in ${ageMins >= 60 ? `${Math.floor(ageMins / 60)}h ${ageMins % 60}m` : `${ageMins}m`}. Readings are outdated.`,
      timestamp: now,
    });
  }

  // Low battery
  if (overview.battery.soc > 0 && overview.battery.soc < 20) {
    alerts.push({
      id: "low-battery",
      level: overview.battery.soc < 10 ? "critical" : "warning",
      title: "Low Battery",
      message: `Battery at ${overview.battery.soc}% - consider reducing consumption`,
      timestamp: now,
    });
  }

  // High battery temperature
  if (overview.battery.temperature > 45) {
    alerts.push({
      id: "high-temp",
      level: "warning",
      title: "High Battery Temperature",
      message: `Battery temperature at ${overview.battery.temperature}C`,
      timestamp: now,
    });
  }

  // Device alarm
  if (overview.alarm && overview.alarm !== "None") {
    alerts.push({
      id: "device-alarm",
      level: "critical",
      title: "Device Alarm",
      message: overview.alarm,
      timestamp: now,
    });
  }

  // Solar yield comparison with yesterday
  if (dailyStats.length >= 2) {
    const today = dailyStats[dailyStats.length - 1];
    const yesterday = dailyStats[dailyStats.length - 2];
    if (today && yesterday && yesterday.solarYield > 0) {
      const diff = ((today.solarYield - yesterday.solarYield) / yesterday.solarYield) * 100;
      if (diff < -50) {
        alerts.push({
          id: "solar-drop",
          level: "warning",
          title: "Solar Yield Drop",
          message: `Today's yield is ${Math.abs(diff).toFixed(0)}% lower than yesterday (${(today.solarYield / 1000).toFixed(1)} vs ${(yesterday.solarYield / 1000).toFixed(1)} kWh)`,
          timestamp: now,
        });
      }
    }
  }

  // 7-day average comparison
  if (dailyStats.length >= 7) {
    const last7 = dailyStats.slice(-7);
    const avg = last7.reduce((s, d) => s + d.solarYield, 0) / 7;
    const today = dailyStats[dailyStats.length - 1];
    if (today && avg > 0 && today.solarYield < avg * 0.5) {
      alerts.push({
        id: "below-avg",
        level: "info",
        title: "Below Average Solar",
        message: `Today's yield (${(today.solarYield / 1000).toFixed(1)} kWh) is below 7-day avg (${(avg / 1000).toFixed(1)} kWh)`,
        timestamp: now,
      });
    }
  }

  // Low remaining time
  if (overview.battery.remaining_mins > 0 && overview.battery.remaining_mins < 120) {
    alerts.push({
      id: "low-remaining",
      level: overview.battery.remaining_mins < 30 ? "critical" : "warning",
      title: "Low Battery Time Remaining",
      message: `Estimated ${overview.battery.remaining_mins} minutes of battery remaining`,
      timestamp: now,
    });
  }

  return alerts;
}

const NO_STORE = { "Cache-Control": "no-store, max-age=0" };

export async function GET() {
  const dataFile = join(process.cwd(), "ble-data.json");

  try {
    const raw = readFileSync(dataFile, "utf-8");
    const data: BLEData = JSON.parse(raw);
    const alerts = generateAlerts(data);

    const lastSeens = Object.values(data.overview?.devices ?? {}).map(
      (d) => d.last_seen
    );
    const newestSeen = lastSeens.length ? Math.max(...lastSeens) : 0;
    const devicesStale = (Date.now() / 1000 - newestSeen) > 120;

    return NextResponse.json(
      {
        ...data,
        alerts,
        devicesStale,
      },
      { headers: NO_STORE }
    );
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") {
      return NextResponse.json(
        {
          error: "no-ble-data",
          message: "No BLE data file found. Start the BLE reader first: cd ble-reader && python3 reader.py",
        },
        { status: 503, headers: NO_STORE }
      );
    }
    return NextResponse.json(
      { error: "read-error", message: String(err) },
      { status: 500, headers: NO_STORE }
    );
  }
}
