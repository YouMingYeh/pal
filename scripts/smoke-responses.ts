import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { setTimeout as sleep } from "node:timers/promises";
import { writeFile } from "node:fs/promises";
import { createClient } from "@supabase/supabase-js";
import { Client } from "eve/client";
import { admin, checked, env } from "../lib/db";

// Run only after the matching production build and capture migration are deployed.
// node --env-file=.env --import tsx scripts/smoke-responses.ts https://pal-jade.vercel.app
process.loadEnvFile(".env.demo.local");
assert.ok(process.argv[2], "Supply the deployed origin explicitly; do not use a demo env's stale base URL.");
const origin = new URL(process.argv[2]);
assert.ok(["http:", "https:"].includes(origin.protocol) && !origin.username && !origin.password);
const base = origin.origin;
const db = admin();
const deadline = Date.now() + 300_000;
const users = await Promise.all(["ALICE", "BOB"].map(async name => {
  assert.match(env(`DEMO_${name}_EMAIL`), /@pal-demo\.example$/, "Only isolated demo accounts may run this check.");
  const client = createClient(env("SUPABASE_URL"), env("SUPABASE_PUBLISHABLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false } });
  const signed = await client.auth.signInWithPassword({ email: env(`DEMO_${name}_EMAIL`), password: env(`DEMO_${name}_PASSWORD`) });
  assert.ok(!signed.error && signed.data.user && signed.data.session, "Demo sign-in failed.");
  return { client, id: signed.data.user.id, token: signed.data.session.access_token };
}));
const [alice, bob] = users;
const completedJobs = new Map<string, { id: string; attempts: number }>();
const toolTrace = new Map<string, unknown>();
let sawThinking = false;
type User = typeof alice;
type ResponseRow = { user_id: string; option_ids: string[]; source_message_id: string | null };
let groupId: string | undefined;

async function api(user: User, path: string, method = "GET", body?: unknown) {
  const response = await fetch(base + path, {
    method, headers: { authorization: `Bearer ${user.token}`, "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(30_000), redirect: "error",
  });
  assert.ok(response.ok, `${method} ${path} returned ${response.status}.`);
  return response.json();
}
async function action(name: string, data: Record<string, unknown>) {
  return api(alice, `/api/groups/${groupId}/state`, "POST", { action: name, data });
}
async function sendAndWait(user: User, body: string) {
  assert.ok(!/@pal\b/i.test(body), "Conversational proof must not mention Pal.");
  const { message } = await api(user, `/api/groups/${groupId}/messages`, "POST", { body, client_id: randomUUID() });
  let completed = false;
  while (Date.now() < deadline) {
    const trigger = checked(await db.from("agent_jobs").select("id,coalesced_into").eq("group_id", groupId!).eq("message_id", message.id).maybeSingle());
    if (trigger) {
      const job = checked(await db.from("agent_jobs").select("status,explicit_mention,batch_message_ids,result,attempts")
        .eq("id", trigger.coalesced_into || trigger.id).single());
      assert.ok(job, "Observed source job disappeared.");
      if (job.status === "running" && job.result) {
        const sessionId = JSON.parse(job.result).sessionId;
        if (sessionId) {
          // Bounded read-only snapshots detach without cancelling the real turn.
          // Job auth deliberately expires on completion; a racing final read is harmless.
          const client = new Client({ host: base, redirect: "error", auth: { bearer: env("PAL_INTERNAL_SECRET") },
            headers: { "x-pal-job-id": trigger.coalesced_into || trigger.id } });
          try {
            for await (const event of client.sessions.attach(sessionId).stream({ startIndex: 0, follow: false,
              signal: AbortSignal.timeout(7000), streamReconnectPolicy: { reconnect: false } })) {
              if (["actions.requested", "action.result", "result.completed"].includes(event.type)) {
                toolTrace.set(event.meta.id, { job_id: trigger.coalesced_into || trigger.id, type: event.type, data: event.data });
              }
            }
          } catch { /* Diagnostics cannot fail or restart the actual worker. */ }
        }
      }
      assert.equal(job.explicit_mention, false, "Ordinary messages must not require @Pal.");
      const state = await api(alice, `/api/groups/${groupId}/state`);
      assert.ok(state.pal_activity, "The deployed state must expose actual Pal activity.");
      if (state.pal_activity.activity === "thinking") {
        assert.equal(state.pal_activity.job_id, trigger.coalesced_into || trigger.id);
        assert.ok(["accepted", "running"].includes(state.pal_activity.status));
        assert.ok(Date.parse(state.pal_activity.expires_at) > Date.now());
        sawThinking = true;
      }
      if (job.status === "completed") {
        assert.ok(job.batch_message_ids.includes(message.id), "The completed durable job contains the actual source.");
        assert.ok(JSON.parse(job.result).sessionId, "A real Eve session must have run.");
        completed = true;
        completedJobs.set(message.id, { id: trigger.coalesced_into || trigger.id, attempts: job.attempts });
        break;
      }
      if (job.status === "failed" && job.attempts >= 3) throw new Error("Real Eve conversational job failed repeatedly.");
    }
    await sleep(2000);
  }
  assert.equal(completed, true, "Real Eve/OpenAI response did not finish within the five-minute check.");
  return message.id as string;
}
async function responses(pollId: string) {
  return checked(await db.from("poll_responses").select("user_id,option_ids,source_message_id").eq("group_id", groupId!).eq("poll_id", pollId)) as ResponseRow[];
}
async function attending(planId: string) {
  return checked(await db.from("plan_rsvps").select("user_id,status,source_message_id").eq("group_id", groupId!).eq("plan_id", planId));
}

try {
  const { group } = await api(alice, "/api/groups", "POST", { name: `Pal conversation check ${new Date().toISOString()}` });
  groupId = group.id;
  await api(bob, "/api/groups/join", "POST", { invite_code: group.invite_code });
  await action("group.settings", { timezone: "UTC", agent_paused: true, proactive_suggestions: false });
  const friday = new Date();
  friday.setUTCHours(19, 0, 0, 0);
  friday.setUTCDate(friday.getUTCDate() + (5 - friday.getUTCDay() + 7) % 7);
  assert.ok(friday.getTime() > Date.now() + 300_000, "Run this weekday fixture before Friday 19:00 UTC.");
  const eight = new Date(friday.getTime() + 3600_000).toISOString();
  const poll = await action("poll.create", {
    kind: "time", question: "What time should we get dinner?", deadline_at: new Date(Date.now() + 6 * 3600_000).toISOString(),
    options: [{ id: "seven", label: "Friday 7 PM", starts_at: friday.toISOString() }, { id: "eight", label: "Friday 8 PM", starts_at: eight }],
    source_key: `smoke:${randomUUID()}`,
  });
  await action("group.settings", { agent_paused: false });
  const aliceSource = await sendAndWait(alice, "Friday after seven works for me");
  let votes = await responses(poll.id);
  assert.equal(votes.length, 1, "Alice's message must not answer for Bob.");
  assert.equal(votes[0].user_id, alice.id);
  assert.equal(votes[0].source_message_id, aliceSource);
  assert.deepEqual(votes[0].option_ids, ["eight"]);
  const bobSource = await sendAndWait(bob, "Either works");
  votes = await responses(poll.id);
  assert.equal(votes.length, 2);
  assert.equal(votes.find(vote => vote.user_id === alice.id)?.source_message_id, aliceSource);
  assert.equal(votes.find(vote => vote.user_id === bob.id)?.source_message_id, bobSource);
  assert.deepEqual(new Set(votes.find(vote => vote.user_id === bob.id)?.option_ids), new Set(["seven", "eight"]));
  console.log("PASS: real Eve/OpenAI captured both speakers' ordinary time choices with exact source provenance, without @Pal.");

  const draft = await action("plan.create", { title: "Friday dinner", starts_at: eight, ends_at: new Date(Date.parse(eight) + 3600_000).toISOString(), source_key: `smoke:${randomUUID()}` });
  await action("plan.confirm", { id: draft.id });
  const eitherSource = await sendAndWait(alice, "Anything works");
  assert.equal((await attending(draft.id))?.length, 0, "Anything works must never imply anyone's attendance.");
  assert.equal((await responses(poll.id)).find(vote => vote.user_id === alice.id)?.source_message_id, eitherSource);
  const attendanceSource = await sendAndWait(bob, "I'm in");
  const attendees = await attending(draft.id);
  assert.equal(attendees?.length, 1, "Bob's explicit attendance must not RSVP for Alice.");
  assert.equal(attendees[0].user_id, bob.id);
  assert.equal(attendees[0].status, "going");
  assert.equal(attendees[0].source_message_id, attendanceSource);
  console.log("PASS: anything works remained a poll choice; Bob's own explicit message RSVP'd only Bob to the member-confirmed plan.");

  const preferenceSource = await sendAndWait(alice, "I prefer vegetarian food.");
  const memories = checked(await db.from("member_memories").select("user_id,source_message_id,value")
    .eq("group_id", groupId!).eq("source_message_id", preferenceSource));
  assert.ok(memories?.some(memory => memory.user_id === alice.id && /vegetarian/i.test(memory.value)), "Actual Eve stored Alice's explicit preference quietly.");
  const preferenceJob = completedJobs.get(preferenceSource)!;
  const unsolicited = checked(await db.from("messages").select("id").eq("group_id", groupId!).eq("source_key", `job:${preferenceJob.id}`));
  assert.equal(unsolicited?.length, 0, "Quiet context capture must not produce an unnecessary reply.");
  console.log("PASS: an ordinary explicit preference was remembered for its actual speaker without a chat reply or editor.");

  const moodSource = await sendAndWait(bob, "Pal, I'm sad because my weekend plans fell through. Please give me one short empathetic reply.");
  const moodJob = completedJobs.get(moodSource)!;
  const mood = checked(await db.from("messages").select("id,body,emotion").eq("group_id", groupId!).eq("source_key", `job:${moodJob.id}`).single());
  assert.ok(mood, "The actual Eve/OpenAI turn must produce an empathetic message.");
  assert.ok(mood.body.trim(), "The actual Eve/OpenAI turn must produce the empathetic reply.");
  assert.equal(mood.emotion, "triste", "The actual empathetic reply must persist a sad expression rather than a celebratory default.");
  const visible = (await api(alice, `/api/groups/${groupId}/messages`)).messages.find((message: { id: string }) => message.id === mood.id);
  assert.equal(visible.emotion, "triste", "The chat API preserves the stable message's expression.");
  const replay = checked(await db.rpc("complete_agent_job_with_emotion", {
    p_job_id: moodJob.id, p_attempt: moodJob.attempts, p_body: "A replacement must not be accepted.",
    p_result: null, p_emotion: "hilare",
  }));
  assert.equal(replay, false, "An already completed job cannot accept another reply or expression.");
  const unchanged = checked(await db.from("messages").select("id,body,emotion").eq("group_id", groupId!).eq("source_key", `job:${moodJob.id}`).single());
  assert.deepEqual(unchanged, mood, "A completion retry preserves the original body and expression.");
  assert.equal(sawThinking, true, "At least one real accepted/running job exposed thinking activity.");
  assert.equal((await api(alice, `/api/groups/${groupId}/state`)).pal_activity.activity, "idle");
  console.log("PASS: actual task activity ended at idle; the real empathetic reply retained triste through the API and a rejected completion retry.");
} catch (error) {
  if (groupId) {
    const diagnostics = await Promise.all([
      db.from("messages").select("id,role,body,card,source_key,created_at").eq("group_id", groupId).order("created_at"),
      db.from("agent_jobs").select("id,message_id,status,attempts,explicit_mention,batch_message_ids,result,coalesced_into").eq("group_id", groupId),
      db.from("polls").select("id,kind,status,question,options").eq("group_id", groupId),
      db.from("poll_responses").select("poll_id,user_id,option_ids,source_message_id").eq("group_id", groupId),
      db.from("plan_rsvps").select("plan_id,user_id,status,source_message_id").eq("group_id", groupId),
    ]);
    await writeFile(".secrets/conversation-smoke-failure.json", JSON.stringify({
      tool_trace: [...toolTrace.values()], snapshots: diagnostics.map(result => ({ data: result.data, error: result.error?.code ?? null })),
    }, null, 2), { mode: 0o600 });
  }
  throw error;
} finally {
  if (groupId) {
    checked(await db.from("groups").update({ agent_paused: true }).eq("id", groupId).eq("creator_id", alice.id));
    checked(await db.from("groups").delete().eq("id", groupId).eq("creator_id", alice.id));
  }
  await Promise.all(users.map(user => user.client.auth.signOut()));
}
console.log("PASS: isolated conversation-check group removed; demo credentials and existing groups were preserved.");
