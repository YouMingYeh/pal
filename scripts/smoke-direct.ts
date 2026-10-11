import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { setTimeout as sleep } from "node:timers/promises";
import { createClient } from "@supabase/supabase-js";
import { Client } from "eve/client";
import { admin, checked, env } from "../lib/db";

assert.ok(process.argv[2], "Supply the deployed origin explicitly.");
const origin = new URL(process.argv[2]);
assert.ok(["http:", "https:"].includes(origin.protocol) && !origin.username && !origin.password);
const base = origin.origin, db = admin();
type User = { id: string; token: string; client: ReturnType<typeof admin> };
const users: User[] = [], groupIds = new Set<string>();
async function provision(label: string) {
  const email = `dm-${label}-${randomUUID()}@pal-demo.example`, password = randomUUID() + randomUUID();
  const created = await db.auth.admin.createUser({ email, password, email_confirm: true });
  assert.ifError(created.error); assert.ok(created.data.user);
  const client = createClient(env("SUPABASE_URL"), env("SUPABASE_PUBLISHABLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false }, realtime: { transport: WebSocket, vsn: "1.0.0" } });
  const signed = await client.auth.signInWithPassword({ email, password });
  if (signed.error || !signed.data.session) {
    await db.auth.admin.deleteUser(created.data.user.id);
    throw new Error("Temporary demo sign-in failed.");
  }
  const user = { id: created.data.user.id, token: signed.data.session.access_token, client }; users.push(user); return user;
}
const request = (user: User, path: string, method = "GET", body?: unknown) => fetch(base + path, {
  method, headers: { Authorization: `Bearer ${user.token}`, "Content-Type": "application/json" },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }), redirect: "error", signal: AbortSignal.timeout(30000),
});
async function api(user: User, path: string, method = "GET", body?: unknown) {
  const response = await request(user, path, method, body);
  assert.ok(response.ok, `${method} ${path} returned ${response.status}`); return response.json();
}
async function inbox(user: User) {
  const { groups } = await api(user, "/api/groups");
  for (const group of groups) groupIds.add(group.id);
  return groups as { id: string; is_direct: boolean; invite_code: string | null; name: string }[];
}
async function group(user: User, name: string) {
  const response = await api(user, "/api/groups", "POST", { name, client_id: randomUUID() });
  groupIds.add(response.group.id);
  await api(user, `/api/groups/${response.group.id}/state`, "POST", { action: "group.settings", data: { agent_paused: true, proactive_suggestions: false } });
  return response.group as { id: string; invite_code: string };
}
async function send(user: User, groupId: string, body: string) {
  return (await api(user, `/api/groups/${groupId}/messages`, "POST", { body, client_id: randomUUID() })).message;
}
async function activeJob(groupId: string, messageId: string) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const job = checked(await db.from("agent_jobs").select("id,status,attempts,lease_until").eq("group_id", groupId).eq("message_id", messageId).maybeSingle());
    if (job?.status === "running" && Date.parse(job.lease_until) > Date.now()) return job;
    if (job?.status === "completed") throw new Error("The real turn completed before its scoped read could be inspected.");
    await sleep(100);
  }
  throw new Error("The real turn did not acquire an active lease.");
}
async function settleFixtureJobs() {
  if (!groupIds.size) return;
  const deadline = Date.now() + 60000;
  for (;;) {
    const pending = checked(await db.from("agent_jobs").select("id,result,status").in("group_id", [...groupIds]).in("status", ["queued", "running"])) ?? [];
    if (!pending.length) return;
    if (Date.now() >= deadline) {
      for (const job of pending) {
        const sessionId = job.result ? JSON.parse(job.result).sessionId : null;
        if (sessionId && job.status === "running") {
          const client = new Client({ host: base, redirect: "error", auth: { bearer: env("PAL_INTERNAL_SECRET") }, headers: { "x-pal-job-id": job.id } });
          try { await client.sessions.attach(sessionId).cancel({ signal: AbortSignal.timeout(10000) }); }
          catch { /* Revoking the exact fixture lease below still prevents tool writes. */ }
        }
      }
      checked(await db.from("agent_jobs").update({ status: "cancelled", lease_until: null, completed_at: new Date().toISOString() })
        .in("id", pending.map(job => job.id)).in("group_id", [...groupIds]).in("status", ["queued", "running"]));
      console.log("Cleanup: boundedly cancelled unfinished jobs belonging only to temporary test groups.");
      return;
    }
    await sleep(1000);
  }
}
async function subscribeMessages(user: User, groupId: string, received: string[]) {
  await user.client.realtime.setAuth(user.token);
  await new Promise<void>((resolve, reject) => {
    let joined = false, postgresReady = false;
    const timeout = setTimeout(() => reject(new Error("Authenticated Postgres Changes subscription timed out.")), 45000);
    const ready = () => { if (joined && postgresReady) { clearTimeout(timeout); resolve(); } };
    user.client.channel(`pal-check-${randomUUID()}`)
      .on("system", {}, payload => {
        if (payload.extension !== "postgres_changes") return;
        if (payload.status === "ok") { postgresReady = true; ready(); }
        else if (payload.status === "error") { clearTimeout(timeout); reject(new Error("Authenticated Postgres Changes subscription failed.")); }
      })
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "messages", filter: `group_id=eq.${groupId}` }, payload => {
        if (typeof payload.new.id === "string") received.push(payload.new.id);
      }).subscribe(status => {
        if (status === "SUBSCRIBED") { joined = true; ready(); }
        else if (["CHANNEL_ERROR", "TIMED_OUT"].includes(status)) { clearTimeout(timeout); reject(new Error("Authenticated Realtime join failed.")); }
      });
  });
}
try {
  const owner = await provision("owner"), member = await provision("member"), outsider = await provision("outsider");
  const repeated = await Promise.all(Array.from({ length: 4 }, () => inbox(owner)));
  const direct = repeated[0][0];
  assert.ok(direct.is_direct); assert.equal(direct.invite_code, null);
  assert.ok(repeated.every(groups => groups.length === 1 && groups[0].id === direct.id));
  assert.equal(checked(await db.from("groups").select("id").eq("creator_id", owner.id).eq("is_direct", true))?.length, 1);
  const otherDirect = (await inbox(outsider))[0];
  assert.notEqual(otherDirect.id, direct.id);
  const directState = await api(owner, `/api/groups/${direct.id}/state`);
  assert.equal(directState.settings.is_direct, true); assert.equal(directState.members.length, 1);
  assert.equal(directState.members[0].user_id, owner.id);
  const rawDirect = checked(await db.from("groups").select("invite_code").eq("id", direct.id).single()); assert.ok(rawDirect);
  assert.equal((await request(outsider, "/api/groups/join", "POST", { invite_code: rawDirect.invite_code })).status, 403);
  assert.equal((await request(outsider, `/api/groups/${direct.id}/state`)).status, 403);
  assert.equal((await request(outsider, `/api/groups/${direct.id}/messages`)).status, 403);
  assert.equal((await request(outsider, `/api/groups/${direct.id}/messages`, "POST", { body: "intrusion", client_id: randomUUID() })).status, 403);
  assert.ok((await outsider.client.rpc("ensure_pal_direct", { p_user_id: owner.id })).error, "Caller cannot supply another user to the direct-room RPC.");
  console.log("PASS: concurrent inbox reads create one owner-only Pal room, with protected invitation and message access.");
  const lunch = await group(owner, "Basel picnic"), ride = await group(member, "Museum bikes"), hidden = await group(outsider, "Private outsider topic");
  await api(member, "/api/groups/join", "POST", { invite_code: lunch.invite_code });
  await api(owner, "/api/groups/join", "POST", { invite_code: ride.invite_code });
  const realtimeEvents: string[][] = [[], [], []];
  await Promise.all([owner, member, outsider].map((user, index) => subscribeMessages(user, lunch.id, realtimeEvents[index])));
  const sourceNote = await send(member, lunch.id, "Picnic budget: 47 CHF. Bring the cobalt blanket.");
  const deliveryDeadline = Date.now() + 15000;
  while ((!realtimeEvents[0].includes(sourceNote.id) || !realtimeEvents[1].includes(sourceNote.id)) && Date.now() < deliveryDeadline) await sleep(100);
  assert.ok(realtimeEvents[0].includes(sourceNote.id), "Owner receives the actual authenticated message event.");
  assert.ok(realtimeEvents[1].includes(sourceNote.id), "The other member receives the same actual message event.");
  await sleep(2000);
  assert.equal(realtimeEvents[2].length, 0, "An authenticated outsider receives no protected message event.");
  await Promise.all(users.map(user => user.client.removeAllChannels()));
  console.log("PASS: actual authenticated Realtime INSERT reaches both members and no outsider.");
  await send(member, ride.id, "Bike pickup at 18:15. Bring tangerine helmets.");
  const hiddenFact = `hidden-only-${randomUUID()}`; await send(outsider, hidden.id, hiddenFact);
  const current = await inbox(owner); assert.equal(current[0].id, direct.id);
  assert.equal(current.filter(group => !group.is_direct).length, 2); assert.equal(current.some(group => group.id === hidden.id), false);
  const asked = await send(owner, direct.id, "Summarize the latest plans across my group chats. Include each group's name, budget or pickup time, and what we should bring.");
  const started = Date.now(), deadline = started + 180000; let reply = "", completed = false;
  while (Date.now() < deadline) {
    const job = checked(await db.from("agent_jobs").select("status,result,explicit_mention,run_after,created_at,attempts")
      .eq("group_id", direct.id).eq("message_id", asked.id).maybeSingle());
    if (job) {
      assert.equal(job.explicit_mention, true, "A normal DM prompt addresses Pal immediately.");
      assert.ok(Date.parse(job.run_after) - Date.parse(job.created_at) < 2000, "Direct prompts skip shared passive debounce.");
      if (job.status === "completed") {
        assert.ok(job.result && JSON.parse(job.result).sessionId, "A real durable Eve turn completed.");
        const messages = (await api(owner, `/api/groups/${direct.id}/messages`)).messages;
        reply = messages.filter((message: { role: string; created_at: string }) => message.role === "pal" && message.created_at >= asked.created_at)
          .map((message: { body: string }) => message.body).join("\n");
        completed = true; break;
      }
      if (job.status === "failed" && job.attempts >= 3) throw new Error("Direct Pal job failed repeatedly.");
    }
    await sleep(1500);
  }
  assert.ok(completed, "Real private Pal summary did not finish in time.");
  for (const fact of ["basel", "museum", "47", "cobalt", "tangerine"]) assert.ok(reply.toLowerCase().includes(fact), `The real summary is missing ${fact}.`);
  assert.match(reply, /18:15|6:15\s*p\.?m/i, "The real summary preserves the pickup time.");
  assert.equal(reply.includes(hiddenFact), false);
  const outsiderRows = checked(await outsider.client.from("messages").select("id").eq("group_id", direct.id)); assert.equal(outsiderRows?.length, 0);
  const sharedAfter = checked(await db.from("messages").select("id").in("group_id", [lunch.id, ride.id])); assert.equal(sharedAfter?.length, 2, "Private summaries never post to the source groups.");
  console.log("PASS: real Eve/OpenAI Pal DM reads and summarizes two authorized chats without leaking outsider context or writing to shared rooms.");
  checked(await db.from("group_members").delete().eq("group_id", ride.id).eq("user_id", owner.id));
  assert.equal((await request(owner, `/api/groups/${ride.id}/state`)).status, 403);
  const askRemoved = await send(owner, direct.id, "Look up the latest messages from Museum bikes using a fresh cross-group read. Report if I no longer have access.");
  const liveDirect = await activeJob(direct.id, askRemoved.id);
  const fresh = checked(await db.rpc("pal_read_across_groups", { p_job_id: liveDirect.id, p_attempt: liveDirect.attempts, p_offset: 0, p_query: "Museum bikes" }));
  assert.equal(fresh.groups.some((group: { id: string }) => group.id === ride.id), false, "Fresh context stops when source membership is removed; existing DM history stays legitimately readable.");
  await api(owner, `/api/groups/${lunch.id}/state`, "POST", { action: "group.settings", data: { agent_paused: false } });
  const sharedQuestion = await send(owner, lunch.id, "@Pal summarize this picnic chat only.");
  const liveShared = await activeJob(lunch.id, sharedQuestion.id);
  const deniedShared = await db.rpc("pal_read_across_groups", { p_job_id: liveShared.id, p_attempt: liveShared.attempts, p_offset: 0, p_query: null });
  assert.equal(deniedShared.error?.code, "42501", "A real shared-group job cannot use private cross-chat context.");
  console.log("PASS: fresh context honors removed memberships and denies cross-chat reads from an actual shared-group job.");
} finally {
  // Only temporary identities and their own newly-created groups are removed.
  if (users.length) {
    const ownedGroups = checked(await db.from("groups").select("id").in("creator_id", users.map(user => user.id)));
    for (const group of ownedGroups ?? []) groupIds.add(group.id);
  }
  await settleFixtureJobs();
  for (const groupId of groupIds) checked(await db.from("groups").delete().eq("id", groupId));
  for (const user of users) {
    await user.client.removeAllChannels();
    await user.client.auth.signOut({ scope: "local" });
    const removed = await db.auth.admin.deleteUser(user.id); assert.ifError(removed.error);
  }
}
