import assert from "node:assert/strict";
import sharp from "sharp";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { admin, checked, env } from "../lib/db";

process.loadEnvFile(".env.demo.local");
const base = (process.argv[2] ?? env("PAL_BASE_URL")).replace(/\/$/, "");
const db = admin();
const identities = await Promise.all(["OUTSIDER", "ALICE", "BOB"].map(async name => {
  const client = createClient(env("SUPABASE_URL"), env("SUPABASE_PUBLISHABLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await client.auth.signInWithPassword({ email: env(`DEMO_${name}_EMAIL`), password: env(`DEMO_${name}_PASSWORD`) });
  assert.ifError(error);
  assert.ok(data.user && data.session);
  const profile = checked(await db.from("profiles").select("*").eq("user_id", data.user.id).maybeSingle());
  return { client, id: data.user.id, token: data.session.access_token, profile };
}));
// Choose a demo identity without an existing photo. Never replace a user's saved photo for a test.
const owner = identities.find(user => !user.profile?.avatar_path && !user.profile?.avatar_url);
assert.ok(owner, "An isolated demo identity without an existing photo is required.");
const [viewer, outsider] = identities.filter(user => user !== owner);
type User = typeof viewer;
async function request(user: User, path: string, method = "GET", body?: BodyInit, headers: Record<string, string> = {}) {
  return fetch(`${base}${path}`, { method, headers: { Authorization: `Bearer ${user.token}`, ...headers }, ...(body ? { body } : {}) });
}
async function api(user: User, path: string, method = "GET", data?: unknown) {
  const response = await request(user, path, method, data ? JSON.stringify(data) : undefined, { "Content-Type": "application/json" });
  assert.ok(response.ok, `${method} ${path} returned ${response.status}`);
  return response.json();
}
const original = (await api(owner, "/api/profile")).profile;
let groupId: string | undefined;
try {
  const { group } = await api(owner, "/api/groups", "POST", { name: "Private avatar verification" });
  groupId = group.id;
  await api(viewer, "/api/groups/join", "POST", { invite_code: group.invite_code });
  const input = await sharp({ create: { width: 1600, height: 800, channels: 3, background: "#3478f6" } })
    .jpeg().withExif({ IFD0: { Copyright: "Private test camera metadata" } }).toBuffer();
  const form = new FormData();
  form.set("file", new File([input], "avatar.jpg", { type: "image/jpeg" }));
  form.set("display_name", "Avatar check");
  const response = await request(owner, "/api/profile/avatar", "POST", form);
  assert.ok(response.ok, `Avatar upload returned ${response.status}`);
  const { profile } = await response.json();
  assert.equal(profile.display_name, "Avatar check", "Name and photo save in one transaction.");
  assert.ok(profile.avatar_url?.includes("/object/sign/avatars/"));
  assert.equal("avatar_path" in profile, false);
  const stored = checked(await db.from("profiles").select("avatar_path").eq("user_id", owner.id).single());
  assert.ok(stored?.avatar_path);
  const avatarPath: string = stored.avatar_path;
  assert.ok(avatarPath.startsWith(`${owner.id}/`));
  const publicURL = db.storage.from("avatars").getPublicUrl(avatarPath).data.publicUrl;
  assert.ok(!(await fetch(publicURL)).ok, "The private photo must not be accessible through an unsigned public URL.");
  const imageResponse = await fetch(profile.avatar_url);
  assert.equal(imageResponse.status, 200);
  const normalized = await sharp(Buffer.from(await imageResponse.arrayBuffer())).metadata();
  assert.equal(normalized.format, "jpeg");
  assert.ok(normalized.width! <= 1024 && normalized.height! <= 1024);
  assert.equal(normalized.exif, undefined);
  const memberState = await api(viewer, `/api/groups/${group.id}/state`);
  const shown = memberState.members.find((member: { user_id: string }) => member.user_id === owner.id);
  assert.ok(shown.avatar_url);
  assert.equal("avatar_path" in shown, false);
  assert.equal((await fetch(shown.avatar_url)).status, 200);
  const deniedState = await request(outsider, `/api/groups/${group.id}/state`);
  assert.equal(deniedState.status, 403);
  const readOther = await outsider.client.from("profiles").select("user_id").eq("user_id", owner.id);
  assert.ifError(readOther.error);
  assert.equal(readOther.data?.length, 0, "Outsider cannot retrieve the owner's profile.");
  const signedOther = await viewer.client.storage.from("avatars").createSignedUrl(avatarPath, 60);
  assert.ok(signedOther.error, "Even a group member cannot sign arbitrary storage paths directly.");
  const overwrite = await outsider.client.storage.from("avatars").upload(avatarPath, input, { contentType: "image/jpeg", upsert: true });
  assert.ok(overwrite.error, "Outsider cannot overwrite another member's stored photo.");
  const directRPC = await outsider.client.rpc("pal_avatar_replace", { p_user_id: owner.id, p_avatar_path: `${owner.id}/${randomUUID()}.jpg` });
  assert.ok(directRPC.error, "Member credentials cannot invoke the avatar service RPC.");
  const forged = new FormData();
  forged.set("file", new File([input], "avatar.jpg", { type: "image/jpeg" }));
  forged.set("user_id", owner.id);
  assert.equal((await request(outsider, "/api/profile/avatar", "POST", forged)).status, 400);
  const fake = new FormData();
  fake.set("file", new File(["not an image"], "avatar.jpg", { type: "image/jpeg" }));
  assert.equal((await request(owner, "/api/profile/avatar", "POST", fake)).status, 400);
  assert.equal(checked(await db.from("profiles").select("avatar_path").eq("user_id", owner.id).single())?.avatar_path, avatarPath);
  console.log("PASS: real JPEG upload atomically saves name/photo, strips metadata and serves authorized signed URLs.");
  console.log("PASS: cross-user paths, private storage signing/writes, forged owner fields and fake images are denied.");
  await api(owner, "/api/profile", "PATCH", { display_name: original.display_name, avatar_url: null });
  assert.equal((await api(owner, "/api/profile")).profile.avatar_url, null);
  assert.equal(checked(await db.from("profiles").select("avatar_path").eq("user_id", owner.id).single())?.avatar_path, null);
  assert.equal((await api(viewer, `/api/groups/${group.id}/state`)).members.find((member: { user_id: string }) => member.user_id === owner.id).avatar_url, null);
  const removed = await db.storage.from("avatars").download(avatarPath);
  assert.ok(removed.error, "Removed avatar object is cleaned up, not merely hidden.");
  console.log("PASS: removing a photo clears group/profile URLs and deletes its private object.");
} finally {
  // Cleanup only this photo-less test identity and the newly-created group.
  await api(owner, "/api/profile/avatar", "DELETE");
  await api(owner, "/api/profile", "PATCH", { display_name: original.display_name, avatar_url: null });
  if (groupId) checked(await db.from("groups").delete().eq("id", groupId));
  await Promise.all(identities.map(user => user.client.auth.signOut()));
}
