import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import sharp from "sharp";
import { createClient } from "@supabase/supabase-js";
import { admin, checked, env } from "../lib/db";

process.loadEnvFile(".env.demo.local");
const base = (process.argv[2] ?? env("PAL_BASE_URL")).replace(/\/$/, "");
const db = admin();
const users = await Promise.all(["ALICE", "BOB", "OUTSIDER"].map(async name => {
  const client = createClient(env("SUPABASE_URL"), env("SUPABASE_PUBLISHABLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await client.auth.signInWithPassword({ email: env(`DEMO_${name}_EMAIL`), password: env(`DEMO_${name}_PASSWORD`) });
  assert.ifError(error); assert.ok(data.user && data.session);
  return { client, id: data.user.id, token: data.session.access_token };
}));
const [owner, member, outsider] = users;
type User = typeof owner;
const call = (user: User, path: string, method = "GET", body?: BodyInit) => fetch(`${base}${path}`, { method, headers: { Authorization: `Bearer ${user.token}`, ...(typeof body === "string" ? { "Content-Type": "application/json" } : {}) }, body });
async function json(user: User, path: string, method = "GET", body?: unknown) {
  const response = await call(user, path, method, body ? JSON.stringify(body) : undefined);
  assert.ok(response.ok, `${method} ${path} returned ${response.status}`); return response.json();
}
const picture = await sharp({ create: { width: 1600, height: 800, channels: 3, background: "#b1c7ad" } }).jpeg().withExif({ IFD0: { Copyright: "Test image metadata" } }).toBuffer();
const audio = await readFile(new URL("../tests/fixtures/voice-apple-aac.m4a", import.meta.url));
const createId = randomUUID();
function groupForm(name = "Private media verification", image = picture) {
  const form = new FormData(); form.set("name", name); form.set("client_id", createId);
  form.set("file", new File([image], "group.jpg", { type: "image/jpeg" })); return form;
}
function mediaForm(kind: "image" | "audio", clientId: string, bytes: Buffer, body?: string) {
  const form = new FormData(); form.set("kind", kind); form.set("client_id", clientId);
  form.set("file", new File([new Uint8Array(bytes)], kind === "image" ? "photo.jpg" : "voice.m4a", { type: kind === "image" ? "image/jpeg" : "audio/mp4" }));
  if (body) form.set("body", body); return form;
}
let groupId: string | undefined;
const groupPhotoBefore = checked(await db.storage.from("avatars").list(`groups/${owner.id}`, { limit: 1000 })) ?? [];
try {
  const createResponse = await call(owner, "/api/groups", "POST", groupForm());
  assert.equal(createResponse.status, 201); const { group } = await createResponse.json(); groupId = group.id;
  assert.ok(group.avatar_url); assert.equal("avatar_path" in group, false);
  assert.equal((await fetch(group.avatar_url)).status, 200);
  const retry = await call(owner, "/api/groups", "POST", groupForm());
  assert.equal(retry.status, 201); assert.equal((await retry.json()).group.id, group.id);
  assert.equal((await call(owner, "/api/groups", "POST", groupForm("Changed name"))).status, 400);
  const groupPhotoAfter = checked(await db.storage.from("avatars").list(`groups/${owner.id}`, { limit: 1000 })) ?? [];
  assert.equal(groupPhotoAfter.filter(row => !groupPhotoBefore.some(previous => previous.name === row.name)).length, 1, "Creation retries and conflicts leave only the linked group photo.");
  await json(member, "/api/groups/join", "POST", { invite_code: group.invite_code });
  await json(owner, `/api/groups/${group.id}/state`, "POST", { action: "group.settings", data: { agent_paused: true } });
  const joinedState = await json(member, `/api/groups/${group.id}/state`);
  assert.ok(joinedState.settings.avatar_url); assert.equal("avatar_path" in joinedState.settings, false);
  assert.ok((await json(member, "/api/groups")).groups.find((row: { id: string }) => row.id === group.id).avatar_url);
  const storedGroup = checked(await db.from("groups").select("avatar_path").eq("id", group.id).single());
  assert.ok(storedGroup?.avatar_path);
  assert.ok(!(await fetch(db.storage.from("avatars").getPublicUrl(storedGroup.avatar_path).data.publicUrl)).ok);
  console.log("PASS: name/photo creation is atomic, retry-safe and visible only through authorized group reads.");
  const photoId = randomUUID(), audioId = randomUUID();
  // Exercise Foundation's UUID spelling at the real upload/storage boundary.
  const endpoint = `/api/groups/${group.id.toUpperCase()}/attachments`;
  const photoResponse = await call(owner, endpoint, "POST", mediaForm("image", photoId, picture));
  assert.equal(photoResponse.status, 201); const photo = (await photoResponse.json()).message;
  const photoRetry = await call(owner, endpoint, "POST", mediaForm("image", photoId, picture));
  assert.equal(photoRetry.status, 201); assert.equal((await photoRetry.json()).message.id, photo.id);
  assert.equal((await call(owner, endpoint, "POST", mediaForm("image", photoId, picture, "Changed caption"))).status, 400);
  const differentImage = await sharp({ create: { width: 40, height: 40, channels: 3, background: "red" } }).jpeg().toBuffer();
  assert.equal((await call(owner, endpoint, "POST", mediaForm("image", photoId, differentImage))).status, 400);
  const voiceForm = mediaForm("audio", audioId, audio); voiceForm.set("reply_to_id", photo.id);
  const audioResponse = await call(member, endpoint, "POST", voiceForm);
  assert.equal(audioResponse.status, 201); const voice = (await audioResponse.json()).message;
  assert.equal(voice.reply_to_id, photo.id); assert.ok(voice.attachments[0].duration_ms >= 1068 && voice.attachments[0].duration_ms <= 1070);
  const voiceRetry = mediaForm("audio", audioId, audio); voiceRetry.set("reply_to_id", photo.id);
  assert.equal((await call(member, endpoint, "POST", voiceRetry)).status, 201);
  const messages = (await json(member, `/api/groups/${group.id}/messages`)).messages;
  for (const message of [photo, voice]) {
    const shared = messages.find((row: { id: string }) => row.id === message.id);
    assert.equal(shared.attachments.length, 1); assert.ok(shared.attachments[0].url);
    assert.equal("object_path" in shared.attachments[0], false);
    const media = await fetch(shared.attachments[0].url); assert.equal(media.status, 200);
    const bytes = Buffer.from(await media.arrayBuffer());
    if (shared.attachments[0].kind === "image") {
      const metadata = await sharp(bytes).metadata(); assert.equal(metadata.format, "jpeg");
      assert.equal(metadata.width, 1024); assert.equal(metadata.exif, undefined);
    } else assert.deepEqual(bytes, audio);
  }
  const rows = checked(await db.from("message_attachments").select("*").eq("group_id", group.id));
  assert.equal(rows?.length, 2, "Retries persist exactly one photo and one audio attachment.");
  for (const user of [owner, member]) {
    const objects = checked(await db.storage.from("message-attachments").list(`${group.id}/${user.id}`, { limit: 1000 }));
    assert.equal(objects?.length, 1, "Upload retries leave only the linked media object.");
  }
  assert.equal((await call(outsider, endpoint, "POST", mediaForm("image", randomUUID(), picture))).status, 403);
  assert.equal((await call(outsider, `/api/groups/${group.id}/messages`)).status, 403);
  for (const row of rows ?? []) {
    assert.ok(!(await fetch(db.storage.from("message-attachments").getPublicUrl(row.object_path).data.publicUrl)).ok);
    assert.ok((await outsider.client.storage.from("message-attachments").createSignedUrl(row.object_path, 60)).error);
    assert.ok((await outsider.client.storage.from("message-attachments").upload(row.object_path, picture, { contentType: "image/jpeg", upsert: true })).error);
  }
  assert.equal((await call(owner, endpoint, "POST", mediaForm("audio", randomUUID(), Buffer.from("not audio")))).status, 400);
  assert.equal((await call(owner, endpoint, "POST", mediaForm("image", randomUUID(), Buffer.from("not a JPEG")))).status, 400);
  console.log("PASS: real photo/audio messages, playback URLs, reply links and retries work for two members.");
  console.log("PASS: changed retries, outsider access, public storage, forged media and private writes are denied.");
} finally {
  if (groupId) {
    const group = checked(await db.from("groups").select("avatar_path").eq("id", groupId).maybeSingle());
    const rows = checked(await db.from("message_attachments").select("object_path").eq("group_id", groupId));
    if (rows?.length) checked(await db.storage.from("message-attachments").remove(rows.map(row => row.object_path)));
    if (group?.avatar_path) checked(await db.storage.from("avatars").remove([group.avatar_path]));
    checked(await db.from("groups").delete().eq("id", groupId));
  }
  await Promise.all(users.map(user => user.client.auth.signOut({ scope: "local" })));
}
