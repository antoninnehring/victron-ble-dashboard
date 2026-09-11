"""Compare solar yield at the same clock time, not full-day vs morning-so-far."""

from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Any

MAX_SAMPLE_AGE_MIN = 60
MAX_INTEGRATION_GAP_MIN = 30
MIN_COMPARE_WH = 50
MIN_WEEK_DAYS = 3


def parse_minutes(t: str) -> int | None:
    if not t or ":" not in str(t):
        return None
    try:
        parts = str(t).split(":")
        return int(parts[0]) * 60 + int(parts[1])
    except (ValueError, IndexError):
        return None


def clock_now() -> str:
    return datetime.now().strftime("%H:%M")


def integrate_solar_wh(points: list[dict]) -> float | None:
    """Watt-hour integral of solar watts. Skips gaps longer than 30 minutes."""
    if len(points) < 2:
        return None
    total = 0.0
    used = 0
    for i in range(1, len(points)):
        t0 = parse_minutes(points[i - 1].get("t") or "")
        t1 = parse_minutes(points[i].get("t") or "")
        if t0 is None or t1 is None:
            continue
        dt_min = t1 - t0
        if dt_min <= 0 or dt_min > MAX_INTEGRATION_GAP_MIN:
            continue
        w0 = points[i - 1].get("solar") or 0
        w1 = points[i].get("solar") or 0
        total += (float(w0) + float(w1)) / 2.0 * (dt_min / 60.0)
        used += 1
    if used == 0:
        return None
    return total


def yield_at_clock(day: dict | None, clock: str) -> tuple[float, str] | None:
    """Yield by `clock` for a history day, or None if that morning was not sampled."""
    if not day:
        return None
    clock_m = parse_minutes(clock)
    if clock_m is None:
        return None
    eligible: list[dict] = []
    for point in day.get("timeseries") or []:
        minutes = parse_minutes(point.get("t") or "")
        if minutes is not None and minutes <= clock_m:
            eligible.append(point)
    if not eligible:
        return None
    last = eligible[-1]
    last_m = parse_minutes(last.get("t") or "")
    if last_m is None or clock_m - last_m > MAX_SAMPLE_AGE_MIN:
        return None
    snapped = last.get("yield")
    if isinstance(snapped, (int, float)):
        return (float(snapped), last["t"])
    integrated = integrate_solar_wh(eligible)
    if integrated is None:
        return None
    return (integrated, last["t"])


def pct_diff(today_wh: float, other_wh: float) -> float | None:
    if other_wh < MIN_COMPARE_WH:
        return None
    return ((today_wh - other_wh) / other_wh) * 100.0


def compute_same_hour(
    history_days: dict[str, dict],
    *,
    today_iso: str | None = None,
    clock: str | None = None,
    today_wh: float | None = None,
) -> dict[str, Any]:
    today_iso = today_iso or date.today().isoformat()
    clock = clock or clock_now()
    today_day = history_days.get(today_iso) or {}
    if today_wh is None:
        today_wh = float(today_day.get("solar_yield_max") or 0)
    today_wh = float(today_wh or 0)

    yesterday_iso = (date.fromisoformat(today_iso) - timedelta(days=1)).isoformat()
    y_hit = yield_at_clock(history_days.get(yesterday_iso), clock)
    yesterday_wh = y_hit[0] if y_hit else None
    yesterday_at = y_hit[1] if y_hit else None
    diff = pct_diff(today_wh, yesterday_wh) if yesterday_wh is not None else None

    all_prior = sorted(d for d in history_days if d < today_iso)
    week_dates = set(all_prior[-7:])
    record_yields: list[float] = []
    week_yields: list[float] = []
    for day_iso in all_prior:
        hit = yield_at_clock(history_days.get(day_iso), clock)
        if not hit or hit[0] < MIN_COMPARE_WH:
            continue
        record_yields.append(hit[0])
        if day_iso in week_dates:
            week_yields.append(hit[0])
    week_avg = sum(week_yields) / len(week_yields) if len(week_yields) >= MIN_WEEK_DAYS else None
    week_diff = pct_diff(today_wh, week_avg) if week_avg is not None else None
    record_wh = max(record_yields) if record_yields else None
    is_record = (
        record_wh is not None
        and len(record_yields) >= 2
        and today_wh >= MIN_COMPARE_WH
        and today_wh > record_wh
    )

    return {
        "clock": clock,
        "todayWh": round(today_wh, 1),
        "yesterdayWh": round(yesterday_wh, 1) if yesterday_wh is not None else None,
        "yesterdayAt": yesterday_at,
        "diffPercent": round(diff, 1) if diff is not None else None,
        "available": diff is not None,
        "weekAvgWh": round(week_avg, 1) if week_avg is not None else None,
        "weekDiffPercent": round(week_diff, 1) if week_diff is not None else None,
        "weekDays": len(week_yields) if week_avg is not None else 0,
        "recordWh": round(record_wh, 1) if record_wh is not None else None,
        "isRecord": is_record,
    }
