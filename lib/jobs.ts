import { Client } from "eve/client";
import { admin, checked, env } from "./db";
import { jobScope, type Job } from "./job-scope";
import { agentReply, parsedPalOutputs, sharedUrls } from "./validation";
import { assertPublicURL } from "./research";
import { initialTurnInput } from "./turn-context";
import { EveInputPausedError, recoverEveResult } from "./eve-result";

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
        ({ body, structured } = await recoverEveResult(client.sessions.attach(sessionId)));
      } else {
        const { batch } = await jobScope(job.id);
        let recentQuery = db.from("messages").select("id,group_id,sender_id,role,body,created_at,reply_to_id,mentions,card,source_key")
          .eq("group_id", job.group_id).or("source_key.is.null,and(source_key.not.like.weekly:%,source_key.not.like.pal:weekly:%)")
          .order("created_at", { ascending: false }).order("id", { ascending: false }).limit(21);
        if (batch.length) recentQuery = recentQuery.lte("created_at", batch[batch.length - 1].created_at);
        const [state, recent] = await Promise.all([
          db.rpc("pal_group_state", { p_group_id: job.group_id }).then(checked), recentQuery.then(checked),
        ]);
        const unavailableUrls: string[] = [];
        for (const source of batch) {
          for (const url of sharedUrls(source.body)) {
            try { await assertPublicURL(url); }
            catch { unavailableUrls.push(url); continue; }
          }
        }
        const timezone = state?.settings?.timezone || "UTC";
        const isDirect = state?.settings?.is_direct === true;
        const currentTime = new Date().toISOString();
        const created = await client.sessions.create({
          message: JSON.stringify(initialTurnInput(job, batch, state, (recent ?? []).reverse(), currentTime)),
          clientContext: { currentTime, timezone, unavailableUrls, isDirect },
          outputSchema: agentReply,
        });
        sessionId = created.response.sessionId;
        checked(await db.from("agent_jobs").update({ result: JSON.stringify({ sessionId, format: "v2" }) })
          .eq("id", job.id).eq("attempts", job.attempts).eq("status", "running"));
        ({ body, structured } = await recoverEveResult(created.session));
      }
      const oldSession = job.result && !["v1", "v2"].includes(JSON.parse(job.result).format);
      if (structured === undefined && !oldSession) throw new Error("Pal did not return a structured result.");
      const outputs = parsedPalOutputs(structured ?? { reply: body ?? "", emotion: "fier" });
      checked(await db.rpc("complete_agent_job_with_outputs", {
        p_job_id: job.id, p_attempt: job.attempts, p_outputs: outputs,
        p_result: JSON.stringify({ sessionId, format: "v2", emotions: outputs.map(output => output.emotion) }),
      }));
    } catch (error) {
      if (error instanceof EveInputPausedError) {
        // Reattaching cannot answer a budget/approval prompt. Preserve the session and avoid replaying tools.
        checked(await db.from("agent_jobs").update({ status: "failed", lease_until: null, last_error: error.message })
          .eq("id", job.id).eq("attempts", job.attempts).eq("status", "running"));
        return;
      }
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
