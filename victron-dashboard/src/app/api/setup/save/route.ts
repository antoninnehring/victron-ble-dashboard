import { NextResponse } from "next/server";
import { saveInstallation } from "@/lib/victron-config";

export const dynamic = "force-dynamic";

const NO_STORE = { "Cache-Control": "no-store, max-age=0" };

export async function POST(request: Request) {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json(
      { ok: false, error: "Invalid JSON" },
      { status: 400, headers: NO_STORE }
    );
  }

  try {
    const saved = saveInstallation(body);
    return NextResponse.json(
      {
        ok: true,
        config: {
          installationName: saved.installationName,
          devices: saved.devices,
        },
      },
      { headers: NO_STORE }
    );
  } catch (err) {
    return NextResponse.json(
      { ok: false, error: err instanceof Error ? err.message : "Save failed" },
      { status: 400, headers: NO_STORE }
    );
  }
}
