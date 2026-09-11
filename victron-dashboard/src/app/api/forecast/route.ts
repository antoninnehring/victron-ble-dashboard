import { NextResponse } from "next/server";
import { readFileSync } from "fs";
import { join } from "path";
import { whToKwh } from "@/lib/energy";
import { resolveSiteLocation } from "@/lib/site-location";
import {
  buildEstimate,
  clearSkyDayKwhM2,
  currentHourInZone,
  fallbackApertureM2,
  mjToKwhM2,
  siteApertureM2,
  todayIsoInZone,
  type DayWeather,
  type HourlyPoint,
  type Observation,
} from "@/lib/solar-forecast";

export const dynamic = "force-dynamic";

interface BLESnapshot {
  lastUpdated?: number;
  overview?: { solar?: { yieldToday?: number; power?: number } };
  dailyStats?: { date: string; solarYield: number; solarPeakPower: number }[];
}

interface OpenMeteoResponse {
  latitude: number;
  longitude: number;
  timezone: string;
  daily: {
    time: string[];
    weather_code: number[];
    temperature_2m_max: number[];
    temperature_2m_min: number[];
    sunrise: string[];
    sunset: string[];
    daylight_duration: number[];
    sunshine_duration: number[];
    uv_index_max: number[];
    shortwave_radiation_sum: number[];
    precipitation_sum: number[];
  };
  hourly: {
    time: string[];
    shortwave_radiation: number[];
    cloud_cover: number[];
  };
}

function parseNumber(raw: string | null): number | null {
  if (raw == null || raw.trim() === "") return null;
  const n = Number(raw);
  return Number.isFinite(n) ? n : null;
}

function readBle(): BLESnapshot {
  try {
    const raw = readFileSync(join(process.cwd(), "ble-data.json"), "utf-8");
    return JSON.parse(raw) as BLESnapshot;
  } catch {
    return {};
  }
}

async function fetchWeather(lat: number, lon: number): Promise<OpenMeteoResponse> {
  const params = new URLSearchParams({
    latitude: lat.toFixed(4),
    longitude: lon.toFixed(4),
    timezone: "auto",
    past_days: "14",
    forecast_days: "7",
    daily: [
      "weather_code",
      "temperature_2m_max",
      "temperature_2m_min",
      "sunrise",
      "sunset",
      "daylight_duration",
      "sunshine_duration",
      "uv_index_max",
      "shortwave_radiation_sum",
      "precipitation_sum",
    ].join(","),
    hourly: "shortwave_radiation,cloud_cover",
  });

  const res = await fetch(`https://api.open-meteo.com/v1/forecast?${params}`, {
    next: { revalidate: 1800 },
  });
  if (!res.ok) {
    throw new Error(`Weather request failed (${res.status})`);
  }
  return res.json() as Promise<OpenMeteoResponse>;
}

