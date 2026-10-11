import assert from "node:assert/strict";
import { test } from "node:test";
import { memberSummaryContext, readMemberSummaryContext, sourcedMemberSummary, summarizeMember } from "../lib/member-summary";
import type { SupabaseClient } from "@supabase/supabase-js";

const group = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", alice = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const bob = "cccccccc-cccc-4ccc-8ccc-cccccccccccc", source = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const memory = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const message = { id: source, group_id: group, sender_id: alice, role: "user", body: "Vegetarian dishes for me please." };

test("member context only includes their own group messages and unexpired explicit memories", () => {
  const context = memberSummaryContext(group, alice, [message,
    { ...message, group_id: bob, body: "OTHER GROUP SECRET" },
    { ...message, sender_id: bob, body: "OTHER MEMBER SECRET" },
    { ...message, role: "pal", body: "AI speculation" },
  ], [
    { id: memory, group_id: group, user_id: alice, kind: "preference", key: "food", value: "vegetarian", expires_at: null },
    { id: memory, group_id: group, user_id: alice, kind: "availability", key: "Friday", value: "7pm", expires_at: "2026-01-01T00:00:00Z" },
    { id: memory, group_id: group, user_id: bob, kind: "preference", key: "private", value: "SECRET", expires_at: null },
  ], Date.parse("2026-10-11T00:00:00Z"));
  assert.deepEqual(context, { messages: [{ id: source, body: message.body }], memories: [{ id: memory, user_id: alice, kind: "preference", key: "food", value: "vegetarian", expires_at: null }] });
});

test("member context has strict source count and text bounds", () => {
  const context = memberSummaryContext(group, alice, Array.from({ length: 70 }, () => ({ ...message, body: "x".repeat(6000) })), []);
  assert.equal(context.messages.length, 40);
  assert.equal(context.messages[0].body.length, 600);
});

test("native uppercase UUID paths resolve the same exact member context", () => {
  const memoryRecord = { id: memory, group_id: group, user_id: alice, kind: "preference", key: "food", value: "vegetarian", expires_at: null };
  assert.deepEqual(memberSummaryContext(group.toUpperCase(), alice.toUpperCase(), [message], [memoryRecord]),
    memberSummaryContext(group, alice, [message], [memoryRecord]));
});

test("AI summaries cannot invent source IDs, cite another member or omit evidence", () => {
  const context = memberSummaryContext(group, alice, [message], []);
  assert.throws(() => sourcedMemberSummary({ summary: "Vegetarian", source_ids: [bob] }, context));
  assert.throws(() => sourcedMemberSummary({ summary: "Vegetarian", source_ids: [] }, context));
  assert.deepEqual(sourcedMemberSummary({ summary: "", source_ids: [] }, context), { summary: null, sources: [] });
  assert.deepEqual(sourcedMemberSummary({ summary: "Likes vegetarian options.", source_ids: [source, source] }, context).sources, [{ id: source, body: message.body }]);
});

test("removed targets are denied before reading messages or calling AI", async () => {
  const queries: string[] = [];
  const db = { from(table: string) {
    queries.push(table);
    return { select() { return this; }, eq() { return this; }, async maybeSingle() { return { data: null, error: null }; } };
  } } as unknown as SupabaseClient;
  await assert.rejects(readMemberSummaryContext(db, group, alice), /no longer in the group/);
  assert.deepEqual(queries, ["group_members"]);
});

test("database reads require same group and member filters for every source", async () => {
  const filters: [string, string, unknown][] = [];
  const db = { from(table: string) {
    return {
      select() { return this; }, eq(key: string, value: unknown) { filters.push([table, key, value]); return this; },
      order() { return this; }, limit() { return Promise.resolve({ data: [], error: null }); },
      async maybeSingle() { return { data: { user_id: alice }, error: null }; },
    };
  } } as unknown as SupabaseClient;
  await readMemberSummaryContext(db, group, alice);
  for (const table of ["group_members", "messages", "member_memories"]) assert.ok(filters.some(([t, key, value]) => t === table && key === "group_id" && value === group));
  assert.ok(filters.some(([t, key, value]) => t === "messages" && key === "sender_id" && value === alice));
  assert.ok(filters.some(([t, key, value]) => t === "member_memories" && key === "user_id" && value === alice));
});

test("empty context requires no AI and source-version requests are coalesced", async () => {
  assert.deepEqual(await summarizeMember(group, alice, { messages: [], memories: [] }), { summary: null, sources: [] });
  const previousFetch = globalThis.fetch, previousKey = process.env.OPENAI_API_KEY, previousModel = process.env.OPENAI_MODEL;
  process.env.OPENAI_API_KEY = "test-only"; process.env.OPENAI_MODEL = "test-model";
  let calls = 0;
  globalThis.fetch = async (_url, options) => {
    calls += 1;
    const input = JSON.parse(String(options?.body));
    assert.equal(input.store, false);
    assert.deepEqual(JSON.parse(input.input).messages, [{ id: source, body: message.body }]);
    return Response.json({ output: [{ content: [{ type: "output_text", text: JSON.stringify({ summary: "Vegetarian options, please.", source_ids: [source] }) }] }] });
  };
  try {
    const context = memberSummaryContext(group, alice, [message], []);
    const [a, b] = await Promise.all([summarizeMember(group, alice, context), summarizeMember(group, alice, context)]);
    assert.deepEqual(a, b); assert.equal(calls, 1);
    await summarizeMember(group, alice, context); assert.equal(calls, 1);
  } finally {
    globalThis.fetch = previousFetch;
    if (previousKey === undefined) delete process.env.OPENAI_API_KEY; else process.env.OPENAI_API_KEY = previousKey;
    if (previousModel === undefined) delete process.env.OPENAI_MODEL; else process.env.OPENAI_MODEL = previousModel;
  }
});
