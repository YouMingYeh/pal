import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { admin, checked, env } from "../lib/db";

assert.equal(new URL(env("SUPABASE_URL")).hostname.split(".")[0], "glfwbiwanenrfwyljqiq");
const db = admin();
const seed = JSON.parse(await readFile(".secrets/demo-room.json", "utf8")) as { group_id: string };
const dinner = checked(await db.from("groups").select("*").eq("id", seed.group_id).single());
assert.ok(dinner.is_demo && !dinner.is_direct, "The original registered rehearsal is required.");
const actors = checked(await db.rpc("pal_demo_cast", { p_group_id: dinner.id, p_user_id: dinner.creator_id })) as string[];
assert.equal(actors.length, 3);
const members = checked(await db.from("group_members").select("user_id").eq("group_id", dinner.id)) ?? [];
assert.equal(members.length, 5);
assert.ok(members.some(member => member.user_id === dinner.creator_id));
const apply = process.argv.includes("--apply");
if (!apply) {
  console.log(JSON.stringify({ ready: true, dinner: dinner.id, members: members.length, apply: false }));
  process.exit(0);
}
checked(await db.from("groups").update({ name: "Demo · Dinner" }).eq("id", dinner.id).eq("is_demo", true));
let chat = checked(await db.from("groups").select("*").eq("creator_id", dinner.creator_id).eq("is_demo", true).eq("is_direct", false).eq("name", "Demo · Chat").maybeSingle());
if (!chat) {
  chat = checked(await db.from("groups").insert({ name: "Demo · Chat", creator_id: dinner.creator_id,
    is_demo: true, is_direct: false, agent_paused: false, proactive_suggestions: false,
    timezone: dinner.timezone, avatar_path: dinner.avatar_path }).select("*").single());
  checked(await db.from("group_members").upsert(members.map(member => ({ group_id: chat.id, user_id: member.user_id })), { onConflict: "group_id,user_id", ignoreDuplicates: true }));
  checked(await db.rpc("pal_demo_register", { p_group_id: chat.id, p_actor_ids: actors, p_place_ids: [], p_kind: "chat" }));
  checked(await db.rpc("pal_demo_reset", { p_group_id: chat.id, p_user_id: dinner.creator_id }));
} else {
  const chatActors = checked(await db.rpc("pal_demo_cast", { p_group_id: chat.id, p_user_id: dinner.creator_id })) as string[];
  assert.deepEqual(chatActors, actors, "An existing room must have the same verified cast.");
}
await writeFile(".secrets/demo-room.json", JSON.stringify({ ...seed, actors, chat_group_id: chat.id }), { mode: 0o600 });
await writeFile(".secrets/demo-rooms.json", JSON.stringify({ dinner: dinner.id, chat: chat.id, owner: dinner.creator_id, actors }), { mode: 0o600 });
console.log(JSON.stringify({ ready: true, dinner: dinner.id, chat: chat.id, existingDinnerHistoryPreserved: true }));
