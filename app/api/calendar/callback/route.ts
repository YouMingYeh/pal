import { after } from "next/server";
import { completeGoogleConnection, runCalendarSync } from "../../../../lib/calendar";

export const maxDuration = 300;

export async function GET(request: Request) {
  const params = new URL(request.url).searchParams;
  let status = "failed";
  if (!params.has("error")) {
    try {
      await completeGoogleConnection(params.get("state") || "", params.get("code") || "");
      status = "connected";
      after(async () => { await runCalendarSync().catch(() => undefined); });
    } catch { /* Authorization codes and provider responses must never reach logs or URLs. */ }
  }
  return new Response(null, { status: 302, headers: { location: `pal://calendar?status=${status}`, "cache-control": "no-store", "referrer-policy": "no-referrer" } });
}
