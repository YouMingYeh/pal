import { defineTool } from "eve/tools";
import { z } from "zod";
import { agentAction } from "../../lib/job-scope";
import { id } from "../../lib/validation";

export default defineTool({
  description: "Draft one outing plan from the group's discussion. The card stays a draft until a member confirms it; no booking or calendar sync is claimed.",
  inputSchema: z.object({ title: z.string().trim().min(1).max(160), place_id: id.optional(),
    starts_at: z.string().datetime({ offset: true }), ends_at: z.string().datetime({ offset: true }).optional(), notes: z.string().max(2000).optional() }),
  execute(input, context) { return agentAction(context, "plan.create", input, "draft"); },
});
