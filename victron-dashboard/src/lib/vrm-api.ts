// Types for the BLE-based Victron data.
// Instant Readout is a live snapshot; dailyStats are days this Mac observed.

export interface DeviceInfo {
  address: string;
  name?: string;
  last_seen: number;
  fields?: string[];
  type?: string;
  typeLabel?: string;
  model?: string;
  summary?: string;
}

export interface SystemOverview {
  battery: {
    soc: number;
    voltage: number;
    current: number;
    power: number;
    state: string;
    temperature: number;
    consumed_ah: number;
    remaining_mins: number;
    starter_voltage?: number;
    midpoint_voltage?: number;
    aux_mode?: string;
  };
  solar: {
    power: number;
    yieldToday: number;
    loadA?: number;
  };
  inverter: {
    ac_power: number;
    ac_in_power?: number;
    ac_in_state?: string;
    state?: string;
    ac_voltage?: number;
    ac_current?: number;
    ac_apparent_power?: number;
  };
  dcdc?: {
    power?: number;
    input_voltage?: number;
    output_voltage?: number;
    output_current?: number;
    input_current?: number;
    state?: string;
  };
  alarm: string;
  devices: Record<string, DeviceInfo>;
}

export interface DailyStats {
  date: string;
  solarYield: number;
  solarPeakPower: number;
  batterySOCMin: number;
  batterySOCMax: number;
  samples: number;
  chargedAh?: number;
  dischargedAh?: number;
  dcdcAh?: number;
  acInWh?: number;
  acOutWh?: number;
}

export interface TimePoint {
  t: string;
  solar: number;
  current: number;
  soc: number;
  acOut?: number;
  dcdcW?: number;
  yield?: number;
}

export type { SameHourCompare } from "./same-hour";

export interface HistoryMeta {
  source?: string;
  label?: string;
  not?: string;
  days?: number;
}

export interface Alert {
  id: string;
  level: "info" | "warning" | "critical";
  title: string;
  message: string;
  timestamp: number;
}

export type RawDeviceSnapshot = {
  type?: string;
  typeLabel?: string;
  model?: string;
  summary?: string;
  solar?: Record<string, number>;
  battery?: Record<string, number | string>;
  inverter?: Record<string, number | string>;
  dcdc?: Record<string, number | string>;
  charger?: Record<string, number | string>;
  lithium?: Record<string, unknown>;
  protect?: Record<string, number | string>;
  meter?: Record<string, number | string>;
  sense?: Record<string, number>;
  alarm?: string;
  chargerError?: string;
  fields?: Record<string, unknown>;
  [key: string]: unknown;
};
