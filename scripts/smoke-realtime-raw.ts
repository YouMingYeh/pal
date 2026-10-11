import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { setTimeout as sleep } from "node:timers/promises";
import { createClient } from "@supabase/supabase-js";
import { admin, checked, env } from "../lib/db";

// Real, raw protocol-v1 proof independent of the SDK's channel implementation.
const db = admin(), users: { id: string; token: string; client: ReturnType<typeof admin> }[] = [];
assert.ok(process.argv[2], "Supply the deployed origin explicitly.");
const origin = new URL(process.argv[2]);
assert.ok(["http:", "https:"].includes(origin.protocol) && !origin.username && !origin.password);
const sockets: WebSocket[] = [], heartbeats: ReturnType<typeof setInterval>[] = [];
let groupId: string | undefined;
async function provision() {
  const email = `raw-realtime-${randomUUID()}@pal-demo.example`, password = randomUUID() + randomUUID();
  const created = await db.auth.admin.createUser({ email, password, email_confirm: true });
  assert.ifError(created.error); assert.ok(created.data.user);
  const client = createClient(env("SUPABASE_URL"), env("SUPABASE_PUBLISHABLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false } });
  const signed = await client.auth.signInWithPassword({ email, password });
  if (signed.error || !signed.data.session) { await db.auth.admin.deleteUser(created.data.user.id); throw new Error("Raw probe fixture sign-in failed."); }
  const user = { id: created.data.user.id, token: signed.data.session.access_token, client }; users.push(user); return user;
}
async function subscribe(token: string, received: string[], label: string) {
  const url = new URL(env("SUPABASE_URL"));
  assert.equal(url.protocol, "https:"); url.protocol = "wss:"; url.pathname = "/realtime/v1/websocket";
  url.search = new URLSearchParams({ apikey: env("SUPABASE_PUBLISHABLE_KEY"), vsn: "1.0.0" }).toString();
  const socket = new WebSocket(url); sockets.push(socket);
  const topic = `realtime:raw-check-${randomUUID()}`; let nextRef = 1, joined = false, ready = false;
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`Raw ${label} CDC readiness timed out.`)), 45000);
    const finish = () => { if (joined && ready) { clearTimeout(timeout); resolve(); } };
    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ topic, event: "phx_join", ref: "1", join_ref: "1", payload: {
        access_token: token, config: { broadcast: { ack: false, self: false }, presence: { enabled: false }, private: false,
          postgres_changes: [{ event: "INSERT", schema: "public", table: "messages", filter: `group_id=eq.${groupId}` }] },
      } }));
      heartbeats.push(setInterval(() => { if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ topic: "phoenix", event: "heartbeat", ref: String(++nextRef), payload: {} })); }, 20000));
    });
    socket.addEventListener("error", () => { clearTimeout(timeout); reject(new Error(`Raw ${label} socket failed.`)); });
    socket.addEventListener("message", event => {
      if (typeof event.data !== "string") return;
      const frame = JSON.parse(event.data);
      if (frame.topic !== topic) return;
      if (frame.event === "phx_reply" && frame.ref === "1") {
        console.log(`Raw ${label}: join ${frame.payload.status}; subscriptions ${frame.payload.response?.postgres_changes?.length ?? 0}.`);
        if (frame.payload.status !== "ok") { clearTimeout(timeout); reject(new Error(`Raw ${label} join rejected.`)); return; }
        joined = true; finish();
      }
      if (frame.event === "system" && frame.payload.extension === "postgres_changes") {
        console.log(`Raw ${label}: CDC ${frame.payload.status}.`);
        if (frame.payload.status === "ok") { ready = true; finish(); }
        else { clearTimeout(timeout); reject(new Error(`Raw ${label} CDC failed.`)); }
      }
      const data = frame.payload?.data;
      if (frame.event === "postgres_changes" && data?.schema === "public" && data.table === "messages" && data.type === "INSERT"
        && data.record?.group_id === groupId && typeof data.record.id === "string") received.push(data.record.id);
    });
  });
}
try {
  const owner = await provision(), member = await provision(), outsider = await provision();
  const group = checked(await owner.client.rpc("create_group", { p_name: "Pal raw realtime check" })); assert.ok(group);
  groupId = group.id;
  checked(await db.from("groups").update({ agent_paused: true, proactive_suggestions: false }).eq("id", groupId).eq("creator_id", owner.id));
  checked(await member.client.rpc("join_group", { p_invite_code: group.invite_code }));
  const received: string[][] = [[], [], []];
  await Promise.all(users.map((user, index) => subscribe(user.token, received[index], ["owner", "member", "outsider"][index])));
  const response = await fetch(`${origin.origin}/api/groups/${groupId}/messages`, { method: "POST", redirect: "error",
    headers: { authorization: `Bearer ${member.token}`, "content-type": "application/json" },
    body: JSON.stringify({ body: "Actual raw Realtime proof.", client_id: randomUUID() }), signal: AbortSignal.timeout(30000) });
  assert.ok(response.ok, `Actual member message API returned ${response.status}.`);
  const { message: source } = await response.json(); assert.ok(source);
  const deadline = Date.now() + 15000;
  while ((!received[0].includes(source.id) || !received[1].includes(source.id)) && Date.now() < deadline) await sleep(100);
  assert.ok(received[0].includes(source.id), "Raw protocol owner received no actual INSERT.");
  assert.ok(received[1].includes(source.id), "Raw protocol member received no actual INSERT.");
  await sleep(2000); assert.equal(received[2].length, 0, "Raw protocol outsider must receive no protected INSERT.");
  console.log("PASS: actual raw v1 WebSocket INSERT reached both members after CDC readiness; authenticated outsider received none.");
} finally {
  for (const heartbeat of heartbeats) clearInterval(heartbeat);
  for (const socket of sockets) socket.close();
  if (groupId) checked(await db.from("groups").delete().eq("id", groupId).eq("creator_id", users[0].id));
  for (const user of users) { await user.client.auth.signOut({ scope: "local" }); assert.ifError((await db.auth.admin.deleteUser(user.id)).error); }
}
