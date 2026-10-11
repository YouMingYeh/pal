import { defineTool } from "eve/tools";
import { z } from "zod";
import { agentAction, batchSpeaker, jobScope, scopeId } from "../../lib/job-scope";
import { id } from "../../lib/validation";

export default defineTool({
  description: "Add one restrained Pal reaction to a human message in this batch without sending a chat reply.",
  inputSchema: z.object({ message_id: id, emoji: z.enum(["👍", "❤️", "😂", "🎉", "👀", "✅", "🤔"]) }),
  async execute(input, context) {
    const { batch } = await jobScope(scopeId(context));
    batchSpeaker(batch, input.message_id);
    return agentAction(context, "reaction.toggle", input, `${input.message_id}:${input.emoji}`);
  },
});
