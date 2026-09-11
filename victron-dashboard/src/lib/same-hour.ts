/** Compare solar yield at the same clock time, not full-day vs morning-so-far. */

export const MAX_SAMPLE_AGE_MIN = 60;
export const MAX_INTEGRATION_GAP_MIN = 30;
export const MIN_COMPARE_WH = 50;
export const MIN_WEEK_DAYS = 3;

export interface SameHourPoint {
  t: string;
  solar?: number;
  yield?: number;
}

export interface SameHourDay {
  timeseries?: SameHourPoint[];
  solar_yield_max?: number;
}

export type HistoryDays = Record<string, SameHourDay>;

export interface SameHourCompare {
  clock: string;
  todayWh: number;
  yesterdayWh: number | null;
  yesterdayAt: string | null;
  diffPercent: number | null;
  available: boolean;
  weekAvgWh: number | null;
  weekDiffPercent: number | null;
  weekDays: number;
  recordWh: number | null;
  isRecord: boolean;
}

export function parseMinutes(t: string): number | null {
  const match = /^(\d{1,2}):(\d{2})/.exec(t);
  if (!match) return null;
  return Number(match[1]) * 60 + Number(match[2]);
}

export function localIsoDate(d = new Date()): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

export function localClock(d = new Date()): string {
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

export function integrateSolarWh(points: SameHourPoint[]): number | null {
  if (points.length < 2) return null;
  let total = 0;
  let used = 0;
  for (let i = 1; i < points.length; i++) {
    const t0 = parseMinutes(points[i - 1].t);
    const t1 = parseMinutes(points[i].t);
    if (t0 == null || t1 == null) continue;
    const dtMin = t1 - t0;
    if (dtMin <= 0 || dtMin > MAX_INTEGRATION_GAP_MIN) continue;
    const w0 = points[i - 1].solar ?? 0;
    const w1 = points[i].solar ?? 0;
    total += ((w0 + w1) / 2) * (dtMin / 60);
    used += 1;
  }
  return used === 0 ? null : total;
}

export function yieldAtClock(
  day: SameHourDay | undefined,
  clock: string,
): { wh: number; at: string } | null {
  if (!day) return null;
  const clockM = parseMinutes(clock);
  if (clockM == null) return null;
  const eligible = (day.timeseries ?? []).filter((point) => {
    const minutes = parseMinutes(point.t);
    return minutes != null && minutes <= clockM;
  });
  if (eligible.length === 0) return null;
  const last = eligible[eligible.length - 1];
  const lastM = parseMinutes(last.t);
  if (lastM == null || clockM - lastM > MAX_SAMPLE_AGE_MIN) return null;
  if (typeof last.yield === "number" && Number.isFinite(last.yield)) {
    return { wh: last.yield, at: last.t };
  }
  const integrated = integrateSolarWh(eligible);
  if (integrated == null) return null;
  return { wh: integrated, at: last.t };
}

function pctDiff(todayWh: number, otherWh: number): number | null {
  if (otherWh < MIN_COMPARE_WH) return null;
  return ((todayWh - otherWh) / otherWh) * 100;
}

function shiftIsoDate(iso: string, days: number): string {
  const [y, m, d] = iso.split("-").map(Number);
  const dt = new Date(y, m - 1, d);
  dt.setDate(dt.getDate() + days);
  return localIsoDate(dt);
}

export function computeSameHour(opts: {
  days: HistoryDays;
  todayIso: string;
  clock: string;
  todayWh: number;
}): SameHourCompare {
  const { days, todayIso, clock } = opts;
  const todayWh = opts.todayWh || 0;
  const yesterdayIso = shiftIsoDate(todayIso, -1);
  const yHit = yieldAtClock(days[yesterdayIso], clock);
  const yesterdayWh = yHit?.wh ?? null;
  const yesterdayAt = yHit?.at ?? null;
  const diff = yesterdayWh != null ? pctDiff(todayWh, yesterdayWh) : null;

  const allPrior = Object.keys(days)
    .filter((d) => d < todayIso)
    .sort();
  const weekDates = new Set(allPrior.slice(-7));
  const recordYields: number[] = [];
  const weekYields: number[] = [];
  for (const dayIso of allPrior) {
    const hit = yieldAtClock(days[dayIso], clock);
    if (!hit || hit.wh < MIN_COMPARE_WH) continue;
    recordYields.push(hit.wh);
    if (weekDates.has(dayIso)) weekYields.push(hit.wh);
  }
  const weekAvg =
    weekYields.length >= MIN_WEEK_DAYS
      ? weekYields.reduce((s, v) => s + v, 0) / weekYields.length
      : null;
  const weekDiff = weekAvg != null ? pctDiff(todayWh, weekAvg) : null;
  const recordWh = recordYields.length ? Math.max(...recordYields) : null;
  const isRecord =
    recordWh != null &&
    recordYields.length >= 2 &&
    todayWh >= MIN_COMPARE_WH &&
    todayWh > recordWh;

  return {
    clock,
    todayWh: Math.round(todayWh * 10) / 10,
    yesterdayWh: yesterdayWh != null ? Math.round(yesterdayWh * 10) / 10 : null,
    yesterdayAt,
    diffPercent: diff != null ? Math.round(diff * 10) / 10 : null,
    available: diff != null,
    weekAvgWh: weekAvg != null ? Math.round(weekAvg * 10) / 10 : null,
    weekDiffPercent: weekDiff != null ? Math.round(weekDiff * 10) / 10 : null,
    weekDays: weekAvg != null ? weekYields.length : 0,
    recordWh: recordWh != null ? Math.round(recordWh * 10) / 10 : null,
    isRecord,
  };
}

export function formatWh(wh: number): string {
  if (wh >= 1000) return `${(wh / 1000).toFixed(2)} kWh`;
  return `${Math.round(wh)} Wh`;
}
