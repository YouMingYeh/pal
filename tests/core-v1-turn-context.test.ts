import assert from "node:assert/strict";
import { test } from "node:test";
import { initialTurnInput, INITIAL_TURN_LIMIT } from "../lib/turn-context";
import type { SourceMessage } from "../lib/job-scope";

const group = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", member = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const messageID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc", other = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const stamp = "2026-10-11T22:00:00Z";
const source: SourceMessage = { id: messageID, group_id: group, sender_id: member, role: "user", body: "Friday after 7 works.", created_at: stamp };
const state = {
  settings: { name: "Friday dinner", timezone: "America/Los_Angeles", is_direct: false, avatar_path: "private/group.jpg" },
  members: [{ user_id: member, display_name: "Maya", avatar_url: "https://private-photo.example", avatar_path: "private/person.jpg" }],
  sources: [{ id: messageID, group_id: group, url: "https://real-source.example/venue", status: "resolved", source_message_id: messageID,
    extraction: { transcript: "raw provider content" }, metadata: { secret: "provider trace" }, provider_job_id: "internal provider ID" }],
  places: [{ id: messageID, group_id: group, name: "Verified venue", address: "Actual address", status: "resolved", latitude: 37.7, longitude: -122.4 }],
  plans: [{ id: messageID, group_id: group, title: "Dinner", status: "draft", starts_at: stamp, version: 2, attendees: [{ user_id: member, status: "maybe", device_token: "private token" }] }],
  polls: [{ id: messageID, group_id: group, kind: "time", options: [{ id: "eight", label: "Friday 8 PM", starts_at: stamp }], responses: [{ user_id: member, option_ids: [], secret: "internal" }] }],
  memories: [{ id: messageID, group_id: group, user_id: member, kind: "preference", key: "diet", value: "vegetarian", source_message_id: messageID, expires_at: null }],
};

test("initial verified context preserves grounded identities, status and source while excluding private payloads", () => {
  const result = initialTurnInput({ group_id: group }, [source], state, [{ ...source, reply_to_id: messageID, mentions: [{ type: "user", user_id: member }], card: { type: "plan", entity_id: messageID } }], stamp);
  const text = JSON.stringify(result);
  for (const privateValue of ["private/", "private-photo", "provider trace", "raw provider content", "internal provider ID", "private token", "avatar_path", "metadata", "extraction"]) assert.ok(!text.includes(privateValue), privateValue);
  assert.equal(result.messages[0].sender_id, member);
  assert.equal(result.context.recent_messages[0].created_at, stamp);
  assert.deepEqual(result.context.recent_messages[0].mentions, [{ type: "user", user_id: member }]);
  assert.deepEqual((result.context.state.plans as Record<string, unknown>[])[0].attendees, [{ user_id: member, status: "maybe" }]);
  assert.deepEqual((result.context.state.polls as Record<string, unknown>[])[0].responses, [{ user_id: member, option_ids: [] }]);
  assert.equal(result.context.truncated, false);
});

test("context cannot introduce cross-group sources, internal weekly messages or expired facts", () => {
  const result = initialTurnInput({ group_id: group }, [source], {
    ...state, places: [...state.places, { ...state.places[0], group_id: other, name: "Other group's venue" }],
    memories: [...state.memories, { ...state.memories[0], expires_at: "2026-10-10T00:00:00Z", value: "expired availability" }],
  }, [{ ...source, group_id: other, body: "Other group's message" }, { ...source, role: "system", source_key: "weekly:group:date", body: "Internal scheduler prompt" },
    { ...source, role: "system", source_key: "pal:weekly:group:date", body: "Internal weekly prompt" }, source], stamp);
  const text = JSON.stringify(result);
  for (const value of ["Other group's", "Internal scheduler", "Internal weekly", "expired availability"]) assert.ok(!text.includes(value));
  assert.equal(result.context.recent_messages.length, 1);
  assert.equal(result.context.truncated, true);
  assert.throws(() => initialTurnInput({ group_id: group }, [{ ...source, group_id: other }], state, [], stamp), /verified human batch/);
  assert.throws(() => initialTurnInput({ group_id: group }, [{ ...source, role: "pal" } as unknown as SourceMessage], state, [], stamp), /verified human batch/);
});

