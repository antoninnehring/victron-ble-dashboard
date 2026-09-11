import { loadSiteLocation, persistSiteLocation } from "@/lib/victron-config";

export type LocationSource = "query" | "env" | "config" | "ip";

export interface SiteLocation {
  lat: number;
  lon: number;
  label: string | null;
  source: LocationSource;
}

interface IpGeoResult {
  lat: number;
  lon: number;
  label: string | null;
}

const IP_GEO_TTL_MS = 24 * 60 * 60 * 1000;
let ipGeoCache: { value: IpGeoResult; at: number } | null = null;

function parseNumber(raw: string | null | undefined): number | null {
  if (raw == null || raw.trim() === "") return null;
  const n = Number(raw);
  return Number.isFinite(n) ? n : null;
}

export function validCoords(lat: number, lon: number) {
  return Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180;
}

function formatLabel(city?: string | null, country?: string | null): string | null {
  const c = (city ?? "").trim();
  const cc = (country ?? "").trim();
  if (c && cc) return `${c}, ${cc}`;
  if (c) return c;
  if (cc) return cc;
  return null;
}

async function fetchJson(url: string): Promise<Record<string, unknown> | null> {
  try {
    const res = await fetch(url, {
      cache: "no-store",
      signal: AbortSignal.timeout(4000),
      headers: { Accept: "application/json" },
    });
    if (!res.ok) return null;
    const json = (await res.json()) as unknown;
    if (!json || typeof json !== "object") return null;
    return json as Record<string, unknown>;
  } catch {
    return null;
  }
}

function fromIpApi(data: Record<string, unknown>): IpGeoResult | null {
  if (data.status === "fail") return null;
  const lat = Number(data.lat);
  const lon = Number(data.lon);
  if (!validCoords(lat, lon)) return null;
  const country = String(data.countryCode ?? data.country ?? "").trim();
  return { lat, lon, label: formatLabel(String(data.city ?? ""), country) };
}

function fromIpapiCo(data: Record<string, unknown>): IpGeoResult | null {
  if (data.error) return null;
  const lat = Number(data.latitude);
  const lon = Number(data.longitude);
  if (!validCoords(lat, lon)) return null;
  const country = String(data.country_code ?? data.country ?? "").trim();
  return { lat, lon, label: formatLabel(String(data.city ?? ""), country) };
}

function fromIpinfo(data: Record<string, unknown>): IpGeoResult | null {
  const loc = String(data.loc ?? "");
  const [latRaw, lonRaw] = loc.split(",");
  const lat = Number(latRaw);
  const lon = Number(lonRaw);
  if (!validCoords(lat, lon)) return null;
  const country = String(data.country ?? "").trim();
  return { lat, lon, label: formatLabel(String(data.city ?? ""), country) };
}

async function lookupPublicIpLocation(): Promise<IpGeoResult | null> {
  if (ipGeoCache && Date.now() - ipGeoCache.at < IP_GEO_TTL_MS) {
    return ipGeoCache.value;
  }

  const attempts: Array<() => Promise<IpGeoResult | null>> = [
    async () => {
      const data = await fetchJson("http://ip-api.com/json/?fields=status,lat,lon,city,countryCode");
      return data ? fromIpApi(data) : null;
    },
    async () => {
      const data = await fetchJson("https://ipapi.co/json/");
      return data ? fromIpapiCo(data) : null;
    },
    async () => {
      const data = await fetchJson("https://ipinfo.io/json");
      return data ? fromIpinfo(data) : null;
    },
  ];

  for (const attempt of attempts) {
    const result = await attempt();
    if (result) {
      ipGeoCache = { value: result, at: Date.now() };
      return result;
    }
  }
  return null;
}

export async function resolveSiteLocation(
  qLat: number | null,
  qLon: number | null,
): Promise<SiteLocation | null> {
  const stored = loadSiteLocation();

  if (qLat != null && qLon != null && validCoords(qLat, qLon)) {
    return { lat: qLat, lon: qLon, label: stored?.label ?? null, source: "query" };
  }

  const envLat = parseNumber(process.env.SITE_LAT);
  const envLon = parseNumber(process.env.SITE_LON);
  if (envLat != null && envLon != null && validCoords(envLat, envLon)) {
    return { lat: envLat, lon: envLon, label: stored?.label ?? null, source: "env" };
  }

  if (stored && validCoords(stored.lat, stored.lon)) {
    return { lat: stored.lat, lon: stored.lon, label: stored.label, source: "config" };
  }

  const ip = await lookupPublicIpLocation();
  if (!ip) return null;
  try {
    persistSiteLocation(ip.lat, ip.lon, ip.label);
  } catch {
    // Forecast still works from the in-memory cache.
  }
  return { lat: ip.lat, lon: ip.lon, label: ip.label, source: "ip" };
}
