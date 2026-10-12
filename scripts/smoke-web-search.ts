import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { Client } from "eve/client";
import { admin, checked, env } from "../lib/db";
import { recoverEveResult } from "../lib/eve-result";
import { initialTurnInput } from "../lib/turn-context";
import type { SourceMessage } from "../lib/job-scope";
import { agentReply, parsedPalOutputs } from "../lib/validation";
import { searchWeb } from "../lib/research";

// Real provider calls; only this script's temporary accounts and rooms are removed.
assert.ok(process.argv[2], "Supply the deployed origin explicitly.");
const origin = new URL(process.argv[2]);
assert.ok(["http:", "https:"].includes(origin.protocol) && !origin.username && !origin.password);
const db = admin(), users: string[] = [], groups: string[] = [];
const member = createClient(env("SUPABASE_URL"), env("SUPABASE_PUBLISHABLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false } });

async function turn(groupId: string, batch: SourceMessage[]) {
  const started = Date.now();
  const job = checked(await db.from("agent_jobs").insert({ group_id: groupId, requester_id: batch[0].sender_id,
    message_id: batch[0].id, status: "running", attempts: 1, batch_message_ids: batch.map(message => message.id),
    lease_until: new Date(Date.now() + 300000).toISOString() }).select("*").single());
  const state = checked(await member.rpc("pal_group_state", { p_group_id: groupId }));
  assert.equal(state.pal_activity.activity, "idle", "Reading a batch is not typing.");
  const recent = checked(await db.from("messages").select("*").eq("group_id", groupId).order("created_at").limit(20));
  const client = new Client({ host: origin.origin, redirect: "error", auth: { bearer: env("PAL_INTERNAL_SECRET") }, headers: { "x-pal-job-id": job.id } });
  const created = await client.sessions.create({ message: JSON.stringify(initialTurnInput(job, batch, state, recent)),
    clientContext: { currentTime: new Date().toISOString(), timezone: "UTC", unavailableUrls: [], isDirect: state.settings.is_direct },
    outputSchema: agentReply });
  const outputs = parsedPalOutputs((await recoverEveResult(created.session)).structured);
  const phase = checked(await db.from("agent_jobs").select("reply_started_at").eq("id", job.id).single());
  assert.ok(phase);
  assert.equal(Boolean(phase.reply_started_at), outputs.length > 0, "Only an actual reply declares typing.");
  const args = { p_job_id: job.id, p_attempt: 1, p_outputs: outputs, p_result: JSON.stringify({ sessionId: created.response.sessionId, format: "v2" }) };
  assert.equal(checked(await db.rpc("complete_agent_job_with_outputs", args)), true);
  assert.equal(checked(await db.rpc("complete_agent_job_with_outputs", args)), false, "A completion retry cannot duplicate messages.");
  const delivered = checked(await db.from("messages").select("id").eq("group_id", groupId).like("source_key", `job:${job.id}%`));
  assert.equal(delivered?.length, outputs.length);
  assert.equal(checked(await member.rpc("pal_group_state", { p_group_id: groupId })).pal_activity.activity, "idle");
  console.log(`Real Eve turn: ${outputs.length} bubbles, ${Date.now() - started}ms.`);
  return outputs;
}

async function sources(groupId: string, inputs: { sender_id: string; body: string }[]) {
  return checked(await db.from("messages").insert(inputs.map((input, index) => ({ ...input, group_id: groupId,
    role: "user", created_at: new Date(Date.now() - (inputs.length - index) * 1000).toISOString() })))
    .select("*").order("created_at")) as SourceMessage[];
}

try {
  const password = randomUUID() + randomUUID();
  for (const name of ["Alice", "Bob"]) {
    const email = `web-search-${randomUUID()}@pal-demo.example`;
    const created = await db.auth.admin.createUser({ email, password, email_confirm: true });
    assert.ifError(created.error); assert.ok(created.data.user); users.push(created.data.user.id);
    checked(await db.from("profiles").update({ display_name: name }).eq("user_id", created.data.user.id));
    if (name === "Alice") assert.ifError((await member.auth.signInWithPassword({ email, password })).error);
  }
  const groupId = checked(await member.rpc("create_group", { p_name: "Search — isolated acceptance" })).id;
  groups.push(groupId);
  checked(await db.from("group_members").insert({ group_id: groupId, user_id: users[1] }));
  const directId = checked(await member.rpc("ensure_pal_direct")).id; groups.push(directId);
  const provider = await searchWeb("SFMOMA official visit opening hours adult admission");
  assert.ok(provider.results.some(result => new URL(result.url).hostname.endsWith("sfmoma.org")), "OpenAI returns actual official search sources.");
  console.log("PASS: real web-search provider returned official sources.");

  const burst = await sources(groupId, [
    { sender_id: users[0], body: "Pal, settle this: pineapple on pizza, yes or no? Reply to my message with your own opinion." },
    { sender_id: users[1], body: "Different question, Pal: what would you name this chaotic friend group? Reply to my message too." },
  ]);
  const replies = await turn(groupId, burst);
  assert.ok(burst.every(source => replies.some(reply => reply.reply_to_id === source.id)), "Each distinct question gets its own actual source reference in one turn.");
  assert.ok(replies.every(reply => reply.body.length < 500 && !reply.card));
  console.log("PASS: two friends answered in one batch with distinct quoted messages, no duplicated delivery.");

  for (const id of [groupId, directId]) {
    const batch = await sources(id, [{ sender_id: users[0], body: "Pal, search the web for SFMOMA's current opening hours and adult admission price. Use official sources and include a clickable source link. Keep it short." }]);
    const answer = await turn(id, batch);
    assert.ok(answer.length > 0 && answer.length <= 2, "Search produces a short conversational answer.");
    const body = answer.map(reply => reply.body).join("\n");
    assert.match(body, /\[[^\]]+\]\(https:\/\/(?:www\.)?sfmoma\.org\//i, "Search answers cite a clickable official source.");
    assert.match(body, /\$\s*\d|\d+\s*(?:USD|dollars)/i, "The requested admission finding is present.");
    console.log(`PASS: ${id === groupId ? "group" : "private DM"} search answer includes current findings and official links.`);
  }
  console.log("ALL GREEN: real search and targeted conversational replies.");
} finally {
  for (const id of groups) checked(await db.from("groups").delete().eq("id", id));
  for (const id of users) assert.ifError((await db.auth.admin.deleteUser(id)).error);
}
