"use client";

import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Legend,
  Cell,
  ReferenceLine,
} from "recharts";
import type { DailyStats } from "@/lib/vrm-api";
import { format, parseISO, isToday, isYesterday } from "date-fns";
import { formatKwh, whToKwh } from "@/lib/energy";

export function DailyComparisonChart({ dailyStats }: { dailyStats: DailyStats[] }) {
  const last7 = dailyStats.slice(-7);
  const completed = last7.filter((d) => !isToday(parseISO(d.date)));
  const avg =
    completed.length > 0
      ? completed.reduce((s, d) => s + whToKwh(d.solarYield), 0) / completed.length
      : 0;

  const chartData = last7.map((d) => {
    const date = parseISO(d.date);
    let label = format(date, "EEE");
    if (isToday(date)) label = "Today";
    else if (isYesterday(date)) label = "Yesterday";

    return {
      name: label,
      "Solar Yield": Number(whToKwh(d.solarYield).toFixed(2)),
      "SOC Range": [d.batterySOCMin, d.batterySOCMax],
      isToday: isToday(date),
    };
  });

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-2xl p-5">
      <h3 className="text-sm font-medium text-gray-400 mb-1">
        Daily comparison (this Mac)
      </h3>
      <p className="text-xs text-gray-600 mb-4">
        7-day avg of completed days: {formatKwh(avg, 1)} kWh · today is yield so far
      </p>
      <ResponsiveContainer width="100%" height={280}>
        <BarChart data={chartData}>
          <CartesianGrid strokeDasharray="3 3" stroke="#1f2937" />
          <XAxis dataKey="name" tick={{ fill: "#6b7280", fontSize: 12 }} />
          <YAxis tick={{ fill: "#6b7280", fontSize: 12 }} unit=" kWh" />
          <Tooltip
            contentStyle={{
              backgroundColor: "#111827",
              border: "1px solid #374151",
              borderRadius: "8px",
            }}
          />
          <Legend />
          <ReferenceLine
            y={avg}
            stroke="#6b7280"
            strokeDasharray="3 3"
            label={{ value: "avg", fill: "#6b7280", fontSize: 11 }}
          />
          <Bar dataKey="Solar Yield" radius={[4, 4, 0, 0]} unit=" kWh">
            {chartData.map((entry, index) => (
              <Cell
                key={index}
                fill={entry.isToday ? "#f59e0b" : "#78716c"}
              />
            ))}
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}
