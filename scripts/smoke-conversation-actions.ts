import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";
import { createClient } from "@supabase/supabase-js";
import { Client } from "eve/client";
import { admin, checked, env } from "../lib/db";

// Run after the mention/output migration AND matching canonical build are deployed.
// node --env-file=.env --import tsx scripts/smoke-conversation-actions.ts https://pal-jade.vercel.app
assert.ok(process.argv[2], "Supply the deployed origin explicitly.");
const origin = new URL(process.argv[2]);
assert.ok(["http:", "https:"].includes(origin.protocol) && !origin.username && !origin.password);
const base = origin.origin, db = admin(), groups = new Set<string>();
type User = { id: string; token: string; client: ReturnType<typeof admin> };
type Mention = { type: "user"; user_id: string } | { type: "pal" };
type Message = { id: string; role: string; body: string; client_id: string | null; reply_to_id: string | null;
  created_at: string; mentions: Mention[]; cards: { type: string; entity_id: string }[]; emotion?: string;
  reply?: { id: string; body: string; role: string; sender_id: string | null } | null };
type Plan = { id: string; title: string; status: string; version: number; starts_at: string;
  attendees: { user_id: string; status: string }[] };
type Poll = { id: string; kind: string; status: string; deadline_at: string;
  options: { id: string; label: string; place_id?: string; starts_at?: string }[];
  responses: { user_id: string; option_ids: string[] }[] };
