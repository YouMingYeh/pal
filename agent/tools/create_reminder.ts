import { defineTool } from "eve/tools";
import { z } from "zod";
import { checked } from "../../lib/db";
import { jobScope, scopeId } from "../../lib/job-scope";
import { validateReminder } from "../../lib/validation";

export default defineTool({
  description: "Save one reminder requested by the user for this group. Posts to chat at the specified future time even with the app closed.",
  inputSchema: z.object({
    body: z.string().trim().min(1).max(1000),
    due_at: z.string().datetime({ offset: true }),
    timezone: z.string().min(1).max(80),
  }),
  async execute(input, context) {
    const { job, db } = await jobScope(scopeId(context));
    const source = checked(await db.from("messages").select("body").eq("id", job.message_id).single());
    if (!source || !/remind|提醒/i.test(source.body)) throw new Error("The requester did not ask for a reminder.");
    const sourceKey = `job:${job.id}`;
    const existing = checked(await db.from("reminders").select("id")
      .eq("group_id", job.group_id).eq("source_key", sourceKey).maybeSingle());
    const dueAt = existing ? input.due_at : validateReminder(input.due_at, input.timezone);
    const reminder = checked(await db.rpc("create_reminder", {
      p_group_id: job.group_id, p_requester_id: job.requester_id, p_body: input.body,
      p_due_at: dueAt, p_timezone: input.timezone, p_source_key: sourceKey,
    }));
    return { saved: true, reminder };
  },
});
