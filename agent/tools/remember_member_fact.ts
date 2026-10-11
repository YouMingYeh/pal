import { defineTool } from "eve/tools";
import { z } from "zod";
import { agentAction, batchSpeaker, jobScope, scopeId } from "../../lib/job-scope";
import { id } from "../../lib/validation";

export default defineTool({
  description: "Remember only a speaker's own explicitly stated preference or dated availability, with a real source message and verbatim evidence. Never infer another person's facts.",
  inputSchema: z.object({
    source_message_id: id, evidence: z.string().trim().min(1).max(1000),
    kind: z.enum(["preference", "availability"]), key: z.string().trim().min(1).max(80),
    value: z.string().trim().min(1).max(1000), expires_at: z.string().datetime({ offset: true }).nullable().optional(),
  }),
  async execute({ evidence, ...input }, context) {
    const { batch } = await jobScope(scopeId(context));
    const source = batchSpeaker(batch, input.source_message_id);
    if (!source.body.includes(evidence)) throw new Error("Evidence must quote the source message exactly.");
    if (input.kind === "availability" && (!input.expires_at || Date.parse(input.expires_at) <= Date.now())) {
      throw new Error("Availability needs a future expiry.");
    }
    return agentAction(context, "memory.save", input, `${source.id}:${input.kind}:${input.key}`, source.id);
  },
});
