import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile, chmod, access } from "node:fs/promises";
import { resolve } from "node:path";
import { admin, checked, env } from "../lib/db";
import { normalizeAvatar } from "../lib/avatar";
import { resolvePlace } from "../lib/maps";

// Fictional prototype characters. Portraits: Pravatar CC0, https://pravatar.cc/.
// No historical Auth identity, Google connection, profile or device is deleted.
const PROJECT = "glfwbiwanenrfwyljqiq", HUMAN = "b7731e13-e241-46a5-b9a3-ed6f58e15d39";
const db = admin(), args = process.argv.slice(2);
const value = (flag: string) => args[args.indexOf(flag) + 1];
const project = new URL(env("SUPABASE_URL")).hostname.split(".")[0];
assert.equal(project, PROJECT, "Refusing to reset another Supabase project.");
assert.equal(value("--target"), HUMAN, "Supply the explicitly authorized human's full UUID.");
assert.ok(args.includes("--prepare") !== args.includes("--reset"), "Choose exactly --prepare or --reset.");
const actors = [
  { key: "maya", name: "Maya", image: 47 }, { key: "theo", name: "Theo", image: 12 },
  { key: "jess", name: "Jess", image: 44 }, { key: "alex", name: "Alex", image: 13 },
  { key: "nina", name: "Nina", image: 49 }, { key: "ben", name: "Ben", image: 33 },
  { key: "lena", name: "Lena", image: 45 }, { key: "sam", name: "Sam", image: 15 },
];
type Line = [string, string, string?];
const rooms: { name: string; actors: string[]; place: number; lines: Line[] }[] = [
  { name: "Friday dinner", actors: ["maya", "theo", "jess", "alex"], place: 0, lines: [
    ["maya", "Can we have one Friday where dinner isn't decided at 8:47?"], ["theo", "That sounds suspiciously like planning."],
    ["pal", "A bold new era for this group. I'll believe it when there's a time.", "fier"], ["jess", "I'm in. Pasta?"],
    ["alex", "I vote food that doesn't arrive in a paper bag."], ["maya", "Delfina looks lovely. Here's the actual restaurant: https://www.delfinasf.com/"],
    ["theo", "I can do Friday after 7pm. Work has claimed the rest of my soul."], ["jess", "Vegetarian here, but pasta usually makes that easy."],
    ["human", "Let's keep it around $40 each before drinks."], ["pal", "$40 before drinks, vegetarian options, after seven. We've narrowed it down to an actual evening. Nice.", "attentif"],
    ["alex", "7:30 would save me from sprinting from the train."], ["maya", "7:30 sounds sensible. Who are we?"],
    ["theo", "Adults, briefly."], ["pal", "Please enjoy this rare sighting responsibly.", "hilare"],
    ["jess", "I haven't booked anything yet. We should check the menu first."], ["pal", "Good call. The official menu and reservation links are on their website. No table booked yet.", "curieux"],
    ["human", "Friday dinner is the plan we're leaning toward. Still need everyone to confirm."], ["maya", "I'll check with Alex before we lock it in."],
    ["alex", "I'm here, reading, and trying to finish one email."], ["pal", "The email can have its dramatic finale. We'll keep dinner as a draft for now.", "fier"],
  ] },
  { name: "Weekend crew", actors: ["nina", "ben", "lena", "sam"], place: 1, lines: [
    ["nina", "Saturday outside? I need to see a tree that isn't on a screen."], ["ben", "Dolores picnic?"],
    ["lena", "Yes. A low-effort weekend is my love language."], ["pal", "Picnic: the rare plan where sitting down counts as participation.", "fier"],
    ["sam", "Can we make it late morning?"], ["human", "Around noon works better for me."],
    ["nina", "I can bring a blanket."], ["ben", "I'll bring snacks. Nothing fancy, budget is about $15 each."],
    ["lena", "Please skip nuts in the snacks. I avoid them."], ["pal", "Blanket, simple snacks, no nuts. What are we thinking for drinks?", "curieux"],
    ["sam", "Sparkling water and coffee sounds perfect."], ["nina", "And maybe a walk afterward if everyone feels like it."],
    ["ben", "I can do Saturday noon, but I need to leave by 3."], ["human", "No problem. Let's keep the walk optional."],
    ["pal", "Noon picnic, optional walk, Ben escapes at three. A plan with an exit strategy. Excellent.", "heureux"],
    ["lena", "Rough week. Honestly just happy to see you all."], ["pal", "Then let's keep this easy. Come as you are; nobody needs to be the entertaining one.", "triste"],
    ["sam", "I'll bring cups so we don't improvise with the coffee lids again."], ["ben", "One time."],
    ["pal", "An iconic one time. The cups will be appreciated.", "hilare"], ["nina", "Let's check the forecast Friday, then confirm."],
  ] },
  { name: "Lunch break", actors: ["maya", "nina", "alex", "sam"], place: 2, lines: [
    ["alex", "Lunch tomorrow? My calendar has accidentally left me an hour."], ["maya", "A miracle. Don't refresh it."],
    ["human", "Something quick around 12:30?"], ["nina", "Tartine sandwich and a short walk?"],
    ["pal", "An actual lunch break with daylight. I'm rooting for this one.", "heureux"],
    ["sam", "I'm good with anything under $20."], ["maya", "Same. I prefer somewhere casual, no long sit-down lunch."],
    ["alex", "I've only got 45 minutes, so takeaway might be better."], ["pal", "Under $20, casual, forty-five minutes. Takeaway gives Alex a fighting chance.", "attentif"],
    ["nina", "I can meet you outside at 12:30."], ["human", "Let's use the original bakery, not the other location."],
    ["sam", "Good distinction. I was absolutely about to go to the other one."], ["pal", "A geographically preventable plot twist. Original bakery it is.", "fier"],
    ["maya", "Can someone send the address?"], ["nina", "600 Guerrero Street. Official site: https://tartinebakery.com/"],
    ["alex", "Nice. I'll check the line when I get there."], ["pal", "Perfect. We haven't checked the current queue or menu prices, so keep a backup nearby.", "curieux"],
    ["human", "If the line is ridiculous, let's just grab something nearby."], ["sam", "Agreed. Food first, bakery prestige second."],
    ["pal", "Finally, a hierarchy I can support.", "hilare"],
  ] },
];
const tables = ["groups", "group_members", "messages", "message_attachments", "message_reactions", "agent_jobs", "reminders", "sources", "source_contributors", "places", "place_contributors", "polls", "poll_responses", "plans", "plan_rsvps", "member_memories"];
const secretDir = resolve(".secrets");
async function secureWrite(path: string, data: unknown) {
  await mkdir(secretDir, { recursive: true, mode: 0o700 }); await chmod(secretDir, 0o700);
  await writeFile(path, JSON.stringify(data, null, 2), { mode: 0o600, flag: "wx" }); await chmod(path, 0o600);
}
async function rows(table: string) {
  const result: unknown[] = [];
  for (let offset = 0; ; offset += 500) {
    const page = checked(await db.from(table).select("*").range(offset, offset + 499)) ?? [];
    result.push(...page); if (page.length < 500) return result;
  }
}
function upcomingLocal(day: number, hour: number, minute: number) {
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Los_Angeles", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
  const anchor = new Date(today + "T12:00:00Z");
  const days = day < 0 ? 1 : (day - anchor.getUTCDay() + 7) % 7 || 7;
  const date = new Date(anchor.getTime() + days * 86400000).toISOString().slice(0, 10);
  const offset = new Intl.DateTimeFormat("en-US", { timeZone: "America/Los_Angeles", timeZoneName: "shortOffset" }).formatToParts(new Date(date + "T12:00:00Z")).find(part => part.type === "timeZoneName")!.value;
  const match = offset.match(/^GMT([+-])(\d{1,2})(?::(\d{2}))?$/); assert.ok(match);
  return new Date(`${date}T${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}:00${match[1]}${match[2].padStart(2, "0")}:${match[3] ?? "00"}`).toISOString();
}
type Manifest = { version: 1; project: string; human: string; marker: string; created_at: string; teammates: string[]; actors: (typeof actors[number] & { id: string; avatar: string })[]; places: Awaited<ReturnType<typeof resolvePlace>>[number][] };
if (args.includes("--prepare")) {
  const human = await db.auth.admin.getUserById(HUMAN); assert.ifError(human.error); assert.ok(human.data.user);
  const teammates = args.filter(arg => arg.startsWith("--teammate=")).map(arg => arg.slice(11));
  for (const id of teammates) { const user = await db.auth.admin.getUserById(id); assert.ifError(user.error); assert.ok(user.data.user); }
  const portraits = [];
  for (const actor of actors) {
    const response = await fetch(`https://i.pravatar.cc/300?img=${actor.image}`, { signal: AbortSignal.timeout(20000) });
    assert.ok(response.ok, "A prototype portrait could not be staged.");
    const image = await normalizeAvatar(Buffer.from(await response.arrayBuffer()), response.headers.get("content-type")?.split(";")[0] ?? "");
    portraits.push({ ...actor, id: randomUUID(), avatar: image.toString("base64") });
  }
  // Actual provider lookups must succeed before any reset. Never fabricate search results.
  const verifiedPlaces = [];
  for (const query of ["Delfina 3621 18th Street San Francisco", "Mission Dolores Park San Francisco", "Tartine Bakery 600 Guerrero Street San Francisco"]) {
    const candidates = await resolvePlace(query); assert.ok(candidates.length, `No verified place for ${query}.`); verifiedPlaces.push(candidates[0]);
  }
  const manifest: Manifest = { version: 1, project: PROJECT, human: HUMAN, marker: randomUUID(), created_at: new Date().toISOString(), teammates, actors: portraits, places: verifiedPlaces };
  const path = resolve(secretDir, `demo-seed-${manifest.marker}.json`); await secureWrite(path, manifest);
  console.log(`Prepared ${rooms.length} rooms and eight fictional photo profiles without clearing live chat. Manifest: ${path}`);
} else {
  assert.ok(args.includes("--ack-calendar-clean"), "Root must finish old Google event cleanup before resetting chat.");
  assert.ok(args.includes("--manifest"), "Supply a reviewed private manifest.");
  const path = resolve(value("--manifest")); assert.ok(path.startsWith(secretDir + "/"), "Use the private prepared manifest.");
  const manifest = JSON.parse(await readFile(path, "utf8")) as Manifest;
  assert.equal(manifest.version, 1); assert.equal(manifest.project, PROJECT); assert.equal(manifest.human, HUMAN);
  assert.equal(manifest.actors.length, 8); assert.equal(manifest.places.length, 3);
  const receipt = resolve(secretDir, `demo-receipt-${manifest.marker}.json`);
  try {
    await access(receipt);
    const completed = JSON.parse(await readFile(receipt, "utf8"));
    assert.equal(completed.marker, manifest.marker);
    assert.equal(checked(await db.from("groups").select("id").in("id", completed.groups))?.length, completed.groups.length);
    console.log("This exact reviewed demo seed is already complete; nothing changed."); process.exit(0);
  } catch (error) { if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) throw error; }
  assert.ok(Date.now() - Date.parse(manifest.created_at) < 86400000, "Stage fresh verified places and photos before resetting.");
  const pendingCalendar = checked(await db.rpc("pal_integration_state", { p_kind: "google_sync_items", p_limit: 200 })) as { event_id?: string }[];
  assert.ok(pendingCalendar.length < 200, "Calendar cleanup inspection was truncated; root must verify all rows.");
  assert.ok(pendingCalendar.every(row => !row.event_id), "Old Google event IDs remain; deleting their group could orphan calendar entries.");
  const activeJobs = checked(await db.from("agent_jobs").select("id").eq("status", "running").gt("lease_until", new Date().toISOString()));
  assert.equal(activeJobs?.length, 0, "Allow actual running Pal turns to finish before taking the backup.");
  const backup: Record<string, unknown> = { project: PROJECT, human: HUMAN, created_at: new Date().toISOString(), manifest: path };
  for (const table of tables) backup[table] = await rows(table);
  const backupPath = resolve(secretDir, `chat-backup-${manifest.marker}.json`); await secureWrite(backupPath, backup);
  console.log(`Saved private chat backup: ${backupPath}`);
  const memberships = backup.group_members as { group_id: string; user_id: string }[];
  const currentShared = new Set(memberships.filter(member => member.user_id === HUMAN).map(member => member.group_id));
  const oldGroups = backup.groups as { id: string; is_direct: boolean; creator_id: string }[];
  const ownDirect = oldGroups.find(group => group.is_direct && group.creator_id === HUMAN);
  const previousGroups = oldGroups.filter(group => !group.is_direct && currentShared.has(group.id)).map(group => group.id);
  // Build all identities/photos BEFORE clearing anything. Reruns reuse only this manifest's marker.
  const actorIds = new Map<string, string>([["human", HUMAN]]);
  for (const actor of manifest.actors) {
    const email = `seed-${manifest.marker}-${actor.key}@pal-demo.example`;
    const user = await db.auth.admin.createUser({ id: actor.id, email, password: randomUUID() + randomUUID(), email_confirm: true, user_metadata: { demo_seed: manifest.marker, fictional: true, display_name: actor.name } });
    if (user.error) {
      const existing = await db.auth.admin.getUserById(actor.id);
      assert.ok(existing.data.user?.user_metadata?.demo_seed === manifest.marker, "Seed actor creation failed; existing identities must never be reused by name.");
    } else assert.equal(user.data.user?.id, actor.id, "Auth must retain the prepared actor UUID.");
    actorIds.set(actor.key, actor.id);
    const avatarPath = `${actor.id}/${manifest.marker}.jpg`;
    checked(await db.storage.from("avatars").upload(avatarPath, Buffer.from(actor.avatar, "base64"), { contentType: "image/jpeg", upsert: true }));
    checked(await db.rpc("pal_avatar_replace", { p_user_id: actor.id, p_avatar_path: avatarPath, p_display_name: actor.name }));
  }
  const now = Date.now(), seededIds: string[] = [];
  const dates = [upcomingLocal(5, 19, 30), upcomingLocal(6, 12, 0), upcomingLocal(-1, 12, 30)];
  const dateLabel = (date: string) => new Intl.DateTimeFormat("en-US", { timeZone: "America/Los_Angeles", weekday: "long", month: "long", day: "numeric" }).format(new Date(date));
  assert.ok(dates.every(date => Date.parse(date) > now));
  for (const place of manifest.places) assert.ok(place.name && place.address && Number.isFinite(place.latitude) && Number.isFinite(place.longitude));
  if (previousGroups.length) checked(await db.from("groups").delete().in("id", previousGroups));
  for (let roomIndex = 0; roomIndex < rooms.length; roomIndex++) {
    const room = rooms[roomIndex], groupId = randomUUID(); seededIds.push(groupId);
    checked(await db.from("groups").insert({ id: groupId, name: room.name, creator_id: HUMAN, agent_paused: true, proactive_suggestions: false, timezone: "America/Los_Angeles", last_weekly_at: new Date().toISOString() }));
    const start = now - (3 - roomIndex) * 86400000;
    const messages = room.lines.map(([speaker, original, emotion], index) => {
      const body = original.replace("Friday after 7pm", `${dateLabel(dates[0])} after 7pm`).replace("Saturday noon", `${dateLabel(dates[1])} at noon`).replace("Lunch tomorrow?", `Lunch ${dateLabel(dates[2])}?`);
      return { id: randomUUID(), group_id: groupId, sender_id: speaker === "pal" ? null : actorIds.get(speaker), role: speaker === "pal" ? "pal" : "user", body, emotion: speaker === "pal" ? emotion ?? "fier" : null, source_key: `demo:${manifest.marker}:${roomIndex}:${index}`, created_at: new Date(start + index * 330000).toISOString() };
    });
    // Members are attached only after historical INSERTs: no fabricated push flood or seed agent tasks.
    checked(await db.from("messages").insert(messages));
    const place = manifest.places[room.place], placeId = randomUUID();
    checked(await db.from("places").insert({ ...place, id: placeId, group_id: groupId, created_by: HUMAN, status: "resolved" }));
    checked(await db.from("plans").insert({ group_id: groupId, created_by: HUMAN, title: room.name, place_id: placeId, starts_at: dates[roomIndex], ends_at: new Date(Date.parse(dates[roomIndex]) + (roomIndex === 2 ? 45 : 120) * 60000).toISOString(), notes: "Discussed as a draft. Members still need to confirm. No reservation made.", status: "draft", booking_status: "needed" }));
    const memories = messages.filter(message => message.role === "user" && /vegetarian|skip nuts|\$40|\$15|\$20|casual|after 7pm|leave by 3/i.test(message.body)).map(message => ({ group_id: groupId, user_id: message.sender_id, kind: /after 7pm|leave by/.test(message.body) ? "availability" : "preference", key: /vegetarian|skip nuts/.test(message.body) ? "diet" : /\$/.test(message.body) ? "budget" : /casual/.test(message.body) ? "lunch_style" : "availability", value: message.body, source_message_id: message.id, expires_at: /after 7pm|leave by/.test(message.body) ? new Date(Date.parse(dates[roomIndex]) + 5 * 3600000).toISOString() : null }));
    if (memories.length) checked(await db.from("member_memories").insert(memories));
    const members = [...new Set([HUMAN, ...manifest.teammates, ...room.actors.map(key => actorIds.get(key)!)])];
    checked(await db.from("group_members").insert(members.map(user_id => ({ group_id: groupId, user_id }))));
  }
  // Keep the existing private room identity so a concurrent inbox refresh cannot
  // create a second owner room while the demo is being reset.
  const directId = ownDirect?.id ?? randomUUID(); seededIds.push(directId);
  if (ownDirect) {
    checked(await db.from("groups").update({ agent_paused: true, proactive_suggestions: false }).eq("id", directId).eq("creator_id", HUMAN));
    for (const table of ["agent_jobs", "reminders", "plans", "polls", "member_memories", "sources", "places", "messages"]) checked(await db.from(table).delete().eq("group_id", directId));
  } else checked(await db.from("groups").insert({ id: directId, name: "Pal", creator_id: HUMAN, is_direct: true, agent_paused: true, proactive_suggestions: false, last_weekly_at: new Date().toISOString() }));
  // Temporarily detach the sole owner before historical messages to prevent seed pushes.
  checked(await db.from("group_members").delete().eq("group_id", directId).eq("user_id", HUMAN));
  checked(await db.from("messages").insert([
    { group_id: directId, sender_id: HUMAN, role: "user", body: "Feels like there are three different plans going on. Help me keep track?", source_key: `demo:${manifest.marker}:dm:0`, created_at: new Date(now - 900000).toISOString() },
    { group_id: directId, role: "pal", body: "Three chats, one social life. Friday dinner is still a draft, the weekend crew is leaning toward a picnic, and lunch sounds like a quick takeaway. Nothing booked yet. What do you want to settle first?", emotion: "fier", source_key: `demo:${manifest.marker}:dm:1`, created_at: new Date(now - 840000).toISOString() },
  ]));
  checked(await db.from("group_members").insert({ group_id: directId, user_id: HUMAN }));
  checked(await db.from("agent_jobs").update({ status: "cancelled", lease_until: null }).in("group_id", seededIds).in("status", ["queued", "running"]));
  checked(await db.from("groups").update({ agent_paused: false, proactive_suggestions: true, last_weekly_at: new Date().toISOString() }).in("id", seededIds).eq("is_direct", false));
  checked(await db.from("groups").update({ agent_paused: false, proactive_suggestions: false }).eq("id", directId));
  await secureWrite(receipt, { marker: manifest.marker, groups: seededIds, fictional_users: manifest.actors.map(actor => actor.id), backup: backupPath, attribution: "Pravatar CC0, https://pravatar.cc/", note: "All seeded dialogue and character names are fictional prototype scenarios, not actual bookings or provider extraction results." });
  console.log(`Seeded three realistic group conversations and the human's private Pal chat. Receipt: ${receipt}`);
}
