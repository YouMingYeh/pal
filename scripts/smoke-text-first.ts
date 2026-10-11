import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";
import { createClient } from "@supabase/supabase-js";
import { Client } from "eve/client";
import { admin, checked, env } from "../lib/db";

// Actual hosted Eve/OpenAI checks; only fresh temporary users/groups are mutated.
// node --env-file=.env --import tsx scripts/smoke-text-first.ts https://pal-jade.vercel.app
assert.ok(process.argv[2], "Supply the deployed origin explicitly.");
const origin = new URL(process.argv[2]);
assert.ok(["http:", "https:"].includes(origin.protocol) && !origin.username && !origin.password);
const base = origin.origin, db = admin();
type User = { id: string; token: string; client: ReturnType<typeof admin> };
const users: User[] = [], trace = new Map<string, unknown>();
let groupId: string | undefined;
async function provision() {
  const email = `text-first-${randomUUID()}@pal-demo.example`, password = randomUUID() + randomUUID();
  const created = await db.auth.admin.createUser({ email, password, email_confirm: true });
  assert.ifError(created.error); assert.ok(created.data.user);
  const client = createClient(env("SUPABASE_URL"), env("SUPABASE_PUBLISHABLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false } });
  const signed = await client.auth.signInWithPassword({ email, password });
  if (signed.error || !signed.data.session) {
    await db.auth.admin.deleteUser(created.data.user.id); throw new Error("Temporary text-first sign-in failed.");
  }
  const user = { id: created.data.user.id, token: signed.data.session.access_token, client }; users.push(user); return user;
}
async function api(user: User, path: string, method = "GET", body?: unknown) {
  const response = await fetch(base + path, { method, redirect: "error", signal: AbortSignal.timeout(30000),
    headers: { authorization: `Bearer ${user.token}`, "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  assert.ok(response.ok, `${method} ${path} returned ${response.status}.`); return response.json();
}
async function snapshot(jobId: string, sessionId: string) {
  const client = new Client({ host: base, redirect: "error", auth: { bearer: env("PAL_INTERNAL_SECRET") }, headers: { "x-pal-job-id": jobId } });
  try {
    for await (const event of client.sessions.attach(sessionId).stream({ startIndex: 0, follow: false,
      signal: AbortSignal.timeout(3000), streamReconnectPolicy: { reconnect: false } })) {
      if (["actions.requested", "action.result", "result.completed"].includes(event.type)) {
        trace.set(`${jobId}:${event.meta.id}`, { job_id: jobId, type: event.type, data: event.data });
      }
    }
  } catch { /* Read-only diagnostics cannot restart or fail a real turn. */ }
}
async function sendAndWait(user: User, body: string) {
  assert.ok(!/@pal\b/i.test(body), "The check must not depend on @Pal.");
  const { message } = await api(user, `/api/groups/${groupId}/messages`, "POST", { body, client_id: randomUUID() });
  const deadline = Date.now() + 180000;
  while (Date.now() < deadline) {
    const trigger = checked(await db.from("agent_jobs").select("id,coalesced_into").eq("group_id", groupId!).eq("message_id", message.id).maybeSingle());
    if (trigger) {
      const jobId = trigger.coalesced_into || trigger.id;
      const job = checked(await db.from("agent_jobs").select("id,status,result,attempts,explicit_mention,batch_message_ids")
        .eq("id", jobId).single());
      assert.ok(job); assert.equal(job.explicit_mention, false);
      if (job.status === "running" && job.result) await snapshot(jobId, JSON.parse(job.result).sessionId);
      if (job.status === "completed") {
        assert.ok(JSON.parse(job.result).sessionId, "A real durable Eve session must run.");
        assert.ok(job.batch_message_ids.includes(message.id), "Completion includes the actual human source.");
        const replies = checked(await db.from("messages").select("id,body,card,emotion")
          .eq("group_id", groupId!).eq("source_key", `job:${jobId}`)) ?? [];
        for (const reply of replies) {
          assert.ok(reply.body.trim()); assert.equal(reply.card, null, "Actual agent replies stay plain text.");
          assert.doesNotMatch(reply.body, /tap (?:the|a|this)|(?:click|press) (?:the|a) (?:button|card)|vote in (?:the|a) poll/i);
        }
        return { source: message.id as string, job: jobId, replies };
      }
      if (job.status === "failed" && job.attempts >= 3) throw new Error("Real text-first Eve job failed repeatedly.");
    }
    await sleep(1000);
  }
  throw new Error("The real text-first Eve job did not finish within three minutes.");
}
try {
  const owner = await provision(), member = await provision();
  const { group } = await api(owner, "/api/groups", "POST", { name: "Pal temporary text-first check", client_id: randomUUID() });
  groupId = group.id;
  await api(member, "/api/groups/join", "POST", { invite_code: group.invite_code });
  const action = (name: string, data: unknown) => api(owner, `/api/groups/${groupId}/state`, "POST", { action: name, data });
  await action("group.settings", { timezone: "UTC", proactive_suggestions: false });
  const greeting = await sendAndWait(owner, "Hey Pal, good to see you here!");
  assert.equal(greeting.replies.length, 1, "A natural greeting addressed to Pal receives a friendly reply without @Pal.");
  assert.doesNotMatch(greeting.replies[0].body, /here(?:'s| is) what i can|your ai assistant|powered by|feature list/i);
  console.log("PASS: real Eve/OpenAI answered a natural greeting with one plain-text reply, without @Pal or feature promotion.");

  const preference = await sendAndWait(member, "I prefer vegetarian food.");
  const memories = checked(await db.from("member_memories").select("user_id,source_message_id,value")
    .eq("group_id", groupId!).eq("source_message_id", preference.source)) ?? [];
  assert.ok(memories.some(row => row.user_id === member.id && /vegetarian/i.test(row.value)));
  assert.equal(memories.some(row => row.user_id === owner.id), false);
  assert.equal(preference.replies.length, 0, "Explicit preference observation is remembered quietly in a shared chat.");
  console.log("PASS: the actual speaker's vegetarian preference was quietly persisted with its real source; no unsolicited reply.");

  const when = new Date(Date.now() + 3 * 86400000); when.setUTCHours(19, 0, 0, 0);
  const draft = await action("plan.create", { title: "Riverside dinner", starts_at: when.toISOString(),
    ends_at: new Date(when.getTime() + 3600000).toISOString(), notes: "Meet by the riverside; restaurant is still undecided.", source_key: `smoke:${randomUUID()}` });
  await sendAndWait(member, "Anything works");
  const stillDraft = checked(await db.from("plans").select("status,version").eq("group_id", groupId!).eq("id", draft.id).single());
  assert.equal(stillDraft?.status, "draft"); assert.equal(stillDraft.version, draft.version);
  assert.equal((checked(await db.from("plan_rsvps").select("user_id").eq("group_id", groupId!)) ?? []).length, 0);
  console.log("PASS: anything works neither confirmed the draft nor silently RSVP'd either member.");

  const confirmation = await sendAndWait(member, "Confirm Riverside dinner");
  const confirmed = checked(await db.from("plans").select("status,version,booking_status,starts_at")
    .eq("group_id", groupId!).eq("id", draft.id).single());
  assert.equal(confirmed?.status, "confirmed"); assert.equal(confirmed.version, draft.version + 1);
  assert.equal(confirmed.booking_status, "needed"); assert.equal(Date.parse(confirmed.starts_at), when.getTime());
  assert.equal(confirmation.replies.length, 1, "Successful explicit confirmation has a useful plain-text reply.");
  assert.match(confirmation.replies[0].body, /riverside/i);
  assert.match(confirmation.replies[0].body, /19:00|7(?::00)?\s*p\.?m/i, "The success reply gives the real plan time.");
  assert.doesNotMatch(confirmation.replies[0].body, /table(?:'s| is)? booked|reservation confirmed|everyone(?:'s| is) (?:in|attending)|synced/i);
  assert.equal((checked(await db.from("plan_rsvps").select("user_id").eq("group_id", groupId!)) ?? []).length, 0);
  assert.equal((checked(await db.from("polls").select("id").eq("group_id", groupId!)) ?? []).length, 0, "No new polls were created.");
  console.log("PASS: the member's real confirmation source changed the future draft once; Pal gave its actual time in text, without inventing booking, attendees, sync, or polls.");
} catch (error) {
  if (groupId) {
    await mkdir(".secrets", { recursive: true, mode: 0o700 });
    const snapshots = await Promise.all([
      db.from("messages").select("id,sender_id,role,body,card,source_key,created_at").eq("group_id", groupId),
      db.from("agent_jobs").select("id,message_id,status,attempts,result,batch_message_ids,last_error").eq("group_id", groupId),
      db.from("plans").select("id,status,title,version,starts_at").eq("group_id", groupId),
    ]);
    await writeFile(".secrets/text-first-smoke-failure.json", JSON.stringify({ trace: [...trace.values()], snapshots: snapshots.map(row => ({ data: row.data, error: row.error?.code })) }, null, 2), { mode: 0o600 });
  }
  throw error;
} finally {
  if (groupId) {
    // Revoke only this fixture's accepted/live work before removing its source group.
    checked(await db.from("groups").update({ agent_paused: true }).eq("id", groupId).eq("creator_id", users[0].id));
    checked(await db.from("agent_jobs").update({ status: "cancelled", lease_until: null, completed_at: new Date().toISOString() })
      .eq("group_id", groupId).in("status", ["queued", "running"]));
    checked(await db.from("groups").delete().eq("id", groupId).eq("creator_id", users[0].id));
  }
  for (const user of users) { await user.client.auth.signOut({ scope: "local" }); assert.ifError((await db.auth.admin.deleteUser(user.id)).error); }
}
console.log("PASS: temporary group and identities cleaned; existing human/demo data preserved.");
