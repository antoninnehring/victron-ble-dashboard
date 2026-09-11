export interface Observation {
  date: string;
  yieldKwh: number;
  ghiKwhM2: number;
}

export interface HourlyPoint {
  time: string;
  hour: number;
  ghiWm2: number;
  cloudCover: number;
  expectedW: number;
}

export interface DayWeather {
  date: string;
  weatherCode: number;
  tempMax: number;
  tempMin: number;
  sunshineHours: number;
  daylightHours: number;
  precipMm: number;
  uvIndex: number;
  sunrise: string;
  sunset: string;
  ghiKwhM2: number;
  estimatedKwh: number;
  clearSkyKwh: number;
}

export interface SolarEstimate {
  todayKwh: number;
  remainingKwh: number;
  producedKwh: number;
  clearSkyKwh: number;
  weatherKwh: number;
  cloudFactor: number;
  apertureM2: number;
  yesterday: {
    date: string;
    yieldKwh: number;
    ghiKwhM2: number;
    isCalendarYesterday: boolean;
    factor: number;
  } | null;
  season: string;
  noonAltitudeDeg: number;
  daylightHours: number;
}

export function mjToKwhM2(mj: number): number {
  return mj / 3.6;
}

export function dayOfYear(isoDate: string): number {
  const [y, m, d] = isoDate.split("-").map(Number);
  const date = new Date(Date.UTC(y, m - 1, d));
  const start = Date.UTC(y, 0, 0);
  return Math.floor((date.getTime() - start) / 86_400_000);
}

export function solarDeclinationDeg(doy: number): number {
  return 23.45 * Math.sin(((2 * Math.PI) / 365) * (doy - 81));
}

export function solarNoonAltitudeDeg(latitude: number, declination: number): number {
  return 90 - Math.abs(latitude - declination);
}

export function meteorologicalSeason(isoDate: string, latitude: number): string {
  const month = Number(isoDate.slice(5, 7));
  const northern = latitude >= 0;
  const bucket =
    month === 12 || month <= 2
      ? 0
      : month <= 5
        ? 1
        : month <= 8
          ? 2
          : 3;
  const names = northern
    ? ["Winter", "Spring", "Summer", "Autumn"]
    : ["Summer", "Autumn", "Winter", "Spring"];
  return names[bucket];
}

function toRad(deg: number): number {
  return (deg * Math.PI) / 180;
}

export function cosSolarZenith(
  latDeg: number,
  declDeg: number,
  hourAngleDeg: number,
): number {
  const lat = toRad(latDeg);
  const decl = toRad(declDeg);
  const ha = toRad(hourAngleDeg);
  return Math.sin(lat) * Math.sin(decl) + Math.cos(lat) * Math.cos(decl) * Math.cos(ha);
}

/** Haurwitz clear-sky GHI in W/m². */
export function haurwitzClearSkyWm2(cosZenith: number): number {
  if (cosZenith <= 0.001) return 0;
  return 1098 * cosZenith * Math.exp(-0.057 / cosZenith);
}

export function clearSkyDayKwhM2(latitude: number, isoDate: string): number {
  const decl = solarDeclinationDeg(dayOfYear(isoDate));
  let wh = 0;
  for (let h = 0; h < 24; h += 0.25) {
    const cosZ = cosSolarZenith(latitude, decl, 15 * (h - 12));
    wh += haurwitzClearSkyWm2(cosZ) * 0.25;
  }
  return wh / 1000;
}

function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1
    ? sorted[mid]
    : (sorted[mid - 1] + sorted[mid]) / 2;
}

/** Effective aperture: kWh out per kWh/m² of GHI. */
export function siteApertureM2(observations: Observation[]): number | null {
  const ratios = observations
    .filter((o) => o.ghiKwhM2 >= 0.4 && o.yieldKwh >= 0.05)
    .map((o) => o.yieldKwh / o.ghiKwhM2);
  return median(ratios);
}

export function fallbackApertureM2(peakWatts: number): number {
  const kwp = Math.max(peakWatts, 80) / 1000 / 0.85;
  return kwp * 0.8;
}

function clamp(n: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, n));
}

function addDaysISO(isoDate: string, days: number): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  const date = new Date(Date.UTC(y, m - 1, d + days));
  return date.toISOString().slice(0, 10);
}

export function previousIsoDate(isoDate: string): string {
  return addDaysISO(isoDate, -1);
}

