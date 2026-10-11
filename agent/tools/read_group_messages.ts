import { defineTool } from "eve/tools";
import { z } from "zod";
import { jobScope, scopeId } from "../../lib/job-scope";
import { checked } from "../../lib/db";

export default defineTool({
  description: "Read the latest messages in the current verified group to summarize its discussion and action items.",
  inputSchema: z.object({}),
  async execute(_input, context) {
    const { job, db, batch } = await jobScope(scopeId(context));
    let query = db.from("messages").select("id,sender_id,role,body,created_at,reply_to_id,mentions,card")
      .eq("group_id", job.group_id).order("created_at", { ascending: false }).order("id", { ascending: false }).limit(80);
    if (batch.length) query = query.lte("created_at", batch[batch.length - 1].created_at);
    const messages = checked(await query);
    const replyIds = [...new Set((messages ?? []).map(message => message.reply_to_id).filter((value): value is string => typeof value === "string"))];
    const replies = replyIds.length ? checked(await db.from("messages").select("id,sender_id,role,body")
      .eq("group_id", job.group_id).in("role", ["user", "pal"]).in("id", replyIds)) ?? [] : [];
    const byId = new Map(replies.map(reply => [reply.id, { ...reply, body: reply.body.slice(0, 500) }]));
    return (messages ?? []).reverse().map(message => ({ ...message, reply: message.reply_to_id ? byId.get(message.reply_to_id) ?? null : null }));
  },
});
