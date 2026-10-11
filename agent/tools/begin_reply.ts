import { defineTool } from "eve/tools";
import { z } from "zod";
import { admin, checked } from "../../lib/db";
import { scopeId } from "../../lib/job-scope";

export default defineTool({
  description: "Signal that you have chosen to send a real nonempty public reply. Call once after reading and finishing other tools, immediately before composing the actual reply. Never call while deciding whether to participate, for quiet memory observations, or when returning silence. This changes only the group's typing indicator; it never sends a message.",
  inputSchema: z.object({}).strict(),
  async execute(_input, context) {
    const rawAttempt = context.session.auth.current?.attributes.jobAttempt;
    const attempt = typeof rawAttempt === "string" ? Number(rawAttempt) : NaN;
    if (!Number.isSafeInteger(attempt) || attempt < 1) throw new Error("Missing verified worker attempt.");
    const started = checked(await admin().rpc("pal_begin_reply", {
      p_job_id: scopeId(context), p_job_attempt: attempt,
    }));
    if (!started) throw new Error("Reply lease is no longer active.");
    return { typing: true };
  },
});
