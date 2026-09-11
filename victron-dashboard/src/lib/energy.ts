/** Victron BLE reports solar yield in watt-hours. */
export function whToKwh(wh: number): number {
  return wh / 1000;
}

export function formatKwh(kwh: number, digits?: number): string {
  const d = digits ?? (Math.abs(kwh) >= 10 ? 1 : 2);
  return kwh.toFixed(d);
}
