// Types for the BLE-based Victron data

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
  };
  solar: {
    power: number;
    yieldToday: number;
  };
  inverter: {
    ac_power: number;
  };
  alarm: string;
  devices: Record<string, { address: string; last_seen: number; fields: string[] }>;
}

export interface DailyStats {
  date: string;
  solarYield: number;
  solarPeakPower: number;
  batterySOCMin: number;
  batterySOCMax: number;
  samples: number;
}

export interface TimePoint {
  t: string;
  solar: number;
  current: number;
  soc: number;
}

export interface Alert {
  id: string;
  level: "info" | "warning" | "critical";
  title: string;
  message: string;
  timestamp: number;
}
