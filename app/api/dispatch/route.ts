import { dispatchJobs } from "../../../lib/jobs";
import { matchesSecret } from "../../../lib/validation";
import { route } from "../../../lib/http";

export const maxDuration = 300;
export function POST(request: Request) {
  if (!matchesSecret(request.headers.get("authorization"), process.env.CRON_SECRET)) {
    return Response.json({ error: "Unauthorized" }, { status: 401 });
  }
  return route(async () => Response.json({ processed: await dispatchJobs() }));
}
