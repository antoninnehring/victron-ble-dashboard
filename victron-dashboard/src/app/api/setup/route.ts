import { NextResponse } from "next/server";
import { isConfigured, loadInstallation } from "@/lib/victron-config";

export const dynamic = "force-dynamic";

const NO_STORE = { "Cache-Control": "no-store, max-age=0" };

export async function GET() {
  const config = loadInstallation();
  return NextResponse.json(
    {
      configured: isConfigured(config),
      source: config.source,
      config: {
        installationName: config.installationName,
        devices: config.devices,
      },
    },
    { headers: NO_STORE }
  );
}
