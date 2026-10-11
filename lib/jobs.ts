import { Client } from "eve/client";
import { admin, checked, env } from "./db";
import { jobScope, type Job } from "./job-scope";
import { agentReply, sharedUrls } from "./validation";
import { assertPublicURL } from "./research";

export async function dispatchJobs() {
  const db = admin();
  const jobs = checked(await db.rpc("claim_agent_jobs", { p_limit: 3 })) as Job[];
  await Promise.all(jobs.map(async (job) => {
    try {
      const client = new Client({
        host: env("PAL_BASE_URL"), redirect: "error",
        auth: { bearer: env("PAL_INTERNAL_SECRET") }, headers: { "x-pal-job-id": job.id },
      });
      let sessionId = job.result ? JSON.parse(job.result).sessionId as string | undefined : undefined;
      let body: string | undefined;
      let structured: unknown;
      if (sessionId) {
        // shortcut: one turn per job, recover its durable stream instead of sending the request twice.
        for await (const event of client.sessions.attach(sessionId).stream()) {
          if (event.type === "message.completed") body = event.data.message;
          if (event.type === "result.completed") structured = event.data.result;
          if (event.type === "turn.failed" || event.type === "session.failed") throw new Error("Pal's durable task failed.");
          if (event.type === "turn.completed" || event.type === "turn.waiting" || event.type === "session.waiting" || event.type === "session.completed") break;
        }
      } else {
        const { batch } = await jobScope(job.id);
        const unavailableUrls: string[] = [];
        for (const source of batch) {
          for (const url of sharedUrls(source.body)) {
            try { await assertPublicURL(url); }
            catch { unavailableUrls.push(url); continue; }
          }
        }
        const state = checked(await db.rpc("pal_group_state", { p_group_id: job.group_id }));
        const timezone = state?.settings?.timezone || "UTC";
        const created = await client.sessions.create({
          message: JSON.stringify({ kind: job.job_kind ?? "chat", explicitMention: job.explicit_mention ?? false, messages: batch }),
          clientContext: { currentTime: new Date().toISOString(), timezone, unavailableUrls },
          outputSchema: agentReply,
        });
        sessionId = created.response.sessionId;
        checked(await db.from("agent_jobs").update({ result: JSON.stringify({ sessionId, format: "v1" }) })
          .eq("id", job.id).eq("attempts", job.attempts).eq("status", "running"));
        const result = await created.response.result();
        if (result.status === "failed") throw new Error("Pal's durable task failed.");
        body = result.message;
        structured = result.data;
      }
      const oldSession = job.result && JSON.parse(job.result).format !== "v1";
      if (structured !== undefined) body = agentReply.parse(structured).reply.trim();
      else if (!oldSession) throw new Error("Pal did not return a structured result.");
      checked(await db.rpc("complete_agent_job", {
        p_job_id: job.id, p_attempt: job.attempts, p_body: body,
        p_result: JSON.stringify({ sessionId, format: "v1" }),
      }));
    } catch (error) {
      // Terminal task failures must create a new Eve session on a future retry.
      if (error instanceof Error && error.message === "Pal's durable task failed.") {
        checked(await db.from("agent_jobs").update({ result: null }).eq("id", job.id)
          .eq("attempts", job.attempts).eq("status", "running"));
      }
      checked(await db.rpc("fail_agent_job", {
        p_job_id: job.id, p_attempt: job.attempts,
        p_error: error instanceof Error ? error.message.slice(0, 500) : "Unknown task failure",
      }));
    }
  }));
  return jobs.length;
}
