import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { admin, checked, env } from "../lib/db";
const owner = "b7731e13-e241-46a5-b9a3-ed6f58e15d39", ronny = "554485c1-83b8-410b-8a5c-6f5d3591ef64";
assert.equal(new URL(env("SUPABASE_URL")).hostname.split(".")[0], "glfwbiwanenrfwyljqiq");
const apply = process.argv.includes("--apply"), db = admin();
const groups = checked(await db.from("groups").select("*")) ?? [];
const memberships = checked(await db.from("group_members").select("group_id,user_id")) ?? [];
const identities = (await db.auth.admin.listUsers({ perPage: 1000 })).data.users;
const byID = new Map(identities.map(user => [user.id, user]));
const cleanup = groups.filter(group => /^Pal (hackathon demo|isolated smoke group)$/.test(group.name)
  && memberships.filter(m => m.group_id === group.id).length > 0
  && memberships.filter(m => m.group_id === group.id).every(m => byID.get(m.user_id)?.email?.endsWith("@pal-demo.example")));
const sync = checked(await db.rpc("pal_integration_state", { p_kind: "google_sync_items", p_limit: 200 })) as { plan_id: string; event_id?: string }[];
assert.ok(sync.length < 200, "Inspect every calendar item before cleanup.");
const actorNames = ["Maya", "Theo", "Ben"];
const profiles = checked(await db.from("profiles").select("user_id,display_name,avatar_path")) ?? [];
const actors = actorNames.map(name => {
  const profile = profiles.find(p => p.display_name === name && byID.get(p.user_id)?.email?.startsWith("seed-") && byID.get(p.user_id)?.user_metadata?.fictional === true);
  assert.ok(profile?.avatar_path, `No verified fictional photo profile for ${name}.`); return profile;
});
const base = groups.find(g => g.is_demo && g.creator_id === owner && g.name !== "Demo · Chat") ?? groups.find(g => g.name === "Friday dinner" && g.creator_id === owner); assert.ok(base);
const places = checked(await db.from("places").select("*").eq("group_id", base.id));
assert.ok(places?.some(p => /delfina/i.test(p.name)), "Reuse the actual previously resolved restaurant, not a fabricated result.");
console.log(JSON.stringify({ apply, cleanup: cleanup.map(g => ({ id:g.id, name:g.name })), preserve: groups.filter(g => !cleanup.includes(g)).length, room: "Demo", actors: actorNames }));
if (!apply) process.exit(0);
await mkdir(".secrets", { recursive: true, mode: 0o700 });
const backup: Record<string, unknown> = { project: "glfwbiwanenrfwyljqiq", created_at: new Date().toISOString() };
const ids = cleanup.map(g => g.id);
for (const table of ["groups","group_members","messages","agent_jobs","places","sources","plans","polls","reminders","member_memories","source_contributors","place_contributors","message_attachments","message_reactions","plan_rsvps","poll_responses"]) {
  if (!ids.length) break;
  const query = db.from(table).select("*").in(table === "groups" ? "id" : "group_id", ids);
  const rows = checked(await query); assert.ok((rows?.length ?? 0) < 1000, "Backup must not silently truncate."); backup[table] = rows;
}
const plans = backup.plans as { id:string }[] | undefined;
assert.ok(!sync.some(item => item.event_id && plans?.some(p => p.id === item.plan_id)), "Do not orphan a real calendar event.");
const backupPath = `.secrets/fixture-cleanup-${randomUUID()}.json`;
await writeFile(backupPath, JSON.stringify(backup), { mode: 0o600, flag: "wx" });
if (ids.length) checked(await db.from("groups").delete().in("id", ids));
let demo = groups.find(g => g.is_demo && g.creator_id === owner && g.name !== "Demo · Chat");
const registered = demo ? (checked(await db.rpc("pal_group_state", { p_group_id: demo.id })) as { demo?: unknown })?.demo : null;
if (!registered) {
  const groupID = demo?.id ?? randomUUID();
  if (!demo) demo = checked(await db.from("groups").insert({ id: groupID, name: "Demo", creator_id: owner, is_demo: true, agent_paused: false,
    proactive_suggestions: false, timezone: "America/Los_Angeles", avatar_path: base.avatar_path }).select("*").single()); assert.ok(demo);
  checked(await db.from("group_members").upsert([owner,ronny,...actors.map(a=>a.user_id)].map(user_id=>({group_id:groupID,user_id})), { onConflict: "group_id,user_id", ignoreDuplicates: true }));
  const baseIDs: string[] = [];
  for (const place of places ?? []) {
    const existing = checked(await db.from("places").select("id").eq("group_id", groupID).eq("provider_id", place.provider_id).maybeSingle());
    if (existing) { baseIDs.push(existing.id); continue; }
    const placeID = randomUUID(), messageID = randomUUID(), sourceID = randomUUID(); baseIDs.push(placeID);
    checked(await db.from("messages").insert({ id:messageID,group_id:groupID,sender_id:actors[0].user_id,role:"user",body:`Saving ${place.name} for dinner. ${place.website ?? ""}`,
      source_key:`demo:seed:${placeID}`,created_at:new Date(Date.now()-3600000).toISOString() }));
    const { id:_id,group_id:_group,created_at:_created,updated_at:_updated,...facts }=place;
    checked(await db.from("places").insert({...facts,id:placeID,group_id:groupID,created_by:owner}));
    if(place.website){
      checked(await db.from("sources").insert({id:sourceID,group_id:groupID,created_by:owner,source_message_id:messageID,url:place.website,canonical_url:place.website,
        status:"resolved",title:place.name,place_ids:[placeID],place_id:placeID,metadata:{title:place.name},extraction:{places:[{name:place.name,address:place.address,city:"San Francisco",dishes:[],prices:[],evidence:[],confidence:"high"}]}}));
      checked(await db.from("source_contributors").insert({group_id:groupID,source_id:sourceID,user_id:actors[0].user_id,source_message_id:messageID}));
      checked(await db.from("place_contributors").insert({group_id:groupID,place_id:placeID,user_id:actors[0].user_id,source_id:sourceID,source_message_id:messageID}));
    }
  }
  const ownGroups = memberships.filter(m=>m.user_id===owner).map(m=>m.group_id);
  const inspected = checked(await db.from("sources").select("*").in("group_id",ownGroups).in("status",["resolved","needs_confirmation"]).order("updated_at",{ascending:false}).limit(3)) ?? [];
  for (const source of inspected) {
    const duplicate=checked(await db.from("sources").select("id").eq("group_id",groupID).eq("canonical_url",source.canonical_url).maybeSingle()); if(duplicate)continue;
    const sourceID=randomUUID(), messageID=randomUUID();
    checked(await db.from("messages").insert({id:messageID,group_id:groupID,sender_id:actors[1].user_id,role:"user",body:`Another saved idea. ${source.url}`,source_key:`demo:seed:${sourceID}`,created_at:new Date(Date.now()-1800000).toISOString()}));
    checked(await db.from("sources").insert({id:sourceID,group_id:groupID,created_by:owner,source_message_id:messageID,url:source.url,canonical_url:source.canonical_url,
      status:"needs_confirmation",title:source.title,metadata:source.metadata,extraction:source.extraction,candidates:source.candidates,place_ids:[]}));
    checked(await db.from("source_contributors").insert({group_id:groupID,source_id:sourceID,user_id:actors[1].user_id,source_message_id:messageID}));
  }
  // Register only this room and this verified fictional cast through a service-only setup operation.
  checked(await db.rpc("pal_demo_register",{p_group_id:groupID,p_actor_ids:actors.map(a=>a.user_id),p_place_ids:baseIDs}));
  checked(await db.rpc("pal_demo_reset",{p_group_id:groupID,p_user_id:owner}));
}
await writeFile(".secrets/demo-room.json",JSON.stringify({group_id:demo.id,owner,actors:actors.map(a=>a.user_id),backup:backupPath}),{mode:0o600});
console.log(JSON.stringify({demo_id:demo.id,cleaned:ids.length,backup:backupPath,normal_rooms_preserved:true}));
