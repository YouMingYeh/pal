import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { performance } from "node:perf_hooks";
import { setTimeout as sleep } from "node:timers/promises";
import { createClient } from "@supabase/supabase-js";
import { admin, checked, env } from "../lib/db";

assert.ok(process.argv[2], "Supply the deployed origin explicitly.");
const origin = new URL(process.argv[2]);
assert.ok(["http:", "https:"].includes(origin.protocol) && !origin.username && !origin.password);
const base = origin.origin, db = admin(), groups = new Set<string>();
const client = createClient(env("SUPABASE_URL"), env("SUPABASE_PUBLISHABLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false } });
let owner: string | undefined, token = "";
async function api(path: string, method = "GET", body?: unknown) {
  const started = performance.now();
  const response = await fetch(base + path, { method, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(60000), redirect: "error" });
  const headersMs = performance.now() - started;
  const data = await response.json();
  assert.ok(response.ok, `${method} ${path} returned ${response.status}`);
  return { data, headersMs: Math.round(headersMs), bodyMs: Math.round(performance.now() - started) };
}
async function send(label: string, groupId: string, body: string, expectJob: boolean) {
  const ack = await api(`/api/groups/${groupId}/messages`, "POST", { body, client_id: randomUUID() });
  const atAck = checked(await db.from("agent_jobs").select("status,run_after,created_at,completed_at").eq("message_id", ack.data.message.id).maybeSingle());
  console.log(JSON.stringify({ label, headers_ms: ack.headersMs, body_ms: ack.bodyMs, job_status_at_ack: atAck?.status ?? "none" }));
  if (!expectJob) { assert.equal(atAck, null); return; }
  const deadline = Date.now() + 90000;
  while (Date.now() < deadline) {
    const job = checked(await db.from("agent_jobs").select("status,created_at,completed_at").eq("message_id", ack.data.message.id).maybeSingle());
    if (job?.status === "completed") {
      console.log(JSON.stringify({ label, agent_total_ms: Date.parse(job.completed_at) - Date.parse(job.created_at) }));
      return;
    }
    if (job?.status === "failed") throw new Error(`${label}: real agent job failed.`);
    await sleep(500);
  }
  throw new Error(`${label}: real agent job did not complete within the bounded wait.`);
}
try {
  const email = `latency-${randomUUID()}@pal-demo.example`, password = randomUUID() + randomUUID();
  const created = await db.auth.admin.createUser({ email, password, email_confirm: true });
  assert.ifError(created.error); assert.ok(created.data.user); owner = created.data.user.id;
  const signed = await client.auth.signInWithPassword({ email, password });
  assert.ifError(signed.error); assert.ok(signed.data.session); token = signed.data.session.access_token;
  const { data: inbox } = await api("/api/groups");
  for (const group of inbox.groups) groups.add(group.id);
  const direct = inbox.groups.find((group: { is_direct: boolean }) => group.is_direct); assert.ok(direct);
  const { data: createdGroup } = await api("/api/groups", "POST", { name: "Send latency isolated QA", client_id: randomUUID() });
  const groupId = createdGroup.group.id; groups.add(groupId);
  await api(`/api/groups/${groupId}/state`, "POST", { action: "group.settings", data: { agent_paused: true, proactive_suggestions: false } });
  await send("paused-shared", groupId, "Checking message acknowledgement while Pal is paused.", false);
  await api(`/api/groups/${groupId}/state`, "POST", { action: "group.settings", data: { agent_paused: false } });
  await send("active-ordinary", groupId, "I prefer quiet places.", true);
  await send("active-mention", groupId, "@Pal what preference did I just share? Reply in one sentence.", true);
  await send("private-direct", direct.id, "Say hello in one short sentence.", true);
} finally {
  if (owner) {
    for (const group of checked(await db.from("groups").select("id").eq("creator_id", owner)) ?? []) groups.add(group.id);
    const deadline = Date.now() + 60000;
    while (groups.size && Date.now() < deadline) {
      const pending = checked(await db.from("agent_jobs").select("id").in("group_id", [...groups]).in("status", ["queued", "running"])) ?? [];
      if (!pending.length) break;
      await sleep(1000);
    }
    if (groups.size) {
      checked(await db.from("agent_jobs").update({ status: "cancelled", lease_until: null, completed_at: new Date().toISOString() }).in("group_id", [...groups]).in("status", ["queued", "running"]));
      checked(await db.from("groups").delete().in("id", [...groups]).eq("creator_id", owner));
    }
    await client.auth.signOut({ scope: "local" });
    const removed = await db.auth.admin.deleteUser(owner); assert.ifError(removed.error);
  }
}
