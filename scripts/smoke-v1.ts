import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";
import { createClient } from "@supabase/supabase-js";
import { admin, checked, env } from "../lib/db";

// Reuse isolated demo identities; never create accounts or print credentials.
process.loadEnvFile(".env.demo.local");
const base = env("PAL_BASE_URL").replace(/\/$/, "");
const db = admin();
const users = await Promise.all(["ALICE", "BOB", "OUTSIDER"].map(async name => {
  const client = createClient(env("SUPABASE_URL"), env("SUPABASE_PUBLISHABLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.signInWithPassword({
    email: env(`DEMO_${name}_EMAIL`), password: env(`DEMO_${name}_PASSWORD`),
  });
  assert.ifError(error);
  assert.ok(data.session && data.user, "Existing demo identity signs in.");
  return { name, client, id: data.user.id, token: data.session.access_token };
}));
const [alice, bob, outsider] = users;
type User = typeof alice;
type Row = Record<string, any>;
const later = (seconds: number) => new Date(Date.now() + seconds * 1000).toISOString();

async function request(user: User, path: string, method = "GET", body?: unknown) {
  return fetch(`${base}${path}`, {
    method, headers: { Authorization: `Bearer ${user.token}`, "Content-Type": "application/json" },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
}
async function api(user: User, path: string, method = "GET", body?: unknown): Promise<any> {
  const response = await request(user, path, method, body);
  assert.ok(response.ok, `${method} ${path} returned ${response.status}`);
  return response.json();
}
async function denied(user: User, path: string, method = "GET", body?: unknown) {
  const response = await request(user, path, method, body);
  assert.ok(response.status >= 400, `Unauthorized/invalid ${method} ${path} must be rejected.`);
}
const { group } = await api(alice, "/api/groups", "POST", { name: `Pal v1 check ${new Date().toISOString().slice(0, 16)}` });
await writeFile(".env.demo.v1.local", `DEMO_V1_GROUP_ID=${group.id}\nDEMO_V1_INVITE_CODE=${group.invite_code}\n`, { mode: 0o600 });
const statePath = `/api/groups/${group.id}/state`;
const messagesPath = `/api/groups/${group.id}/messages`;
const action = (user: User, name: string, data: Row) => api(user, statePath, "POST", { action: name, data });
const state = () => api(bob, statePath) as Promise<Row>;
async function send(user: User, body: string, extra: Row = {}) {
  return (await api(user, messagesPath, "POST", { body, client_id: randomUUID(), ...extra })).message as Row;
}
await api(bob, "/api/groups/join", "POST", { invite_code: group.invite_code });
await action(alice, "group.settings", { timezone: "America/Los_Angeles", agent_paused: true, proactive_suggestions: false });
await api(alice, "/api/profile", "PATCH", { display_name: "Alice", notification_preferences: { enabled: true } });
await api(bob, "/api/profile", "PATCH", { display_name: "Bob", notifications_enabled: true });
assert.equal((await api(bob, "/api/profile")).profile.display_name, "Bob");
const initial = await state();
assert.equal(initial.settings.timezone, "America/Los_Angeles");
assert.deepEqual(new Set(initial.members.map((m: Row) => m.display_name)), new Set(["Alice", "Bob"]));
await denied(outsider, statePath);
await denied(outsider, messagesPath);
assert.equal(checked(await outsider.client.from("messages").select("id").eq("group_id", group.id))?.length, 0);
await denied(alice, statePath, "POST", { action: "plan.confirm", data: { id: randomUUID(), requester_id: bob.id } });
await denied(alice, "/api/profile", "PATCH", { user_id: bob.id, display_name: "Impersonator" });
await denied(alice, "/api/devices", "POST", { token: "a".repeat(65), environment: "sandbox" });
const integrationDenied = await alice.client.rpc("pal_integration_state", { p_kind: "google_connections", p_limit: 10 });
assert.ok(integrationDenied.error, "Members cannot inspect private OAuth tokens.");
console.log("PASS: authenticated member profiles, group timezone, isolation, and private integration boundary.");

const original = await send(alice, "I personally prefer vegetarian food.");
const replyClient = randomUUID();
const replyBody = { body: "I can bring snacks.", client_id: replyClient, reply_to_id: original.id };
await api(bob, messagesPath, "POST", replyBody);
await api(bob, messagesPath, "POST", replyBody);
let transcript = (await api(alice, messagesPath)).messages as Row[];
assert.equal(transcript.filter(m => m.client_id === replyClient).length, 1);
assert.equal(transcript.find(m => m.client_id === replyClient)?.reply_to_id, original.id);
const reaction = { message_id: original.id, emoji: "👍", source_key: `smoke:${randomUUID()}` };
await action(bob, "reaction.toggle", reaction);
await action(bob, "reaction.toggle", reaction);
assert.equal((await state()).reactions.filter((r: Row) => r.user_id === bob.id && r.message_id === original.id).length, 1);
const inbox = (await api(bob, "/api/groups")).groups.find((g: Row) => g.id === group.id);
assert.ok(inbox.unread_count >= 1);
await action(bob, "group.read", { message_id: transcript.at(-1)!.id });
assert.equal((await api(bob, "/api/groups")).groups.find((g: Row) => g.id === group.id).unread_count, 0);
const newer = await send(alice, "New unread message after the selected read marker.");
await action(bob, "group.read", { message_id: original.id });
assert.equal((await api(bob, "/api/groups")).groups.find((g: Row) => g.id === group.id).unread_count, 1, "Stale read receipt cannot mark newer incoming message read.");
const pausedJobs = checked(await db.from("agent_jobs").select("id").eq("group_id", group.id));
assert.equal(pausedJobs?.length, 0, "Paused Pal creates no new agent jobs.");
console.log("PASS: reply/client retry identity, idempotent reactions, monotonic unread markers, and paused Pal.");

// Verify URL dedup independently of a provider extracting this generic public page.
const shared = await send(alice, "Saved link https://example.com/pal-smoke?utm_source=alice");
await send(bob, "Same link https://example.com/pal-smoke?utm_source=bob");
let current = await state();
const source = current.sources.find((s: Row) => s.canonical_url === "https://example.com/pal-smoke");
assert.ok(source);
assert.equal(current.sources.filter((s: Row) => s.canonical_url === source.canonical_url).length, 1);
assert.deepEqual(new Set(source.contributors.map((c: Row) => c.user_id)), new Set([alice.id, bob.id]));
transcript = (await api(alice, messagesPath)).messages;
assert.equal(transcript.filter(m => m.cards.some((c: Row) => c.type === "place" && c.entity_id === source.id)).length, 1);

let candidate: Row;
const mapsResponse = await request(alice, "/api/places/search?q=Ferry%20Building%20San%20Francisco");
if (mapsResponse.ok) {
  candidate = (await mapsResponse.json()).places[0];
  assert.ok(candidate?.provider_id && Number.isFinite(candidate.latitude), "Apple Maps returns a verified candidate.");
} else {
  assert.equal(mapsResponse.status, 503);
  // A named real-world fixture exercises database identity without claiming a provider call succeeded.
  candidate = { name: "Ferry Building", address: "1 Ferry Building, San Francisco, CA", latitude: 37.79549, longitude: -122.3937, provider: "apple", provider_id: "smoke-fixture:ferry-building" };
  console.log("SKIP: live Apple Maps provider unavailable; place dedup uses an explicit known-location fixture.");
}
const placeData = Object.fromEntries(["name", "address", "latitude", "longitude", "provider", "provider_id", "website"].filter(k => candidate[k] !== undefined).map(k => [k, candidate[k]]));
const place = await action(alice, "place.save", { ...placeData, source_id: source.id, source_key: `smoke:${randomUUID()}` });
const samePlace = await action(bob, "place.save", { ...placeData, source_id: source.id, source_key: `smoke:${randomUUID()}` });
assert.equal(place.id, samePlace.id);
current = await state();
assert.equal(current.places.filter((p: Row) => p.id === place.id).length, 1);
assert.deepEqual(new Set(current.places.find((p: Row) => p.id === place.id).contributors.map((c: Row) => c.user_id)), new Set([alice.id, bob.id]));
const { group: other } = await api(outsider, "/api/groups", "POST", { name: "Pal isolated smoke group" });
const outsidePlace = checked(await outsider.client.rpc("pal_action", { p_group_id: other.id, p_action: "place.save", p_data: { ...placeData, source_key: randomUUID() } }));
await denied(alice, statePath, "POST", { action: "plan.create", data: { title: "Cross-group place attack", place_id: outsidePlace.id, starts_at: later(172800) } });
await denied(alice, statePath, "POST", { action: "source.update", data: { id: source.id, place_ids: [outsidePlace.id] } });
console.log("PASS: shared source/card and saved-place dedup retain both contributors; nested references stay in their group.");

const poll = await action(alice, "poll.create", {
  kind: "time", question: "What time works?", deadline_at: later(600),
  options: [{ id: "fri", label: "Friday", starts_at: later(172800) }, { id: "sat", label: "Saturday", starts_at: later(259200) }],
  source_key: `smoke:${randomUUID()}`,
});
await action(alice, "poll.vote", { id: poll.id, option_ids: ["fri"] });
current = await state();
assert.equal(current.polls.find((p: Row) => p.id === poll.id).votes.some((v: Row) => v.user_id === bob.id), false, "Unknown member availability stays unanswered.");
await action(alice, "poll.vote", { id: poll.id, option_ids: ["sat"] });
assert.deepEqual((await state()).polls.find((p: Row) => p.id === poll.id).votes.filter((v: Row) => v.user_id === alice.id).map((v: Row) => v.option_id), ["sat"]);
await action(bob, "poll.vote", { id: poll.id, option_ids: ["fri", "sat"] });
assert.ok((await state()).reminders.filter((r: Row) => r.poll_id === poll.id).every((r: Row) => r.status === "cancelled"));
await denied(alice, statePath, "POST", { action: "poll.vote", data: { id: poll.id, option_ids: ["invented"] } });
const ownMemory = await action(alice, "memory.save", { kind: "preference", key: "food", value: "vegetarian", source_message_id: original.id });
assert.equal(ownMemory.user_id, alice.id);
await denied(bob, statePath, "POST", { action: "memory.save", data: { kind: "preference", key: "food", value: "meat", source_message_id: original.id } });
await denied(bob, statePath, "POST", { action: "memory.delete", data: { id: ownMemory.id } });
const availability = await action(bob, "memory.save", { kind: "availability", key: "smoke_window", value: "Available for this short test", expires_at: later(3) });
await sleep(3500);
assert.equal((await state()).memories.some((m: Row) => m.id === availability.id), false, "Expired availability is absent from current group state.");
console.log("PASS: editable votes preserve unanswered members, stop obsolete nudges, and attributed memory expires.");

const draftData = { title: "V1 planning check", place_id: place.id, starts_at: later(172800), ends_at: later(176400), source_key: `smoke:${randomUUID()}` };
const draft = await action(alice, "plan.create", draftData);
assert.equal((await action(alice, "plan.create", draftData)).id, draft.id, "Draft retry is idempotent.");
assert.equal(draft.status, "draft");
assert.equal((await state()).plans.find((p: Row) => p.id === draft.id).attendees.length, 0);
const agentConfirm = await db.rpc("pal_agent_action", { p_group_id: group.id, p_requester_id: alice.id, p_action: "plan.confirm", p_data: { id: draft.id, source_key: randomUUID() } });
assert.ok(agentConfirm.error, "Agent service action cannot confirm for people.");
await action(alice, "plan.confirm", { id: draft.id });
await action(alice, "plan.rsvp", { id: draft.id, status: "going" });
await action(bob, "plan.rsvp", { id: draft.id, status: "maybe" });
let plan = (await state()).plans.find((p: Row) => p.id === draft.id);
assert.equal(plan.attendees.find((a: Row) => a.user_id === alice.id).status, "going");
assert.equal(plan.attendees.find((a: Row) => a.user_id === bob.id).status, "maybe");
const connections = checked(await db.rpc("pal_integration_state", { p_kind: "google_connections", p_limit: 200 })) as Row[];
const syncRows = async () => (checked(await db.rpc("pal_integration_state", { p_kind: "google_sync_items", p_limit: 200 })) as Row[]).filter(r => r.plan_id === draft.id);
let sync = await syncRows();
const aliceConnected = connections.some(c => c.user_id === alice.id && c.status === "connected");
assert.equal(sync.length, aliceConnected ? 1 : 0, "Only an actually connected, going member has a calendar mapping.");
assert.ok(sync.every(r => r.user_id === alice.id));
await action(alice, "plan.rsvp", { id: draft.id, status: "going" });
assert.equal((await syncRows()).length, sync.length, "RSVP retries do not create duplicate calendar mappings.");
if (!aliceConnected) console.log("SKIP: demo Alice has not authorized Google OAuth; no external calendar event claimed.");
const oldReminders = (await state()).reminders.filter((r: Row) => r.plan_id === draft.id && r.status === "scheduled").map((r: Row) => r.id);
assert.ok(oldReminders.length >= 1);
await action(alice, "plan.update", { id: draft.id, starts_at: later(259200), ends_at: later(262800) });
current = await state();
plan = current.plans.find((p: Row) => p.id === draft.id);
assert.equal(plan.attendees.length, 0, "Rescheduling requires fresh personal RSVP choices.");
assert.ok(current.reminders.filter((r: Row) => oldReminders.includes(r.id)).every((r: Row) => r.status === "cancelled"));
assert.ok((await syncRows()).every(r => !r.sync_required && r.state === "remove"));
await action(alice, "plan.rsvp", { id: draft.id, status: "going" });
await action(alice, "plan.cancel", { id: draft.id });
assert.ok((await state()).reminders.filter((r: Row) => r.plan_id === draft.id).every((r: Row) => r.status !== "scheduled"));
assert.ok((await syncRows()).every(r => !r.sync_required && r.state === "remove"));
console.log("PASS: draft/confirm/personal RSVP, calendar mapping uniqueness, reschedule reset, and cancellation cleanup.");

await action(alice, "group.settings", { agent_paused: false });
const beforePlans = new Set((await state()).plans.map((p: Row) => p.id));
// A direct request without @Pal proves observation/debounce rather than explicit mention triggering.
const observed = await send(bob, `I personally prefer quiet places. Please remember my preference and draft a plan titled "Quiet team catch-up" starting ${later(345600)}. Keep it a draft and leave everyone's RSVP unanswered.`);
let realJob: Row | undefined;
for (let attempt = 0; attempt < 60; attempt++) {
  await sleep(2000);
  const trigger = checked(await db.from("agent_jobs").select("id,status,coalesced_into,last_error").eq("message_id", observed.id).single()) as Row;
  const jobId = trigger.coalesced_into || trigger.id;
  realJob = checked(await db.from("agent_jobs").select("id,status,result,last_error,explicit_mention,batch_message_ids").eq("id", jobId).single()) as Row;
  if (realJob.status === "failed") throw new Error(`Real Eve task failed: ${realJob.last_error}`);
  if (realJob.status === "completed") break;
}
assert.equal(realJob?.status, "completed", "Observed human request completed through durable worker.");
assert.equal(realJob?.explicit_mention, false);
assert.ok(JSON.parse(realJob!.result).sessionId, "Real Eve durable session persisted.");
current = await state();
const generated = current.plans.filter((p: Row) => !beforePlans.has(p.id));
assert.ok(generated.some((p: Row) => p.title.includes("Quiet") && p.status === "draft" && p.attendees.length === 0), "Real Pal tool wrote a draft without confirming or impersonating attendees.");
assert.ok(current.memories.some((m: Row) => m.user_id === bob.id && m.source_message_id === observed.id && /quiet/i.test(m.value)), "Real Pal attributed observed preference to its actual speaker.");
console.log("PASS: no-@Pal observation ran a real Eve/OpenAI task and saved Bob's own memory plus an unconfirmed draft.");

const oldDue = later(6);
const reminder = await action(alice, "reminder.create", { body: "Closed-client v1 reminder", due_at: oldDue, timezone: "America/Los_Angeles", target_user_ids: [bob.id], source_key: `smoke:${randomUUID()}` });
const updatedDue = later(15);
const updated = await action(alice, "reminder.update", { id: reminder.id, due_at: updatedDue });
assert.ok(updated.version > reminder.version);
await Promise.all(users.map(user => user.client.auth.signOut()));
console.log("All test clients signed out. Checking durable maintenance and versioned delivery.");
await sleep(Math.max(1, Date.parse(oldDue) + 500 - Date.now()));
checked(await db.rpc("pal_maintenance"));
assert.equal(checked(await db.from("reminders").select("status").eq("id", reminder.id).single())?.status, "scheduled", "Old due time no longer fires after reschedule.");
await sleep(Math.max(1, Date.parse(updatedDue) + 500 - Date.now()));
checked(await db.rpc("pal_maintenance"));
checked(await db.rpc("pal_maintenance"));
const completed = checked(await db.from("reminders").select("status,version").eq("id", reminder.id).single());
assert.ok(completed);
assert.equal(completed.status, "completed");
const deliveries = checked(await db.from("messages").select("id,created_at,source_key").eq("group_id", group.id).like("source_key", `reminder:${reminder.id}:%`));
assert.ok(deliveries);
assert.equal(deliveries.length, 1, "Closed-client repeated maintenance posts exactly once.");
assert.equal(deliveries[0].source_key, `reminder:${reminder.id}:${updated.version}`);
assert.ok(Date.parse(deliveries[0].created_at) >= Date.parse(updatedDue));
const pushes = checked(await db.rpc("pal_integration_state", { p_kind: "push_outbox", p_limit: 200 })) as Row[];
assert.deepEqual(pushes.filter(p => p.message_id === deliveries[0].id).map(p => p.user_id), [bob.id], "Targeted reminder creates exactly Bob's notification outbox entry.");
console.log("PASS: rescheduled reminder survives closed clients and produces one versioned delivery; APNs receipt requires a real registered device.");
console.log(`V1 smoke complete. Isolated group ${group.id}; invite ${group.invite_code}. Existing demo credentials were reused and never printed.`);
