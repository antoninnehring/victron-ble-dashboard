"use client";

import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Legend,
} from "recharts";
import type { DailyStats } from "@/lib/vrm-api";
import { format, parseISO } from "date-fns";
import { whToKwh } from "@/lib/energy";

export function EnergyFlowChart({ dailyStats }: { dailyStats: DailyStats[] }) {
  const chartData = dailyStats.map((d) => ({
    date: format(parseISO(d.date), "dd MMM"),
    "Solar Yield": Number(whToKwh(d.solarYield).toFixed(2)),
    "Peak Power": Number((d.solarPeakPower / 1000).toFixed(2)), // W -> kW
  }));

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-2xl p-5">
      <h3 className="text-sm font-medium text-gray-400 mb-4">
        Solar Production History
      </h3>
      <ResponsiveContainer width="100%" height={280}>
        <AreaChart data={chartData}>
          <defs>
            <linearGradient id="solarGrad" x1="0" y1="0" x2="0" y2="1">
              <stop offset="5%" stopColor="#f59e0b" stopOpacity={0.3} />
              <stop offset="95%" stopColor="#f59e0b" stopOpacity={0} />
            </linearGradient>
          </defs>
          <CartesianGrid strokeDasharray="3 3" stroke="#1f2937" />
          <XAxis dataKey="date" tick={{ fill: "#6b7280", fontSize: 12 }} />
          <YAxis tick={{ fill: "#6b7280", fontSize: 12 }} unit=" kWh" />
          <Tooltip
            contentStyle={{
              backgroundColor: "#111827",
              border: "1px solid #374151",
              borderRadius: "8px",
            }}
          />
          <Legend />
          <Area
            type="monotone"
            dataKey="Solar Yield"
            stroke="#f59e0b"
            fillOpacity={1}
            fill="url(#solarGrad)"
            unit=" kWh"
          />
          <Area
            type="monotone"
            dataKey="Peak Power"
            stroke="#fb923c"
            fillOpacity={0}
            strokeDasharray="5 5"
            unit=" kW"
          />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}
