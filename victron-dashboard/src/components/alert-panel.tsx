"use client";

import { formatDistanceToNow } from "date-fns";
import type { Alert } from "@/lib/vrm-api";

const levelStyles = {
  critical: {
    bg: "bg-red-950/40",
    border: "border-red-800/50",
    icon: "🔴",
    text: "text-red-400",
  },
  warning: {
    bg: "bg-amber-950/40",
    border: "border-amber-800/50",
    icon: "🟡",
    text: "text-amber-400",
  },
  info: {
    bg: "bg-blue-950/40",
    border: "border-blue-800/50",
    icon: "🔵",
    text: "text-blue-400",
  },
};

export function AlertPanel({ alerts }: { alerts: Alert[] }) {
  if (alerts.length === 0) {
    return (
      <div className="bg-gray-900 border border-gray-800 rounded-2xl p-5">
        <h3 className="text-sm font-medium text-gray-400 mb-3">Alerts</h3>
        <p className="text-gray-600 text-sm">No active alerts. All systems normal.</p>
      </div>
    );
  }

  const critical = alerts.filter((a) => a.level === "critical");
  const others = alerts.filter((a) => a.level !== "critical");

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-2xl p-5">
      <div className="flex items-center gap-2 mb-4">
        <h3 className="text-sm font-medium text-gray-400">Alerts</h3>
        {critical.length > 0 && (
          <span className="text-xs bg-red-900 text-red-300 px-2 py-0.5 rounded-full">
            {critical.length} critical
          </span>
        )}
      </div>
      <div className="space-y-2 max-h-80 overflow-y-auto">
        {[...critical, ...others].map((alert) => {
          const style = levelStyles[alert.level];
          return (
            <div
              key={alert.id + alert.timestamp}
              className={`${style.bg} border ${style.border} rounded-lg p-3 flex items-start gap-3`}
            >
              <span className="text-sm mt-0.5">{style.icon}</span>
              <div className="flex-1 min-w-0">
                <div className={`text-sm font-medium ${style.text}`}>
                  {alert.title}
                </div>
                <div className="text-xs text-gray-400 mt-0.5">
                  {alert.message}
                </div>
              </div>
              <div className="text-xs text-gray-600 whitespace-nowrap">
                {formatDistanceToNow(alert.timestamp, { addSuffix: true })}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
