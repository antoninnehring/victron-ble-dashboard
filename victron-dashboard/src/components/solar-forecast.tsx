"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Area,
  AreaChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { format, parseISO } from "date-fns";
import { formatKwh, whToKwh } from "@/lib/energy";
import { weatherInfo, type DayWeather, type HourlyPoint, type SolarEstimate } from "@/lib/solar-forecast";

const LOCATION_KEY = "victron-site-location";

interface StoredLocation {
  lat: number;
  lon: number;
}

interface ForecastResponse {
  needsLocation?: boolean;
  message?: string;
  error?: string;
  location?: {
    latitude: number;
    longitude: number;
    timezone: string;
    source: "device" | "config";
  };
  todayIso?: string;
  estimate?: SolarEstimate;
  days?: DayWeather[];
  hourly?: HourlyPoint[];
  observedPeakW?: number;
}

interface TimePoint {
  t: string;
  solar: number;
}

function readStoredLocation(): StoredLocation | null {
  try {
    const raw = localStorage.getItem(LOCATION_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as StoredLocation;
    if (!Number.isFinite(parsed.lat) || !Number.isFinite(parsed.lon)) return null;
    return parsed;
  } catch {
    return null;
  }
}

function formatCoord(lat: number, lon: number): string {
  const ns = lat >= 0 ? "N" : "S";
  const ew = lon >= 0 ? "E" : "W";
  return `${Math.abs(lat).toFixed(2)}°${ns} ${Math.abs(lon).toFixed(2)}°${ew}`;
}

function sunClock(iso: string): string {
  if (!iso) return "—";
  const t = iso.includes("T") ? iso.slice(11, 16) : iso;
  return t;
}

function WeatherGlyph({ code, label }: { code: number; label: string }) {
  const kind =
    code === 0 || code === 1
      ? "sun"
      : code === 2
        ? "partly"
        : code >= 51 && code < 70
          ? "rain"
          : code >= 71 && code < 80
            ? "snow"
            : code >= 80 && code < 90
              ? "rain"
              : code >= 95
                ? "storm"
                : "cloud";
  const stroke = kind === "sun" || kind === "partly" ? "#fbbf24" : "#d1d5db";
  return (
    <svg
      viewBox="0 0 24 24"
      className="w-5 h-5 mx-auto mt-1"
      fill="none"
      stroke={stroke}
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-label={label}
      role="img"
    >
      {(kind === "sun" || kind === "partly") && (
        <>
          <circle cx={kind === "partly" ? 9 : 12} cy={kind === "partly" ? 9 : 12} r="3.2" />
          {kind === "sun" && (
            <>
              <path d="M12 3v2.2M12 18.8V21M4.2 12H2M22 12h-2.2M6.1 6.1 4.6 4.6M19.4 19.4l-1.5-1.5M6.1 17.9 4.6 19.4M19.4 4.6l-1.5 1.5" />
            </>
          )}
        </>
      )}
      {(kind === "cloud" || kind === "partly" || kind === "rain" || kind === "snow" || kind === "storm") && (
        <path d="M7.5 16.5h9.2a3.3 3.3 0 0 0 .4-6.6 4.6 4.6 0 0 0-8.7-1.5A3.6 3.6 0 0 0 7.5 16.5Z" />
      )}
      {kind === "rain" && (
        <>
          <path d="M9 18.5v2M12 18.2v2.4M15 18.5v2" />
        </>
      )}
      {kind === "snow" && (
        <>
          <path d="M9 18.8h.01M12 19.4h.01M15 18.8h.01" />
        </>
      )}
      {kind === "storm" && <path d="M11 14.5 9.5 18h3L11 21" />}
    </svg>
  );
}


export function SolarForecast({
  yieldTodayWh,
  timeseries,
  dataIsLive,
}: {
  yieldTodayWh: number;
  timeseries: TimePoint[];
  dataIsLive: boolean;
}) {
  const [location, setLocation] = useState<StoredLocation | null>(null);
  const [locationReady, setLocationReady] = useState(false);
  const [forecast, setForecast] = useState<ForecastResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [geoBusy, setGeoBusy] = useState(false);

  useEffect(() => {
    setLocation(readStoredLocation());
    setLocationReady(true);
  }, []);

  const fetchForecast = useCallback(async (coords: StoredLocation | null) => {
    setLoading(true);
    try {
      const q = coords ? `?lat=${coords.lat}&lon=${coords.lon}` : "";
      const res = await fetch(`/api/forecast${q}`);
      const json = (await res.json()) as ForecastResponse;
      if (json.error) {
        setError(json.message ?? json.error);
        setForecast(null);
      } else {
        setForecast(json);
        setError(null);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : "Forecast failed");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!locationReady) return;
    fetchForecast(location);
    const interval = setInterval(() => fetchForecast(location), 15 * 60_000);
    return () => clearInterval(interval);
  }, [fetchForecast, location, locationReady]);

  const requestGeo = useCallback(() => {
    if (!navigator.geolocation) {
      setError("Geolocation is not available in this browser.");
      return;
    }
    setGeoBusy(true);
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        const coords = { lat: pos.coords.latitude, lon: pos.coords.longitude };
        localStorage.setItem(LOCATION_KEY, JSON.stringify(coords));
        setLocation(coords);
        setGeoBusy(false);
      },
      (err) => {
        setError(err.message || "Location permission denied.");
        setGeoBusy(false);
      },
      { enableHighAccuracy: false, timeout: 10_000, maximumAge: 6 * 3600_000 },
    );
  }, []);

  const producedKwh = dataIsLive ? whToKwh(yieldTodayWh) : 0;
  const estimate = forecast?.estimate;
  const todayKwh = estimate?.todayKwh ?? 0;
  const progress = todayKwh > 0 ? Math.min(100, (producedKwh / todayKwh) * 100) : 0;

  const chartData = useMemo(() => {
    const hourly = forecast?.hourly ?? [];
    if (hourly.length === 0) return [];
    const actualByHour = new Map<number, { sum: number; n: number }>();
    for (const point of timeseries) {
      const hour = Number(point.t.slice(0, 2));
      if (!Number.isFinite(hour)) continue;
      const cur = actualByHour.get(hour) ?? { sum: 0, n: 0 };
      cur.sum += point.solar;
      cur.n += 1;
      actualByHour.set(hour, cur);
    }
    return hourly
      .filter((h) => h.expectedW > 5 || (actualByHour.get(h.hour)?.sum ?? 0) > 0)
      .map((h) => {
        const actual = actualByHour.get(h.hour);
        return {
          hour: `${String(h.hour).padStart(2, "0")}:00`,
          expected: Math.round(h.expectedW),
          actual: actual && actual.n > 0 ? Math.round(actual.sum / actual.n) : undefined,
          clouds: h.cloudCover,
        };
      });
  }, [forecast?.hourly, timeseries]);

  if (loading && !forecast) {
    return (
      <section className="bg-gray-900 border border-gray-800 rounded-2xl p-5">
        <div className="animate-pulse text-gray-500 text-sm">Loading solar forecast…</div>
      </section>
    );
  }

  if (forecast?.needsLocation) {
    return (
      <section className="bg-gray-900 border border-gray-800 rounded-2xl p-5 space-y-3">
        <h3 className="text-sm font-medium text-gray-400">Solar forecast</h3>
        <p className="text-sm text-gray-500">
          Location is needed to estimate today&apos;s yield from sun angle, season, and weather.
        </p>
        <button
          type="button"
          onClick={requestGeo}
          disabled={geoBusy}
          className="px-4 py-2 bg-amber-900/80 hover:bg-amber-800 rounded-lg text-sm text-amber-100 transition-colors disabled:opacity-50"
        >
          {geoBusy ? "Locating…" : "Use my location"}
        </button>
        {error && <p className="text-xs text-red-400">{error}</p>}
      </section>
    );
  }

  if (error && !estimate) {
    return (
      <section className="bg-gray-900 border border-gray-800 rounded-2xl p-5">
        <h3 className="text-sm font-medium text-gray-400 mb-2">Solar forecast</h3>
        <p className="text-sm text-red-400">{error}</p>
      </section>
    );
  }

  if (!estimate || !forecast?.days) return null;

  const loc = forecast.location;
  const yest = estimate.yesterday;
  const cloudCut = Math.round((1 - Math.min(estimate.cloudFactor, 1)) * 100);
  const yestDelta = yest ? Math.round((yest.factor - 1) * 100) : 0;

  return (
    <section className="bg-gray-900 border border-gray-800 rounded-2xl p-5 space-y-5">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="text-sm font-medium text-gray-400">Solar forecast</h3>
          <p className="text-xs text-gray-600 mt-1">
            {estimate.season} · sun {estimate.noonAltitudeDeg.toFixed(0)}° at noon ·{" "}
            {estimate.daylightHours.toFixed(1)} h daylight
            {loc && (
              <>
                {" "}
                · {formatCoord(loc.latitude, loc.longitude)}
              </>
            )}
          </p>
        </div>
        <button
          type="button"
          onClick={requestGeo}
          disabled={geoBusy}
          className="text-xs text-gray-500 hover:text-gray-300 transition-colors"
        >
          {geoBusy ? "Locating…" : "Update location"}
        </button>
      </header>

      <div className="grid md:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)] gap-6 items-end">
        <div>
          <div className="text-amber-400 text-4xl font-bold font-mono leading-none">
            {formatKwh(todayKwh, 1)}
            <span className="text-base font-normal text-gray-500 ml-1">kWh</span>
          </div>
          <div className="text-xs text-gray-500 mt-1">estimated today</div>
          <div className="mt-4">
            <div className="flex justify-between text-xs text-gray-500 mb-1">
              <span>
                {dataIsLive
                  ? `${formatKwh(producedKwh, 1)} kWh so far`
                  : "Waiting for live yield"}
              </span>
              <span>
                {estimate.remainingKwh > 0.05
                  ? `${formatKwh(estimate.remainingKwh, 1)} kWh remaining`
                  : "day complete"}
              </span>
            </div>
            <div className="h-2 bg-gray-800 rounded-full overflow-hidden">
              <div
                className="h-full bg-amber-500 rounded-full transition-all duration-1000"
                style={{ width: `${progress}%` }}
              />
            </div>
          </div>
        </div>
        <div className="space-y-1 text-sm text-gray-400">
          <p>
            Clear-sky season potential{" "}
            <span className="font-mono text-gray-200">{formatKwh(estimate.clearSkyKwh)} kWh</span>
            {cloudCut > 3 && (
              <>
                {" "}
                · clouds cut ~{cloudCut}%
              </>
            )}
          </p>
          {yest ? (
            <p>
              {yest.isCalendarYesterday ? "Yesterday" : format(parseISO(yest.date), "d MMM")}{" "}
              delivered {formatKwh(yest.yieldKwh)} kWh at {formatKwh(yest.ghiKwhM2)} kWh/m²
              {yestDelta !== 0 && (
                <>
                  {" "}
                  · site ran {yestDelta > 0 ? "+" : ""}
                  {yestDelta}% vs model, applied to today
                </>
              )}
            </p>
          ) : (
            <p>No previous yield yet — estimate uses array peak and today&apos;s sun/weather.</p>
          )}
        </div>
      </div>

      {chartData.length > 4 && dataIsLive && (
        <div>
          <p className="text-xs text-gray-600 mb-2">Expected vs observed power</p>
          <ResponsiveContainer width="100%" height={160}>
            <AreaChart data={chartData}>
              <defs>
                <linearGradient id="forecastGrad" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%" stopColor="#f59e0b" stopOpacity={0.25} />
                  <stop offset="95%" stopColor="#f59e0b" stopOpacity={0} />
                </linearGradient>
              </defs>
              <CartesianGrid strokeDasharray="3 3" stroke="#1f2937" />
              <XAxis dataKey="hour" tick={{ fill: "#6b7280", fontSize: 11 }} interval={2} />
              <YAxis tick={{ fill: "#6b7280", fontSize: 11 }} unit=" W" width={48} />
              <Tooltip
                contentStyle={{
                  backgroundColor: "#111827",
                  border: "1px solid #374151",
                  borderRadius: "8px",
                }}
                formatter={(value) => [`${Number(value ?? 0)} W`]}
              />
              <Area
                type="monotone"
                dataKey="expected"
                name="Expected"
                stroke="#78716c"
                fill="url(#forecastGrad)"
                strokeDasharray="4 3"
              />
              <Area
                type="monotone"
                dataKey="actual"
                name="Observed"
                stroke="#f59e0b"
                fill="none"
                strokeWidth={2}
                connectNulls={false}
              />
            </AreaChart>
          </ResponsiveContainer>
        </div>
      )}

      <div className="grid grid-cols-7 gap-1">
        {forecast.days.map((day) => {
          const info = weatherInfo(day.weatherCode);
          const isToday = day.date === forecast.todayIso;
          return (
            <div
              key={day.date}
              className={`rounded-xl px-1 py-2 text-center ${
                isToday ? "bg-amber-950/40 border border-amber-800/40" : "bg-gray-950/50"
              }`}
            >
              <div className="text-[10px] uppercase tracking-wide text-gray-500">
                {isToday ? "Today" : format(parseISO(day.date), "EEE")}
              </div>
              <WeatherGlyph code={day.weatherCode} label={info.label} />
              <div className="font-mono text-xs text-amber-300 mt-1">
                {formatKwh(day.estimatedKwh, 1)}
              </div>
              <div className="text-[10px] text-gray-600">{Math.round(day.tempMax)}°</div>
              {day.precipMm >= 0.4 && (
                <div className="text-[10px] text-sky-500">{day.precipMm.toFixed(0)} mm</div>
              )}
            </div>
          );
        })}
      </div>

      {forecast.days[0] && (
        <p className="text-[11px] text-gray-600">
          Sunrise {sunClock(forecast.days[0].sunrise)} · sunset {sunClock(forecast.days[0].sunset)}
          {forecast.days[0].uvIndex > 0 && <> · UV {forecast.days[0].uvIndex.toFixed(0)}</>}
        </p>
      )}
    </section>
  );
}
