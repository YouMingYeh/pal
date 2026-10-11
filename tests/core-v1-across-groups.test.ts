import assert from "node:assert/strict";
import { test } from "node:test";
import { acrossGroupsInput, boundedAcrossGroupContext, CROSS_GROUP_CONTEXT_LIMIT, readAcrossGroups } from "../lib/across-groups";

const id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const stamp = "2026-10-11T20:00:00Z";
const base = {
  id, name: "Weekend crew", timezone: "UTC", members: [{ user_id: id, display_name: "Amy", avatar_path: "private/member.jpg" }],
  messages: [{ id, sender_id: id, role: "user", body: "Friday at eight works.", created_at: stamp, card: null }],
  plans: [{ id, title: "Dinner", status: "confirmed", starts_at: stamp, ends_at: "2026-10-11T21:00:00Z", booking_status: "needed" }],
  places: [], sources: [], memories: [], avatar_path: "private/group.jpg", google_connection: { encrypted_refresh_token: "never return" },
};

test("cross-group tool input never accepts an actor, group ID or arbitrary search expression", () => {
  assert.deepEqual(acrossGroupsInput.parse({}), { offset: 0 });
  assert.deepEqual(acrossGroupsInput.parse({ offset: 5, query: " Dinner " }), { offset: 5, query: "Dinner" });
  for (const input of [{ actor_id: id }, { group_id: id }, { user_id: id }, { offset: -1 }, { offset: 1.5 }, { offset: 1001 }, { query: "x".repeat(101) }, { query: " " }]) {
    assert.throws(() => acrossGroupsInput.parse(input));
  }
});

test("cross-group context exposes grounded messages and plan states while stripping private fields", () => {
  const result = boundedAcrossGroupContext({ groups: [base], next_offset: null, secret: "excluded" });
  const json = JSON.stringify(result);
  assert.ok(!json.includes("private/") && !json.includes("encrypted_refresh_token") && !json.includes("google_connection"));
  assert.equal(result.groups[0].messages[0].created_at, stamp);
  assert.equal(result.groups[0].plans[0].status, "confirmed");
  assert.equal(result.groups[0].name, base.name);
  assert.equal(result.truncated, false);
  assert.throws(() => boundedAcrossGroupContext({ next_offset: null, groups: [{ ...base, messages: [{ ...base.messages[0], body: "x".repeat(501) }] }] }));
});

test("context budgets keep group names and newest source while admitting omitted or truncated detail", () => {
  const groups = Array.from({ length: 5 }, (_, index) => ({
    ...base, name: `Group ${index}`, messages: Array.from({ length: 20 }, (_, index) => ({ ...base.messages[0], body: `${index}:` + "x".repeat(490) })),
  }));
  const result = boundedAcrossGroupContext({ groups, next_offset: 5 });
  assert.ok(Buffer.byteLength(JSON.stringify(result), "utf8") <= CROSS_GROUP_CONTEXT_LIMIT);
  assert.equal(result.groups.length, 5);
  assert.equal(result.next_offset, 5);
  assert.equal(result.truncated, true);
  for (let index = 0; index < 5; index++) {
    assert.equal(result.groups[index].name, `Group ${index}`);
    assert.match(result.groups[index].messages.at(-1)!.body, /^19:/);
  }
  assert.equal(boundedAcrossGroupContext({ groups: [{ ...base, messages: [{ ...base.messages[0], body_truncated: true }] }], next_offset: null }).truncated, true);
  const multilingual = boundedAcrossGroupContext({ groups: groups.map(group => ({ ...group, messages: group.messages.map(message => ({ ...message, body: "中文".repeat(240) })) })), next_offset: null });
  assert.ok(Buffer.byteLength(JSON.stringify(multilingual), "utf8") <= CROSS_GROUP_CONTEXT_LIMIT);
  assert.equal(multilingual.truncated, true);
  assert.throws(() => boundedAcrossGroupContext({ groups: [...groups, base], next_offset: null }));
});

test("cross-group reads pass only verified job scope to the atomic service permission check and fail closed", async () => {
  const calls: unknown[] = [];
  const scope = { job: { id, attempts: 3 }, db: { rpc: async (name: string, input: unknown) => {
    calls.push({ name, input });
    return { data: { groups: [base], next_offset: null }, error: null };
  } } } as unknown as Parameters<typeof readAcrossGroups>[1];
  await readAcrossGroups({ offset: 5, query: "Dinner" }, scope);
  assert.deepEqual(calls, [{ name: "pal_read_across_groups", input: { p_job_id: id, p_attempt: 3, p_offset: 5, p_query: "Dinner" } }]);
  await assert.rejects(() => readAcrossGroups({ actor_id: id }, scope));
  assert.equal(calls.length, 1);
  const denied = { ...scope, db: { rpc: async () => ({ data: null, error: { message: "Own live private job required.", code: "42501" } }) } } as unknown as typeof scope;
  await assert.rejects(() => readAcrossGroups({}, denied), { code: "42501" });
});
