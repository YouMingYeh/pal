import { after } from "next/server";
import { dispatchJobs } from "../../../lib/jobs";
import { matchesSecret } from "../../../lib/validation";
import { route } from "../../../lib/http";
import { runIntegrations } from "../../../lib/integrations";
import { runDemoScenes } from "../../../lib/demo";
import { admin, checked } from "../../../lib/db";

export const maxDuration = 300;
export function POST(request: Request) {
  if (!matchesSecret(request.headers.get("authorization"), process.env.CRON_SECRET)) {
    return Response.json({ error: "Unauthorized" }, { status: 401 });
  }
  return route(async () => {
    after(async () => {
      checked(await admin().rpc("pal_maintenance"));
      await runDemoScenes();
      await dispatchJobs();
      await runIntegrations();
    });
    return Response.json({ accepted: true }, { status: 202 });
  });
}