export async function GET(request: Request) {
  const url = new URL(request.url);
  const qLat = parseNumber(url.searchParams.get("lat"));
  const qLon = parseNumber(url.searchParams.get("lon"));
  const site = await resolveSiteLocation(qLat, qLon);
  if (!site) {
    return NextResponse.json({
      needsLocation: true,
      message: "Could not resolve site location. Set SITE_LAT and SITE_LON in .env.local or victron-config.json.",
    });
  }

  const lat = site.lat;
  const lon = site.lon;
  const locationSource = site.source;

  try {
    const weather = await fetchWeather(lat, lon);
    const ble = readBle();
    const timeZone = weather.timezone;
    const todayIso = todayIsoInZone(timeZone);
    const hourNow = currentHourInZone(timeZone);

    const ghiByDate = new Map<string, number>();
    weather.daily.time.forEach((date, i) => {
      ghiByDate.set(date, mjToKwhM2(weather.daily.shortwave_radiation_sum[i] ?? 0));
    });

    const dailyStats = ble.dailyStats ?? [];
    const envCapacity = parseNumber(process.env.SITE_CAPACITY_W ?? null);
    const inferredPeak = Math.max(
      0,
      ...dailyStats.map((d) => d.solarPeakPower || 0),
      ble.overview?.solar?.power ?? 0,
    );
    const peakWatts =
      envCapacity != null && envCapacity > 0 ? envCapacity : inferredPeak;

    const observations: Observation[] = dailyStats
      .filter((d) => d.date < todayIso)
      .map((d) => ({
        date: d.date,
        yieldKwh: whToKwh(d.solarYield),
        ghiKwhM2: ghiByDate.get(d.date) ?? 0,
      }))
      .filter((o) => o.ghiKwhM2 > 0);

    const aperture = siteApertureM2(observations) ?? fallbackApertureM2(peakWatts);

    const hourly: HourlyPoint[] = [];
    let expectedToNowKwh = 0;
    let remainingForecastKwh = 0;

    weather.hourly.time.forEach((time, i) => {
      if (!time.startsWith(todayIso)) return;
      const hour = Number(time.slice(11, 13));
      const ghiWm2 = weather.hourly.shortwave_radiation[i] ?? 0;
      const expectedW = ghiWm2 * aperture;
      const kwh = expectedW / 1000;
      if (hour < hourNow) expectedToNowKwh += kwh;
      else remainingForecastKwh += kwh;
      hourly.push({
        time,
        hour,
        ghiWm2,
        cloudCover: weather.hourly.cloud_cover[i] ?? 0,
        expectedW,
      });
    });

    const liveToday =
      typeof ble.lastUpdated === "number" &&
      todayIsoInZone(timeZone, new Date(ble.lastUpdated)) === todayIso;
    const producedKwh = liveToday ? whToKwh(ble.overview?.solar?.yieldToday ?? 0) : 0;
    const todayIdx = weather.daily.time.indexOf(todayIso);
    const todayGhi = ghiByDate.get(todayIso) ?? 0;
    const daylightHours =
      todayIdx >= 0 ? (weather.daily.daylight_duration[todayIdx] ?? 0) / 3600 : 0;

    const estimate = buildEstimate({
      todayIso,
      latitude: weather.latitude,
      todayGhiKwhM2: todayGhi,
      producedKwh,
      expectedToNowKwh,
      remainingForecastKwh,
      observations,
      peakWatts,
      daylightHours,
      liveToday,
    });

    const scale = aperture > 0 ? estimate.apertureM2 / aperture : 1;
    const hourlyScaled = hourly.map((h) => ({
      ...h,
      expectedW: h.expectedW * scale,
    }));

    const persist =
      estimate.yesterday != null
        ? Math.min(1.25, Math.max(0.7, 0.5 + 0.5 * estimate.yesterday.factor))
        : 1;

    const days: DayWeather[] = weather.daily.time
      .map((date, i) => {
        const ghiKwhM2 = ghiByDate.get(date) ?? 0;
        const estimatedKwh =
          date === todayIso ? estimate.todayKwh : estimate.apertureM2 * ghiKwhM2 * persist;
        return {
          date,
          weatherCode: weather.daily.weather_code[i] ?? 0,
          tempMax: weather.daily.temperature_2m_max[i] ?? 0,
          tempMin: weather.daily.temperature_2m_min[i] ?? 0,
          sunshineHours: (weather.daily.sunshine_duration[i] ?? 0) / 3600,
          daylightHours: (weather.daily.daylight_duration[i] ?? 0) / 3600,
          precipMm: weather.daily.precipitation_sum[i] ?? 0,
          uvIndex: weather.daily.uv_index_max[i] ?? 0,
          sunrise: weather.daily.sunrise[i] ?? "",
          sunset: weather.daily.sunset[i] ?? "",
          ghiKwhM2,
          estimatedKwh,
          clearSkyKwh: estimate.apertureM2 * clearSkyDayKwhM2(weather.latitude, date),
        };
      })
      .filter((d) => d.date >= todayIso)
      .slice(0, 7);

    return NextResponse.json({
      needsLocation: false,
      location: {
        latitude: weather.latitude,
        longitude: weather.longitude,
        timezone: timeZone,
        label: site.label,
        source: locationSource,
      },
      todayIso,
      estimate,
      days,
      hourly: hourlyScaled,
      observedPeakW: peakWatts,
    });
  } catch (err) {
    return NextResponse.json(
      { error: "forecast-failed", message: err instanceof Error ? err.message : String(err) },
      { status: 502 },
    );
  }
}
