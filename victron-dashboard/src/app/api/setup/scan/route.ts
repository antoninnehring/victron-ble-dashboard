import { spawn } from "child_process";
import { join } from "path";
import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";
export const maxDuration = 30;
export const runtime = "nodejs";

const NO_STORE = { "Cache-Control": "no-store, max-age=0" };
const SCAN_TIMEOUT_S = 8;

type ScanDevice = {
  address: string;
  name: string;
  rssi: number | null;
  type: string | null;
  typeLabel: string | null;
  suggestedRole: string;
};

function runScan(): Promise<{ ok: boolean; devices: ScanDevice[]; error: string | null }> {
  const script = join(process.cwd(), "ble-reader", "scan.py");
  return new Promise((resolve) => {
    const child = spawn(
      "python3",
      [script, "--json", "--timeout", String(SCAN_TIMEOUT_S)],
      {
        cwd: join(process.cwd(), "ble-reader"),
        env: { ...process.env, PYTHONUNBUFFERED: "1" },
      }
    );
    let stdout = "";
    let stderr = "";
    const killTimer = setTimeout(() => {
      child.kill("SIGKILL");
    }, (SCAN_TIMEOUT_S + 12) * 1000);

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", (err) => {
      clearTimeout(killTimer);
      resolve({
        ok: false,
        devices: [],
        error:
          err.message.includes("ENOENT")
            ? "python3 not found — install Python 3 or enter addresses manually."
            : err.message,
      });
    });
    child.on("close", (code) => {
      clearTimeout(killTimer);
      const trimmed = stdout.trim();
      if (trimmed) {
        try {
          const parsed = JSON.parse(trimmed);
          resolve({
            ok: Boolean(parsed.ok),
            devices: Array.isArray(parsed.devices) ? parsed.devices : [],
            error: parsed.error || (parsed.ok ? null : "Scan failed"),
          });
          return;
        } catch {
          resolve({
            ok: false,
            devices: [],
            error: "Scan returned unreadable output. Enter addresses manually.",
          });
          return;
        }
      }
      const errText = stderr.trim() || `Scan exited (${code ?? "?"})`;
      resolve({
        ok: false,
        devices: [],
        error: errText.slice(0, 400),
      });
    });
  });
}

export async function POST() {
  try {
    const result = await runScan();
    return NextResponse.json(result, { headers: NO_STORE });
  } catch (err) {
    return NextResponse.json(
      {
        ok: false,
        devices: [],
        error: err instanceof Error ? err.message : "Scan failed",
      },
      { status: 500, headers: NO_STORE }
    );
  }
}
