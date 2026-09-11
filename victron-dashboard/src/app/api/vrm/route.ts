import { NextResponse } from "next/server";
import { readFileSync } from "fs";
import { join } from "path";
import { loadInstallation } from "@/lib/victron-config";
import {
  computeSameHour,
  formatWh,
  localClock,
  localIsoDate,
  type HistoryDays,
  type SameHourCompare,
} from "@/lib/same-hour";
import type {
  DailyStats,
  HistoryMeta,
  RawDeviceSnapshot,
  SystemOverview,
} from "@/lib/vrm-api";

export const dynamic = "force-dynamic";

interface BLEData {
  overview: SystemOverview;
  installationName?: string;
  dailyStats: DailyStats[];
  lastUpdated: number;
  deviceCount: number;
  bluetoothOff?: boolean;
  history?: HistoryMeta;
  raw_devices?: Record<string, RawDeviceSnapshot>;
  sameHour?: SameHourCompare;
}

function loadHistoryDays(): HistoryDays {
  try {
    const raw = readFileSync(join(process.cwd(), "ble-history.json"), "utf-8");
    const parsed = JSON.parse(raw) as { days?: HistoryDays };
    return parsed.days ?? {};
  } catch {
    return {};
  }
}

function resolveSameHour(data: BLEData): SameHourCompare {
  const todayWh = data.overview?.solar?.yieldToday ?? 0;
  return computeSameHour({
    days: loadHistoryDays(),
    todayIso: localIsoDate(),
    clock: localClock(),
    todayWh,
  });
}

function generateAlerts(data: BLEData) {
  const alerts: { id: string; level: "info" | "warning" | "critical"; title: string; message: string; timestamp: number }[] = [];
  const now = Date.now();
  const { overview } = data;
  if (!overview) return alerts;

  if (data.bluetoothOff) {
    alerts.push({
      id: "bluetooth-off",
      level: "critical",
      title: "Bluetooth is off",
      message: "Bluetooth is off — turn it on in Control Center to read Victron devices.",
      timestamp: now,
    });
  }

  // Stale data warning — based on when devices were actually last heard from, not file write time
  const lastSeens = Object.values(overview?.devices ?? {}).map((d) => d.last_seen);
  const newestDeviceSeen = lastSeens.length ? Math.max(...lastSeens) : 0;
  const deviceAgeSecs = now / 1000 - newestDeviceSeen;
  if (!data.bluetoothOff && deviceAgeSecs > 120) {
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
  const soc = overview.battery?.soc ?? 0;
  if (soc > 0 && soc < 20) {
    alerts.push({
      id: "low-battery",
      level: overview.battery.soc < 10 ? "critical" : "warning",
      title: "Low Battery",
      message: `Battery at ${soc}% - consider reducing consumption`,
      timestamp: now,
    });
  }

  // High battery temperature
  const temp = overview.battery?.temperature ?? 0;
  if (temp > 45) {
    alerts.push({
      id: "high-temp",
      level: "warning",
      title: "High Battery Temperature",
      message: `Battery temperature at ${temp}C`,
      timestamp: now,
    });
  }

  // Device alarm
  if (overview.alarm && overview.alarm !== "None" && overview.alarm !== "NO_ALARM") {
    alerts.push({
      id: "device-alarm",
      level: "critical",
      title: "Device Alarm",
      message: overview.alarm,
      timestamp: now,
    });
  }

  // Same-hour yield vs calendar yesterday (never full-day vs morning-so-far)
  const sameHour = data.sameHour;
  if (sameHour?.available && sameHour.diffPercent != null && sameHour.diffPercent < -50) {
    const yWh = sameHour.yesterdayWh ?? 0;
    alerts.push({
      id: "solar-drop",
      level: "warning",
      title: "Behind yesterday at this hour",
      message: `Yield at this hour is ${Math.abs(sameHour.diffPercent).toFixed(0)}% lower than yesterday (${formatWh(sameHour.todayWh)} vs ${formatWh(yWh)})`,
      timestamp: now,
    });
  }

  // Same-hour vs weekly average of completed days (skip if not enough morning samples)
  if (
    sameHour?.weekAvgWh &&
    sameHour.weekDiffPercent != null &&
    sameHour.weekDiffPercent < -50
  ) {
    alerts.push({
      id: "below-avg",
      level: "info",
      title: "Below average at this hour",
      message: `At this hour, yield (${formatWh(sameHour.todayWh)}) is below your weekly average (${formatWh(sameHour.weekAvgWh)})`,
      timestamp: now,
    });
  }

  // Low remaining time
  const remaining = overview.battery?.remaining_mins ?? 0;
  if (remaining > 0 && remaining < 120) {
    alerts.push({
      id: "low-remaining",
      level: overview.battery.remaining_mins < 30 ? "critical" : "warning",
      title: "Low Battery Time Remaining",
      message: `Estimated ${remaining} minutes of battery remaining`,
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
    const sameHour = resolveSameHour(data);
    const alerts = generateAlerts({ ...data, sameHour });

    const lastSeens = Object.values(data.overview?.devices ?? {}).map(
      (d) => d.last_seen
    );
    const newestSeen = lastSeens.length ? Math.max(...lastSeens) : 0;
    const devicesStale = (Date.now() / 1000 - newestSeen) > 120;

    const inst = loadInstallation();
    return NextResponse.json(
      {
        ...data,
        sameHour,
        installationName: data.installationName || inst.installationName || "",
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
