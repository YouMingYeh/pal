import { admin, checked } from "./db";

export type Job = {
  id: string; group_id: string; requester_id: string; message_id: string;
  attempts: number; status: string; result: string | null; lease_until: string | null;
};

export async function jobScope(jobId: string) {
  const db = admin();
  const job = checked(await db.from("agent_jobs").select("*").eq("id", jobId).single()) as Job;
  if (job.status !== "running" || !job.lease_until || Date.parse(job.lease_until) <= Date.now()) {
    throw new Error("Job lease is no longer active.");
  }
  const membership = checked(await db.from("group_members").select("group_id")
    .eq("group_id", job.group_id).eq("user_id", job.requester_id).maybeSingle());
  if (!membership) throw new Error("Requester is no longer a group member.");
  return { job, db };
}

export function scopeId(context: { session: { auth: { current: { attributes: Readonly<Record<string, unknown>> } | null } } }) {
  const value = context.session.auth.current?.attributes.jobId;
  if (typeof value !== "string") throw new Error("Missing verified job scope.");
  return value;
}