test("large multilingual turns stay bounded and admit omitted context while preserving newest source evidence", () => {
  const body = "今天".repeat(1900);
  const batch = Array.from({ length: 15 }, (_, index) => ({ ...source, body: `${index}:` + body }));
  const recent = Array.from({ length: 21 }, (_, index) => ({ ...source, body: `${index}:` + body }));
  const result = initialTurnInput({ group_id: group }, batch, {
    ...state, memories: Array.from({ length: 30 }, (_, index) => ({ ...state.memories[0], value: `${index}:` + body })),
  }, recent, stamp);
  assert.ok(Buffer.byteLength(JSON.stringify(result), "utf8") <= INITIAL_TURN_LIMIT);
  assert.equal(result.messages.at(-1)?.body, batch.at(-1)?.body, "Newest human evidence is not shortened to make the context fit.");
  assert.equal(result.context.truncated, true);
  assert.ok(result.context.omitted.batch_messages > 0);
  assert.ok(result.context.omitted.recent_messages > 0);
  assert.ok(result.context.omitted.memories > 0);
  const normal = initialTurnInput({ group_id: group }, [source], state, recent.map(item => ({ ...item, body: "x".repeat(700) })), stamp);
  assert.equal(normal.context.recent_messages.length, 20);
  assert.deepEqual(normal.context.recent_messages.at(-1)?.truncated_fields, ["body"]);
  assert.equal(normal.context.omitted.recent_messages, 1);
});

test("planning receives only fresh consenting current shared-group locations; DM and unknown members have none", () => {
  const location = { user_id: member, latitude: 37.78, longitude: -122.41, accuracy: 10, updated_at: stamp,
    expires_at: "2026-10-11T23:00:00Z", avatar_path: "private/member-location.jpg" };
  const raw = { ...state, locations: [location, { ...location, user_id: other }, { ...location, group_id: other },
    { ...location, expires_at: stamp }, { ...location, latitude: NaN }, { ...location, longitude: 181 }, { ...location, accuracy: 10001 }] };
  const result = initialTurnInput({ group_id: group }, [source], raw, [], stamp);
  assert.deepEqual(result.context.state.locations, [{ user_id: member, latitude: 37.78, longitude: -122.41,
    accuracy: 10, updated_at: stamp, expires_at: "2026-10-11T23:00:00Z" }]);
  assert.ok(!JSON.stringify(result).includes("private/member-location"));
  for (const settings of [{ ...state.settings, is_direct: true }, { timezone: "UTC" }]) {
    assert.deepEqual(initialTurnInput({ group_id: group }, [source], { ...raw, settings }, [], stamp).context.state.locations, []);
  }
  assert.deepEqual(initialTurnInput({ group_id: group }, [source], state, [], stamp).context.state.locations, [], "Missing location is unknown, not an inferred coordinate.");
});


test("suggested replies retain the actual scoped question and answers in initial conversation context", () => {
  const card = { type: "question", entity_id: group, question: "Dinner budget?", suggestions: ["Under $30", "$30–50", "Flexible"] };
  const result = initialTurnInput({ group_id: group }, [{ ...source, body: "Under $30", reply_to_id: other }], state,
    [{ ...source, id: other, role: "pal", body: "Let's narrow it down.", card }], stamp);
  assert.deepEqual(result.context.recent_messages[0].card, card);
  const rejected = initialTurnInput({ group_id: group }, [source], state, [{ ...source, card: { ...card, entity_id: other } }], stamp);
  assert.ok(!JSON.stringify(rejected).includes("Dinner budget?"));
});