export function buildEstimate(opts: {
  todayIso: string;
  latitude: number;
  todayGhiKwhM2: number;
  producedKwh: number;
  expectedToNowKwh: number;
  remainingForecastKwh: number;
  observations: Observation[];
  peakWatts: number;
  daylightHours: number;
  liveToday: boolean;
}): SolarEstimate {
  const {
    todayIso,
    latitude,
    todayGhiKwhM2,
    producedKwh,
    remainingForecastKwh,
    observations,
    peakWatts,
    daylightHours,
  } = opts;

  const historyAperture = siteApertureM2(observations);
  const aperture = historyAperture ?? fallbackApertureM2(peakWatts);
  const weatherKwh = aperture * todayGhiKwhM2;
  const clearSkyKwh = aperture * clearSkyDayKwhM2(latitude, todayIso);

  const last = [...observations].sort((a, b) => a.date.localeCompare(b.date)).at(-1) ?? null;
  let calibratedFullDay = weatherKwh;
  let yesterday: SolarEstimate["yesterday"] = null;

  if (last && last.ghiKwhM2 > 0.2) {
    const fromLastDay = last.yieldKwh * (todayGhiKwhM2 / last.ghiKwhM2);
    const ageDays =
      (Date.parse(`${todayIso}T00:00:00Z`) - Date.parse(`${last.date}T00:00:00Z`)) /
      86_400_000;
    const yesterdayWeight = ageDays <= 1.5 ? 0.75 : ageDays <= 3 ? 0.5 : 0.25;
    calibratedFullDay = yesterdayWeight * fromLastDay + (1 - yesterdayWeight) * weatherKwh;
    const expectedLast = aperture * last.ghiKwhM2;
    yesterday = {
      date: last.date,
      yieldKwh: last.yieldKwh,
      ghiKwhM2: last.ghiKwhM2,
      isCalendarYesterday: last.date === previousIsoDate(todayIso),
      factor: expectedLast > 0.05 ? last.yieldKwh / expectedLast : 1,
    };
  }

  if (clearSkyKwh > 0.2) {
    calibratedFullDay = clamp(calibratedFullDay, clearSkyKwh * 0.08, clearSkyKwh * 1.15);
  }

  const weatherFull = opts.expectedToNowKwh + remainingForecastKwh;
  const remainingScale = weatherFull > 0.05 ? calibratedFullDay / weatherFull : 1;
  const scaledRemaining = Math.max(0, remainingForecastKwh * remainingScale);
  const dayUnderway =
    opts.liveToday && (producedKwh > 0.02 || opts.expectedToNowKwh > 0.05);
  const remainingKwh = dayUnderway ? scaledRemaining : calibratedFullDay;
  const todayKwh = dayUnderway ? producedKwh + scaledRemaining : calibratedFullDay;

  const noonAltitudeDeg = solarNoonAltitudeDeg(
    latitude,
    solarDeclinationDeg(dayOfYear(todayIso)),
  );

  return {
    todayKwh,
    remainingKwh,
    producedKwh,
    clearSkyKwh,
    weatherKwh,
    cloudFactor: clearSkyKwh > 0 ? clamp(weatherKwh / clearSkyKwh, 0, 1.2) : 1,
    apertureM2: aperture,
    yesterday,
    season: meteorologicalSeason(todayIso, latitude),
    noonAltitudeDeg,
    daylightHours,
  };
}

export function weatherInfo(code: number): { icon: string; label: string } {
  if (code === 0) return { icon: "☀️", label: "Clear" };
  if (code === 1) return { icon: "🌤️", label: "Mostly clear" };
  if (code === 2) return { icon: "⛅", label: "Partly cloudy" };
  if (code === 3) return { icon: "☁️", label: "Overcast" };
  if (code === 45 || code === 48) return { icon: "🌫️", label: "Fog" };
  if (code >= 51 && code <= 57) return { icon: "🌦️", label: "Drizzle" };
  if (code >= 61 && code <= 67) return { icon: "🌧️", label: "Rain" };
  if (code >= 71 && code <= 77) return { icon: "🌨️", label: "Snow" };
  if (code >= 80 && code <= 82) return { icon: "🌦️", label: "Showers" };
  if (code >= 85 && code <= 86) return { icon: "🌨️", label: "Snow showers" };
  if (code >= 95) return { icon: "⛈️", label: "Thunderstorm" };
  return { icon: "🌡️", label: "—" };
}

export function todayIsoInZone(timeZone: string, now = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
}

export function currentHourInZone(timeZone: string, now = new Date()): number {
  return Number(
    new Intl.DateTimeFormat("en-GB", {
      timeZone,
      hour: "numeric",
      hourCycle: "h23",
    }).format(now),
  );
}
