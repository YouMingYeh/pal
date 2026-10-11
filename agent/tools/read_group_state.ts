import { defineTool } from "eve/tools";
import { z } from "zod";
import { checked } from "../../lib/db";
import { jobScope, scopeId } from "../../lib/job-scope";

export default defineTool({
  description: "Read verified group members, saved places/sources, current polls/plans/reminders, unexpired preferences/availability, reactions, and timezone settings.",
  inputSchema: z.object({}),
  async execute(_input, context) {
    const { db, job } = await jobScope(scopeId(context));
    return checked(await db.rpc("pal_group_state", { p_group_id: job.group_id }));
  },
});
