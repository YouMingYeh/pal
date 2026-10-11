import { defineTool } from "eve/tools";
import { z } from "zod";
import { agentAction } from "../../lib/job-scope";
import { id } from "../../lib/validation";

export default defineTool({
  description: "Save a draft outing from a clear group discussion with verified place and dated time. Explain the draft and any missing detail in natural text. It remains a draft until a member explicitly confirms it through their own source-grounded message; never claim booking or calendar sync.",
  inputSchema: z.object({ title: z.string().trim().min(1).max(160), place_id: id.optional(),
    starts_at: z.string().datetime({ offset: true }), ends_at: z.string().datetime({ offset: true }).optional(), notes: z.string().max(2000).optional() }),
  execute(input, context) { return agentAction(context, "plan.create", input, "draft"); },
});
