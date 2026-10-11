import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { Client } from "eve/client";
import { admin, checked, env } from "../lib/db";
import { recoverEveResult } from "../lib/eve-result";
import { setTimeout as sleep } from "node:timers/promises";
import { initialTurnInput } from "../lib/turn-context";
import { agentReply, parsedPalOutputs } from "../lib/validation";

// Run only after the migration and matching canonical agent are deployed.
// node --env-file=.env --import tsx scripts/smoke-reply-activity.ts https://pal-jade.vercel.app
assert.ok(process.argv[2], "Supply the deployed origin explicitly.");
const origin = new URL(process.argv[2]);
assert.ok(["http:", "https:"].includes(origin.protocol) && !origin.username && !origin.password);
const db = admin(), users: string[] = [];
let groupId: string | undefined;
const deadline = () => new Date(Date.now() + 5 * 60000).toISOString();
try {
  const password = randomUUID() + randomUUID(), email = `reply-activity-${randomUUID()}@pal-demo.example`;
  const ownerResponse = await db.auth.admin.createUser({ email, password, email_confirm: true });
  assert.ifError(ownerResponse.error); assert.ok(ownerResponse.data.user);
  const owner = ownerResponse.data.user;
  users.push(owner.id);
  const bobResponse = await db.auth.admin.createUser({ email: `reply-bob-${randomUUID()}@pal-demo.example`, password, email_confirm: true });
  assert.ifError(bobResponse.error); assert.ok(bobResponse.data.user);
  const bob = bobResponse.data.user;
  users.push(bob.id);
  checked(await db.from("profiles").update({ display_name: "Alice" }).eq("user_id", owner.id));
  checked(await db.from("profiles").update({ display_name: "Bob" }).eq("user_id", bob.id));
  const member = createClient(env("SUPABASE_URL"), env("SUPABASE_PUBLISHABLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false } });
  const login = await member.auth.signInWithPassword({ email, password }); assert.ifError(login.error);
  groupId = checked(await member.rpc("create_group", { p_name: "Reply activity — isolated acceptance" })).id;
  checked(await db.from("group_members").insert({ group_id: groupId, user_id: bob.id }));
  checked(await db.from("messages").insert([
    { group_id: groupId, sender_id: owner.id, role: "user", body: "Bob, did I leave my charger at yours?", created_at: new Date(Date.now() - 60000).toISOString() },
    { group_id: groupId, sender_id: bob.id, role: "user", body: "Yep, your charger is on my desk.", created_at: new Date(Date.now() - 30000).toISOString() },
  ]));

  for (const [body, shouldReply] of [["Thanks Bob, got it.", false], ["We should finally get dinner together Friday after seven. What do you think?", true], ["Let’s pick a dinner budget. Ask us one short question with two or three suggested answers we can tap.", true]] as const) {
    const source = checked(await member.rpc("send_message", { p_group_id: groupId, p_body: body, p_client_id: randomUUID() }));
    assert.equal(checked(await member.rpc("pal_group_state", { p_group_id: groupId })).pal_activity.activity, "idle", "A queued group message never claims typing.");
    // Lease only this isolated fixture; never claim unrelated users' queued work.
    const job = checked(await db.from("agent_jobs").update({ status: "running", attempts: 1, lease_until: deadline(), batch_message_ids: [source.id] })
      .eq("group_id", groupId).eq("message_id", source.id).select("*").single());
    assert.equal(checked(await member.rpc("pal_group_state", { p_group_id: groupId })).pal_activity.activity, "idle", "Decision work remains quiet.");
    const client = new Client({ host: origin.origin, redirect: "error", auth: { bearer: env("PAL_INTERNAL_SECRET") }, headers: { "x-pal-job-id": job.id } });
    const state = checked(await member.rpc("pal_group_state", { p_group_id: groupId }));
    const recent = checked(await db.from("messages").select("*").eq("group_id", groupId).order("created_at").limit(20));
    const startedAt = Date.now();
    const created = await client.sessions.create({ message: JSON.stringify(initialTurnInput(job, [source], state, recent)),
      clientContext: { currentTime: new Date().toISOString(), timezone: "UTC", unavailableUrls: [], isDirect: false },
      outputSchema: agentReply });
    const result = await recoverEveResult(client.sessions.attach(created.response.sessionId));
    const outputs = parsedPalOutputs(result.structured);
    const finished = checked(await db.from("agent_jobs").select("reply_started_at,reply_started_attempt").eq("id", job.id).single());
    assert.ok(finished, "The isolated worker remains available for verification.");
    const activity = checked(await member.rpc("pal_group_state", { p_group_id: groupId })).pal_activity;
    if (shouldReply) {
      assert.ok(outputs.length, "An untagged planning invitation receives a real response.");
      assert.ok(finished.reply_started_at, "Eve called begin_reply for its actual chosen response.");
      assert.equal(finished.reply_started_attempt, job.attempts);
      assert.equal(activity.activity, "typing"); assert.equal(activity.status, "running");
      if (body.includes("suggested answers")) {
        const question = outputs.find(output => output.card?.type === "question");
        assert.ok(question, "Eve supplies a real validated suggested-answer card.");
        assert.equal(question.card?.entity_id, groupId);
      }
    } else {
      assert.equal(outputs.length, 0, "A resolved exchange between friends needs no Pal response.");
      assert.equal(finished.reply_started_at, null, "Real silence never calls begin_reply.");
      assert.equal(activity.activity, "idle");
    }
    assert.equal(checked(await db.rpc("complete_agent_job_with_outputs", { p_job_id: job.id, p_attempt: job.attempts, p_outputs: outputs,
      p_result: JSON.stringify({ sessionId: created.response.sessionId, format: "v2" }) })), true);
    assert.equal(checked(await member.rpc("pal_group_state", { p_group_id: groupId })).pal_activity.activity, "idle", "Completion stops typing.");
    if (body.includes("suggested answers")) {
      const delivered = checked(await db.from("messages").select("id,card").eq("group_id", groupId).like("source_key", `job:${job.id}%`).eq("card->>type", "question").single());
      assert.ok(delivered, "The real question is delivered in this group.");
      assert.ok(delivered.card.suggestions.length >= 2);
      const answer = checked(await member.rpc("send_message", { p_group_id: groupId, p_body: delivered.card.suggestions[0], p_client_id: randomUUID(), p_reply_to_id: delivered.id }));
      assert.equal(answer.reply_to_id, delivered.id, "A suggestion sends an ordinary human quote reply.");
      checked(await db.from("agent_jobs").update({ status: "cancelled" }).eq("group_id", groupId).eq("message_id", answer.id));
      console.log("PASS: Suggested answer persisted and sent as an ordinary quoted member message.");
    }
    console.log(`Turn completed in ${Date.now() - startedAt}ms; ${outputs.length} public messages.`);
    console.log(shouldReply ? "PASS: Real Eve chose a short response and marked only its reply phase." : "PASS: Real Eve stayed silent without claiming typing.");
  }
  const apiStarted = Date.now();
  const submitted = await fetch(origin.origin + `/api/groups/${groupId}/messages`, { method: "POST",
    headers: { authorization: `Bearer ${login.data.session!.access_token}`, "content-type": "application/json" },
    body: JSON.stringify({ body: "@Pal, help us settle dinner: what one detail should we decide next?", client_id: randomUUID() }) });
  assert.equal(submitted.status, 201);
  const sent = (await submitted.json()).message;
  let complete = false;
  while (Date.now() - apiStarted < 120000) {
    const job = checked(await db.from("agent_jobs").select("status,last_error").eq("group_id", groupId).eq("message_id", sent.id).single());
    assert.ok(job); assert.notEqual(job.status, "failed", job.last_error ?? "The deployed dispatcher must finish.");
    if (job.status === "completed") { complete = true; break; }
    await sleep(1000);
  }
  assert.ok(complete, "The actual HTTP dispatcher finishes within two minutes.");
  console.log(`PASS: Actual deployed message dispatcher completed in ${Date.now() - apiStarted}ms.`);
  console.log("ALL GREEN: shared reply-phase acceptance.");
} finally {
  if (groupId) checked(await db.from("groups").delete().eq("id", groupId));
  for (const id of users) assert.ifError((await db.auth.admin.deleteUser(id)).error);
}
