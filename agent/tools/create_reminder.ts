import { defineTool } from "eve/tools";
import { z } from "zod";
import { agentAction, batchSpeaker, jobScope, scopeId } from "../../lib/job-scope";
import { id, timezone, validateReminder } from "../../lib/validation";

export default defineTool({
  description: "Save one explicitly requested reminder for its verified speaker. Target members get a server reminder even after closing the app.",
  inputSchema: z.object({
    source_message_id: id, body: z.string().trim().min(1).max(2000),
    due_at: z.string().datetime({ offset: true }), timezone,
    target_user_ids: z.array(id).max(50).optional(), plan_id: id.optional(), poll_id: id.optional(),
  }),
  async execute({ source_message_id, ...input }, context) {
    const { db, job, batch } = await jobScope(scopeId(context));
    const source = batchSpeaker(batch, source_message_id);
    if (!/remind|提醒/i.test(source.body)) throw new Error("This speaker did not ask for a reminder.");
    const existing = await db.from("reminders").select("id").eq("group_id", job.group_id)
      .eq("requester_id", source.sender_id).eq("body", input.body).eq("due_at", input.due_at).maybeSingle();
    if (existing.error) throw new Error(existing.error.message);
    if (!existing.data) validateReminder(input.due_at, input.timezone);
    return agentAction(context, "reminder.create", input, `reminder:${source.id}`, source_message_id);
  },
});