const users: User[] = [], trace = new Map<string, unknown>();
let groupId: string | undefined;
async function provision(name: string) {
  const email = `conversation-actions-${randomUUID()}@pal-demo.example`, password = randomUUID() + randomUUID();
  const created = await db.auth.admin.createUser({ email, password, email_confirm: true });
  assert.ifError(created.error); assert.ok(created.data.user);
  const client = createClient(env("SUPABASE_URL"), env("SUPABASE_PUBLISHABLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false } });
  const signed = await client.auth.signInWithPassword({ email, password });
  if (signed.error || !signed.data.session) { await db.auth.admin.deleteUser(created.data.user.id); throw new Error("Temporary fixture sign-in failed."); }
  const user = { id: created.data.user.id, token: signed.data.session.access_token, client }; users.push(user);
  await api(user, "/api/profile", "PATCH", { display_name: name }); return user;
}
const request = (user: User, path: string, method = "GET", body?: unknown) => fetch(base + path, {
  method, redirect: "error", signal: AbortSignal.timeout(30000),
  headers: { authorization: `Bearer ${user.token}`, "content-type": "application/json" },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }),
});
async function api(user: User, path: string, method = "GET", body?: unknown) {
  const response = await request(user, path, method, body);
  assert.ok(response.ok, `${method} ${path} returned ${response.status}.`); return response.json();
}
async function create(user: User, name: string) {
  const { group } = await api(user, "/api/groups", "POST", { name, client_id: randomUUID() }); groups.add(group.id);
  await api(user, `/api/groups/${group.id}/state`, "POST", { action: "group.settings", data: { agent_paused: true, proactive_suggestions: false, timezone: "UTC" } });
  return group as { id: string; invite_code: string };
}
const transcript = async (user: User) => (await api(user, `/api/groups/${groupId}/messages`)).messages as Message[];
const state = (user: User) => api(user, `/api/groups/${groupId}/state`);
const action = (user: User, name: string, data: unknown) => api(user, `/api/groups/${groupId}/state`, "POST", { action: name, data });
async function send(user: User, body: string, extra: Record<string, unknown> = {}) {
  return (await api(user, `/api/groups/${groupId}/messages`, "POST", { body, client_id: randomUUID(), ...extra })).message as Message;
}
async function snapshot(jobId: string, sessionId: string) {
  const client = new Client({ host: base, redirect: "error", auth: { bearer: env("PAL_INTERNAL_SECRET") }, headers: { "x-pal-job-id": jobId } });
  try {
    for await (const event of client.sessions.attach(sessionId).stream({ startIndex: 0, follow: false,
      signal: AbortSignal.timeout(3000), streamReconnectPolicy: { reconnect: false } })) {
      if (["actions.requested", "action.result", "result.completed"].includes(event.type)) trace.set(`${jobId}:${event.meta.id}`, { job_id: jobId, type: event.type, data: event.data });
    }
  } catch { /* Read-only diagnostics never restart the real turn. */ }
}
async function waitForTurn(source: Message) {
  const deadline = Date.now() + 240000;
  while (Date.now() < deadline) {
    const trigger = checked(await db.from("agent_jobs").select("id,coalesced_into").eq("group_id", groupId!).eq("message_id", source.id).maybeSingle());
    if (trigger) {
      const job = checked(await db.from("agent_jobs").select("id,status,result,attempts,explicit_mention,run_after,created_at,completed_at,batch_message_ids")
        .eq("id", trigger.coalesced_into || trigger.id).single()); assert.ok(job);
      assert.equal(job.explicit_mention, true, "Structured Pal mentions and replies to Pal address it directly.");
      assert.ok(Date.parse(job.run_after) - Date.parse(job.created_at) < 2000, "An actual direct request skips passive debounce.");
      if (job.status === "running" && job.result) await snapshot(job.id, JSON.parse(job.result).sessionId);
      if (job.status === "completed") {
        assert.ok(JSON.parse(job.result).sessionId, "Real Eve/OpenAI ran rather than a scripted response.");
        assert.ok(job.batch_message_ids.includes(source.id));
        console.log(`Real Eve turn: ${((Date.parse(job.completed_at) - Date.parse(source.created_at)) / 1000).toFixed(1)} seconds from source to completion; ${job.attempts} attempt(s).`);
        const replies = checked(await db.from("messages").select("id,body,card,emotion,reply_to_id,mentions,source_key,created_at")
          .eq("group_id", groupId!).eq("role", "pal").like("source_key", `job:${job.id}%`)
          .order("created_at").order("id")) ?? [];
        return { job, replies };
      }
      if (job.status === "failed" && job.attempts >= 3) throw new Error("Real conversation-actions turn failed repeatedly.");
    }
    await sleep(1000);
  }
  throw new Error("Real conversation-actions turn did not finish within four minutes.");
}
try {
  const alice = await provision("Alice"), bob = await provision("Bob"), outsider = await provision("Outsider");
  const group = await create(alice, "Pal temporary message actions"); groupId = group.id;
  await api(bob, "/api/groups/join", "POST", { invite_code: group.invite_code });
  const other = await create(outsider, "Pal temporary outside source");
  const otherSource = (await api(outsider, `/api/groups/${other.id}/messages`, "POST", { body: "Private source outside the tested group.", client_id: randomUUID() })).message;
  const clientID = randomUUID(), firstBody = { body: "@Bob, Friday works for me.", client_id: clientID, mentions: [{ type: "user", user_id: bob.id }] };
  const first = (await api(alice, `/api/groups/${groupId}/messages`, "POST", firstBody)).message as Message;
  await api(alice, `/api/groups/${groupId}/messages`, "POST", firstBody);
  const humanReply = await send(bob, "Friday works for me too.", { reply_to_id: first.id });
  const rows = await transcript(bob);
  assert.equal(rows.filter(row => row.client_id === clientID).length, 1, "Same client retry creates one mentioned message.");
  assert.deepEqual(rows.find(row => row.id === first.id)?.mentions, [{ type: "user", user_id: bob.id }]);
  assert.equal(rows.find(row => row.id === humanReply.id)?.reply_to_id, first.id);
  assert.equal(rows.find(row => row.id === humanReply.id)?.reply?.id, first.id);
  assert.equal(rows.find(row => row.id === humanReply.id)?.reply?.body, firstBody.body);
  for (const extra of [{ mentions: [{ type: "user", user_id: outsider.id }] }, { reply_to_id: otherSource.id }]) {
    const rejected = await request(alice, `/api/groups/${groupId}/messages`, "POST", { body: "This target is outside our group.", client_id: randomUUID(), ...extra });
    assert.ok([400, 403].includes(rejected.status), "Cross-group reply and mention targets must fail closed.");
  }
  assert.equal((await request(outsider, `/api/groups/${groupId}/messages`)).status, 403);
  console.log("PASS: user mention/reply identities survive fetch and retry; outsider targets and reads are rejected.");

  const when = new Date(Date.now() + 4 * 86400000); when.setUTCHours(19, 0, 0, 0);
  const draft = await action(alice, "plan.create", { title: "Riverside dinner", starts_at: when.toISOString(),
    ends_at: new Date(when.getTime() + 3600000).toISOString(), source_key: `smoke:${randomUUID()}` });
  await action(alice, "plan.confirm", { id: draft.id });
  await action(alice, "group.settings", { agent_paused: false });
  const addressed = await send(alice, "Please send exactly two separate short chat messages: first acknowledge Friday, then ask Bob which restaurant he prefers and mention him. Both should reply to this message.", { mentions: [{ type: "pal" }], reply_to_id: humanReply.id });
  const multiple = await waitForTurn(addressed);
  assert.equal(multiple.replies.length, 2, "The actual model produces two independently persisted chat messages.");
  assert.ok(multiple.replies.every(row => row.body.trim() && row.reply_to_id === addressed.id && row.card === null));
  const mentioned = multiple.replies.find(row => row.mentions.some((mention: Mention) => mention.type === "user" && mention.user_id === bob.id));
  assert.ok(mentioned, "The real outgoing message persists Bob's member ID rather than only printing his name.");
  assert.match(mentioned.body, /@Bob\b/i, "The actual mention has readable display-name text.");
  const firstFetch = (await transcript(bob)).filter(row => multiple.replies.some(reply => reply.id === row.id));
  const secondFetch = (await transcript(alice)).filter(row => multiple.replies.some(reply => reply.id === row.id));
  assert.deepEqual(firstFetch, secondFetch, "Both devices see stable output identities, ordering, mentions and replies.");
  assert.equal(checked(await db.rpc("complete_agent_job_with_outputs", {
    p_job_id: multiple.job.id, p_attempt: multiple.job.attempts,
    p_outputs: [{ body: "A completed turn must never add another bubble.", emotion: "neutre", mentions: [], card: null }], p_result: null,
  })), false, "A completion retry cannot append or replace the original bubbles.");
  assert.deepEqual((await transcript(alice)).filter(row => multiple.replies.some(reply => reply.id === row.id)), firstFetch);
  assert.equal((checked(await db.from("messages").select("id").eq("group_id", groupId).like("source_key", `job:${multiple.job.id}%`)) ?? []).length, 2);
  console.log("PASS: a real structured Pal mention produces two stable separate replies, including the actual member mention.");

  const invitationSource = await send(bob, "Please send the RSVP invitation for our confirmed Riverside dinner, so we can answer whether we are going. Reply to this message.", { reply_to_id: multiple.replies[0].id });
  const invitation = await waitForTurn(invitationSource);
  const cardReply = invitation.replies.find(row => ["plan", "rsvp"].includes(row.card?.type) && row.card.entity_id === draft.id);
  assert.ok(cardReply, "A real future-plan invitation includes the bounded persisted RSVP card.");
  assert.equal(cardReply.reply_to_id, invitationSource.id);
  const persisted = (await transcript(alice)).find(row => row.id === cardReply.id); assert.ok(persisted);
  assert.deepEqual(persisted.cards, [{ type: cardReply.card.type, entity_id: draft.id }]);
  assert.equal((await state(alice)).plans.find((plan: Plan) => plan.id === draft.id).attendees.length, 0, "An invitation itself RSVP's nobody.");
  await action(bob, "plan.rsvp", { id: draft.id, status: "going" });
  let current = await state(alice), plan = current.plans.find((row: Plan) => row.id === draft.id) as Plan;
  assert.deepEqual(plan.attendees.map(row => ({ user_id: row.user_id, status: row.status })), [{ user_id: bob.id, status: "going" }]);
  assert.equal((await request(outsider, `/api/groups/${groupId}/state`, "POST", { action: "plan.rsvp", data: { id: draft.id, status: "going" } })).status, 403);
  assert.equal((await request(alice, `/api/groups/${groupId}/state`, "POST", { action: "plan.rsvp", data: { id: draft.id, status: "going", user_id: bob.id } })).status, 400);
  assert.deepEqual((await transcript(bob)).find(row => row.id === cardReply.id)?.cards, persisted.cards);
  console.log("PASS: the real RSVP invitation persists; a member changes only their own attendance and both readers retain the same message/card identity.");

  const secondSlot = new Date(when.getTime() + 86400000).toISOString();
  const cardsSource = await send(alice, `Please send exactly three separate messages with three cards: our existing Riverside dinner plan; a new options card offering only the generic ideas Park walk and Movie night (no invented venues or facts); and a new availability card proposing ${when.toISOString()} and ${secondSlot}, with a deadline tomorrow. Create the actual option and time choices first. Reply to this message on all three. Nobody has stated availability for these slots yet, so leave everyone's response unknown.`, { mentions: [{ type: "pal" }] });
  const rich = await waitForTurn(cardsSource);
  assert.equal(rich.replies.length, 3, "The actual model persists three intentional rich messages.");
  assert.deepEqual(rich.replies.map(row => row.card?.type).sort(), ["availability", "options", "plan"]);
  assert.ok(rich.replies.every(row => row.reply_to_id === cardsSource.id));
  assert.equal(rich.replies.find(row => row.card.type === "plan")?.card.entity_id, draft.id);
  const optionsCard = rich.replies.find(row => row.card.type === "options")!, availabilityCard = rich.replies.find(row => row.card.type === "availability")!;
  const richState = await state(alice);
  const ideas = richState.polls.find((row: Poll) => row.id === optionsCard.card.entity_id) as Poll;
  const times = richState.polls.find((row: Poll) => row.id === availabilityCard.card.entity_id) as Poll;
  assert.ok(ideas && times, "Cards reference real persisted choices, rather than transient generated JSON.");
  assert.equal(ideas.kind, "place"); assert.equal(times.kind, "time");
  assert.ok(ideas.options.every(row => !row.place_id), "Generic inspiration cannot invent a resolved venue.");
  assert.match(ideas.options.map(row => row.label).join(" "), /park/i);
  assert.match(ideas.options.map(row => row.label).join(" "), /movie/i);
  assert.deepEqual(times.options.map(row => row.starts_at && new Date(row.starts_at).toISOString()).sort(), [when.toISOString(), secondSlot].sort());
  assert.deepEqual(times.responses, [], "Proposing slots does not infer anyone's schedule.");
  assert.ok(richState.reminders.every((row: { poll_id: string | null }) => ![ideas.id, times.id].includes(row.poll_id ?? "")), "Rich inspiration and schedule boards do not create unsolicited legacy poll nudges.");
  const richAlice = (await transcript(alice)).filter(row => rich.replies.some(reply => reply.id === row.id));
  assert.deepEqual((await transcript(bob)).filter(row => rich.replies.some(reply => reply.id === row.id)), richAlice);
  console.log("PASS: real Eve tools create persisted options and availability; all three rich cards retain identical references for both readers, without guessed attendance or venues.");

  const noneSource = await send(bob, "None of these times work for me.", { reply_to_id: availabilityCard.id });
  await waitForTurn(noneSource);
  let scheduling = (await state(alice)).polls.find((row: Poll) => row.id === times.id) as Poll;
  assert.deepEqual(scheduling.responses, [{ user_id: bob.id, option_ids: [] }], "An explicit conversational decline remains distinct from Alice's unknown response.");
  await action(alice, "poll.vote", { id: times.id, option_ids: [times.options[0].id] });
  scheduling = (await state(bob)).polls.find((row: Poll) => row.id === times.id);
  assert.deepEqual(scheduling.responses.find(row => row.user_id === alice.id)?.option_ids, [times.options[0].id]);
  assert.deepEqual(scheduling.responses.find(row => row.user_id === bob.id)?.option_ids, []);
  assert.equal((await request(outsider, `/api/groups/${groupId}/state`, "POST", { action: "poll.vote", data: { id: times.id, option_ids: [times.options[0].id] } })).status, 403);
  assert.equal((await request(alice, `/api/groups/${groupId}/state`, "POST", { action: "poll.vote", data: { id: times.id, option_ids: [], user_id: bob.id } })).status, 400);
  checked(await db.from("polls").update({ status: "closed" }).eq("id", ideas.id).eq("group_id", groupId));
  checked(await db.from("polls").update({ deadline_at: new Date(Date.now() - 1000).toISOString() }).eq("id", times.id).eq("group_id", groupId));
  assert.equal((await request(alice, `/api/groups/${groupId}/state`, "POST", { action: "poll.vote", data: { id: ideas.id, option_ids: [ideas.options[0].id] } })).status, 400);
  assert.equal((await request(bob, `/api/groups/${groupId}/state`, "POST", { action: "poll.vote", data: { id: times.id, option_ids: [] } })).status, 400);
  assert.deepEqual((await transcript(alice)).filter(row => rich.replies.some(reply => reply.id === row.id)), richAlice, "Closing or expiring choices retains the same historical message references.");
  console.log("PASS: spoken availability is speaker-owned; unknown and none remain distinct; closed/expired choices reject edits and outsider responses.");

  await action(alice, "group.settings", { agent_paused: true });
  const ownFact = await send(bob, `I prefer vegetarian food. I am free at ${when.toISOString()} for Riverside dinner.`);
  const preference = await action(bob, "memory.save", { kind: "preference", key: "dietary preference", value: "Vegetarian food", source_message_id: ownFact.id });
  const availability = await action(bob, "memory.save", { kind: "availability", key: "Riverside dinner time", value: `Free at ${when.toISOString()}`, source_message_id: ownFact.id, expires_at: new Date(when.getTime() + 3600000).toISOString() });
  const summaryPath = `/api/groups/${groupId.toUpperCase()}/members/${bob.id.toUpperCase()}/summary`;
  const summaryResponse = await request(alice, summaryPath); assert.ok(summaryResponse.ok);
  assert.match(summaryResponse.headers.get("cache-control") ?? "", /private.*no-store/);
  const summary = await summaryResponse.json() as { summary: string | null; sources: { id: string; body: string }[]; preferences: { id: string; user_id: string }[]; availability: { id: string; user_id: string }[] };
  assert.ok(summary.summary); assert.ok(summary.summary.trim()); assert.match(summary.summary, /vegetarian|plant.based/i);
  assert.deepEqual(summary.preferences.map(row => row.id), [preference.id]);
  assert.deepEqual(summary.availability.map(row => row.id), [availability.id]);
  assert.ok([...summary.preferences, ...summary.availability].every(row => row.user_id === bob.id));
  const ownMessages = checked(await db.from("messages").select("id").eq("group_id", groupId).eq("role", "user").eq("sender_id", bob.id)) ?? [];
  const evidenceIDs = new Set([...ownMessages.map(row => row.id), preference.id, availability.id]);
  assert.ok(summary.sources.length && summary.sources.every(row => evidenceIDs.has(row.id)), "AI cites only this member's actual shared messages and own active memories.");
  assert.equal((await request(outsider, summaryPath)).status, 403);
  assert.equal((await request(alice, `/api/groups/${groupId}/members/${outsider.id}/summary`)).status, 404);
  console.log("PASS: a real member summary returns explicit preferences and dated availability, cites only that speaker's group evidence, and denies outsider viewers and targets.");

  const oldReminders = current.reminders.filter((row: { plan_id: string; status: string }) => row.plan_id === draft.id && row.status === "scheduled").map((row: { id: string }) => row.id);
  assert.ok(oldReminders.length > 0);
  const later = new Date(when.getTime() + 3600000);
  await action(alice, "plan.update", { id: draft.id, starts_at: later.toISOString(), ends_at: new Date(later.getTime() + 3600000).toISOString() });
  current = await state(bob); plan = current.plans.find((row: Plan) => row.id === draft.id);
  assert.equal(plan.attendees.length, 0, "A material time edit requires renewed RSVP.");
  assert.equal(Date.parse(plan.starts_at), later.getTime());
  assert.ok(current.reminders.filter((row: { id: string }) => oldReminders.includes(row.id)).every((row: { status: string }) => row.status === "cancelled"));
  assert.deepEqual((await transcript(alice)).find(row => row.id === cardReply.id)?.cards, persisted.cards, "Existing cards reference the updated authoritative plan.");
  await action(bob, "plan.rsvp", { id: draft.id, status: "maybe" });
  await action(alice, "plan.cancel", { id: draft.id });
  current = await state(bob); assert.equal(current.plans.find((row: Plan) => row.id === draft.id).status, "cancelled");
  assert.ok(current.reminders.filter((row: { plan_id: string }) => row.plan_id === draft.id).every((row: { status: string }) => row.status !== "scheduled"));
  assert.deepEqual((await transcript(bob)).find(row => row.id === cardReply.id)?.cards, persisted.cards);
  console.log("PASS: editing and cancelling update the referenced plan, require renewed attendance, and retire obsolete reminders without replacing the invitation message.");
} catch (error) {
  if (groupId) {
    await mkdir(".secrets", { recursive: true, mode: 0o700 });
    const snapshots = await Promise.all([
      db.from("messages").select("id,sender_id,role,body,card,mentions,reply_to_id,source_key,created_at").eq("group_id", groupId),
      db.from("agent_jobs").select("id,message_id,status,attempts,result,batch_message_ids,last_error").eq("group_id", groupId),
      db.from("plans").select("id,status,title,version,starts_at").eq("group_id", groupId),
      db.from("polls").select("id,kind,status,question,options,deadline_at").eq("group_id", groupId),
      db.from("poll_responses").select("poll_id,user_id,option_ids,source_message_id").eq("group_id", groupId),
    ]);
    await writeFile(".secrets/conversation-actions-smoke-failure.json", JSON.stringify({ trace: [...trace.values()], snapshots: snapshots.map(row => ({ data: row.data, error: row.error?.code })) }, null, 2), { mode: 0o600 });
  }
  throw error;
} finally {
  for (const id of groups) {
    checked(await db.from("groups").update({ agent_paused: true }).eq("id", id));
    checked(await db.from("agent_jobs").update({ status: "cancelled", lease_until: null, completed_at: new Date().toISOString() })
      .eq("group_id", id).in("status", ["queued", "running"]));
    checked(await db.from("groups").delete().eq("id", id));
  }
  for (const user of users) { await user.client.auth.signOut({ scope: "local" }); assert.ifError((await db.auth.admin.deleteUser(user.id)).error); }
}
console.log("PASS: fresh fixture rooms and users cleaned; human/demo data unchanged.");
