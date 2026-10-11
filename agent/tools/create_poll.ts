import { defineTool } from "eve/tools";
import { z } from "zod";
import { agentAction } from "../../lib/job-scope";
import { id } from "../../lib/validation";

export default defineTool({
  description: "Create one concise group poll with verified place choices or concrete dated time choices. A card is posted automatically; members vote themselves.",
  inputSchema: z.object({
    kind: z.enum(["place", "time"]), question: z.string().trim().min(1).max(300),
    options: z.array(z.object({ id: z.string().min(1).max(64), label: z.string().min(1).max(160), place_id: id.optional(), starts_at: z.string().datetime({ offset: true }).optional() })).min(2).max(8),
    deadline_at: z.string().datetime({ offset: true }),
  }),
  execute(input, context) { return agentAction(context, "poll.create", input, input.kind); },
});
