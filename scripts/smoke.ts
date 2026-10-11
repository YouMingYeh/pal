import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";
import { createClient } from "@supabase/supabase-js";
import { admin, env } from "../lib/db";

const base = env("PAL_BASE_URL").replace(/\/$/, "");
const db = admin();
const suffix = `${Date.now()}-${randomBytes(3).toString("hex")}`;
const users = await Promise.all(["alice", "bob", "outsider"].map(async (name) => {
  const email = `${name}-${suffix}@pal-demo.example`;
  const password = randomBytes(24).toString("base64url");
  const created = await db.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { display_name: name } });
  if (created.error) throw created.error;
  const client = createClient(env("SUPABASE_URL"), env("SUPABASE_PUBLISHABLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const signed = await client.auth.signInWithPassword({ email, password });
  if (signed.error || !signed.data.session) throw signed.error || new Error("Sign in failed");
  return { name, email, password, client, token: signed.data.session.access_token };
}));
const [alice, bob, outsider] = users;

async function api(user: typeof alice, path: string, method = "GET", body?: unknown) {
  const response = await fetch(`${base}${path}`, {
    method, headers: { Authorization: `Bearer ${user.token}`, "Content-Type": "application/json" },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  assert.ok(response.ok, `API ${method} ${path} returned ${response.status}`);
  return response.json();
}

const { group } = await api(alice, "/api/groups", "POST", { name: "Pal hackathon demo" });
await api(bob, "/api/groups/join", "POST", { invite_code: group.invite_code });
await writeFile(".env.demo.local", users.map(user =>
  `DEMO_${user.name.toUpperCase()}_EMAIL=${user.email}\nDEMO_${user.name.toUpperCase()}_PASSWORD=${user.password}`
).join("\n") + `\nDEMO_GROUP_ID=${group.id}\nDEMO_INVITE_CODE=${group.invite_code}\n`, { mode: 0o600 });

const path = `/api/groups/${group.id}/messages`;
const aliceMessageId = randomUUID();
await api(alice, path, "POST", { body: "Let's meet at the hackathon demo. Alice will bring snacks; Bob will bring a laptop.", client_id: aliceMessageId });
await api(alice, path, "POST", { body: "Let's meet at the hackathon demo. Alice will bring snacks; Bob will bring a laptop.", client_id: aliceMessageId });
await api(bob, path, "POST", { body: "Agreed. We also need a charger for the laptop.", client_id: randomUUID() });
const { messages } = await api(bob, path);
assert.equal(messages.length, 2, "Two users see the shared transcript; duplicate delivery creates no extra message.");
const denied = await fetch(`${base}${path}`, { headers: { Authorization: `Bearer ${outsider.token}` } });
assert.equal(denied.status, 403, "Outsider is denied by API.");
const outsideRows = await outsider.client.from("messages").select("id").eq("group_id", group.id);
assert.ifError(outsideRows.error);
assert.equal(outsideRows.data?.length, 0, "RLS hides the group from outsider.");
const eveDenied = await fetch(`${base}/eve/v1/session`, {
  method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${alice.token}` },
  body: JSON.stringify({ message: "Bypass Pal" }),
});
assert.equal(eveDenied.status, 401, "A client cannot directly access Pal's service-only Eve runtime.");
console.log("PASS: two authenticated users share one group; duplicate messages and outsider access are blocked.");

const due = new Date(Date.now() + 90000).toISOString();
await api(alice, path, "POST", {
  body: `@Pal read our discussion, summarize who is bringing what, and remind us to bring the charger at ${due} (timezone UTC).`,
  client_id: randomUUID(),
});
let replied = false;
for (let attempt = 0; attempt < 40; attempt++) {
  await sleep(2000);
  const { messages: current } = await api(bob, path);
  if (current.some((message: { role: string }) => message.role === "pal")) { replied = true; break; }
}
assert.ok(replied, "Pal completed a real OpenAI turn through Eve.");
const reminders = await db.from("reminders").select("id,status,due_at").eq("group_id", group.id);
assert.ifError(reminders.error);
assert.equal(reminders.data?.length, 1, "Pal's tool saved exactly one real reminder.");
assert.equal(reminders.data?.[0].status, "scheduled");
console.log("PASS: Eve + OpenAI read the group and saved a real reminder with a scoped database tool.");

// Sending through PostgREST bypasses Next's immediate worker so only Cron can recover this job.
const recoveredMessage = await alice.client.rpc("send_message", {
  p_group_id: group.id,
  p_body: "@Pal read the group and give one short sentence about the remaining unassigned item. Do not create another reminder.",
  p_client_id: randomUUID(),
});
assert.ifError(recoveredMessage.error);
const recovery = await db.from("agent_jobs").select("id").eq("message_id", recoveredMessage.data.id).single();
assert.ifError(recovery.error);
assert.ok(recovery.data?.id, "Direct Supabase send created a durable job without a backend dispatch.");

await Promise.all(users.map(user => user.client.auth.signOut()));
console.log("All test clients signed out. Waiting for server Cron delivery with no connected client.");
await sleep(Math.max(1000, Date.parse(due) + 70000 - Date.now()));
const delivered = await db.from("reminders").select("status").eq("group_id", group.id).single();
assert.ifError(delivered.error);
assert.equal(delivered.data?.status, "completed", "Reminder fired without a connected client.");
const posted = await db.from("messages").select("id,body,created_at").eq("group_id", group.id)
  .eq("source_key", `reminder:${reminders.data![0].id}`);
assert.ifError(posted.error);
assert.equal(posted.data?.length, 1, "Reminder posts exactly one durable group message.");
assert.ok(Date.parse(posted.data![0].created_at) >= Date.parse(due));
const recovered = await db.from("agent_jobs").select("status").eq("id", recovery.data!.id).single();
assert.ifError(recovered.error);
assert.equal(recovered.data?.status, "completed", "Server recovery Cron completed the job without a connected client.");
const recoveryReply = await db.from("messages").select("id").eq("group_id", group.id)
  .eq("source_key", `job:${recovery.data!.id}`);
assert.ifError(recoveryReply.error);
assert.equal(recoveryReply.data?.length, 1, "Recovered task posts one durable Pal reply.");
console.log("PASS: server reminder posted once after every client signed out.");
console.log("PASS: server recovery Cron completed a directly queued Pal job after clients signed out.");
console.log(`Demo group ${group.id}; invite ${group.invite_code}. Device credentials are saved only in ignored .env.demo.local.`);
