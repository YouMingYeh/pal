import { defineTool } from "eve/tools";
import { z } from "zod";
import { jobScope, scopeId } from "../../lib/job-scope";
import { checked } from "../../lib/db";

export default defineTool({
  description: "Read the latest messages in the current verified group to summarize its discussion and action items.",
  inputSchema: z.object({}),
  async execute(_input, context) {
    const { job, db } = await jobScope(scopeId(context));
    const messages = checked(await db.from("messages").select("sender_id,role,body,created_at")
      .eq("group_id", job.group_id).order("created_at", { ascending: false }).limit(80));
    return (messages ?? []).reverse();
  },
});
