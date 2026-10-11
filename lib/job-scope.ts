import { createHash } from "node:crypto";
import { admin, checked } from "./db";
import { parseAgentAction, type actionSchemas } from "./validation";

export type Job = {
  id: string; group_id: string; requester_id: string; message_id: string;
  attempts: number; status: string; result: string | null; lease_until: string | null;
  batch_message_ids?: string[]; explicit_mention?: boolean; job_kind?: "chat" | "weekly";
};
export type SourceMessage = { id: string; group_id: string; sender_id: string; role: "user"; body: string; created_at: string };

export async function jobScope(jobId: string) {
  const db = admin();
  const job = checked(await db.from("agent_jobs").select("*").eq("id", jobId).single()) as Job;
  if (job.status !== "running" || !job.lease_until || Date.parse(job.lease_until) <= Date.now()) {
    throw new Error("Job lease is no longer active.");
  }
  const membership = checked(await db.from("group_members").select("group_id")
    .eq("group_id", job.group_id).eq("user_id", job.requester_id).maybeSingle());
  if (!membership) throw new Error("Requester is no longer a group member.");
  const ids = job.batch_message_ids?.length ? job.batch_message_ids : [job.message_id];
  const batch = checked(await db.from("messages").select("id,group_id,sender_id,role,body,created_at")
    .eq("group_id", job.group_id).eq("role", "user").in("id", ids).order("created_at")) as SourceMessage[];
  if (!batch?.length && job.job_kind !== "weekly") throw new Error("Task source messages are unavailable.");
  return { job, db, batch: batch ?? [] };
}

export function batchSpeaker(batch: SourceMessage[], messageId: string) {
  const source = batch.find(message => message.id === messageId && message.role === "user");
  if (!source) throw new Error("Choose a human source message in this job's verified batch.");
  return source;
}

export function actionSourceKey(jobId: string, action: keyof typeof actionSchemas, identity: string) {
  const digest = createHash("sha256").update(identity).digest("hex").slice(0, 32);
  return `job:${jobId}:${action}:${digest}`;
}

export async function agentAction(context: Parameters<typeof scopeId>[0], action: keyof typeof actionSchemas,
  data: Record<string, unknown>, identity: string, sourceMessageId?: string) {
  const { job, db, batch } = await jobScope(scopeId(context));
  const source = sourceMessageId ? batchSpeaker(batch, sourceMessageId) : undefined;
  const parsed = parseAgentAction(action, data);
  return checked(await db.rpc("pal_agent_action", {
    p_group_id: job.group_id, p_requester_id: source?.sender_id ?? job.requester_id, p_action: action,
    p_data: { ...parsed, job_id: job.id, source_key: actionSourceKey(job.id, action, identity) },
  }));
}

export function scopeId(context: { session: { auth: { current: { attributes: Readonly<Record<string, unknown>> } | null } } }) {
  const value = context.session.auth.current?.attributes.jobId;
  if (typeof value !== "string") throw new Error("Missing verified job scope.");
  return value;
}
