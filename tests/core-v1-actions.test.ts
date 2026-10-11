import assert from "node:assert/strict";
import { test } from "node:test";
import { actionInput, agentReply, deviceInput, parseAgentAction, profileInput, sharedUrls } from "../lib/validation";
import { actionSourceKey, batchSpeaker, type SourceMessage } from "../lib/job-scope";

const messageId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const otherId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

test("member actions reject identity injection and unsupported side effects", () => {
  assert.throws(() => actionInput.parse({ action: "plan.confirm", data: { id: messageId, user_id: otherId } }));
  assert.throws(() => actionInput.parse({ action: "shell.execute", data: { command: "whoami" } }));
  assert.throws(() => actionInput.parse({ action: "plan.confirm", data: { id: messageId }, requester_id: otherId }));
  assert.equal(actionInput.parse({ action: "plan.rsvp", data: { id: messageId, status: "going" } }).action, "plan.rsvp");
  for (const action of ["plan.confirm", "plan.cancel", "plan.booking", "plan.rsvp", "poll.vote", "group.settings"] as const) {
    assert.throws(() => parseAgentAction(action, { id: messageId }), /requires a group member/);
  }
});

test("facts are scoped to the real speaker in a frozen batch", () => {
  const batch: SourceMessage[] = [{ id: messageId, group_id: otherId, sender_id: "real-speaker", role: "user", body: "I am vegetarian", created_at: "2026-10-11T18:00:00Z" }];
  assert.equal(batchSpeaker(batch, messageId).sender_id, "real-speaker");
  assert.throws(() => batchSpeaker(batch, otherId), /verified batch/);
  assert.throws(() => actionInput.parse({ action: "memory.save", data: { kind: "availability", key: "friday", value: "free" } }));
  assert.throws(() => actionInput.parse({ action: "memory.save", data: { kind: "preference", key: "diet", value: "vegetarian", user_id: otherId } }));
});

test("polls and plans reject contradictory structured data", () => {
  assert.equal(actionInput.parse({ action: "poll.vote", data: { id: messageId, option_ids: [] } }).action, "poll.vote", "An explicit empty time response is distinct from never responding; SQL checks poll kind.");
  assert.throws(() => actionInput.parse({ action: "poll.vote", data: { id: messageId, option_ids: [], user_id: otherId } }));
  assert.throws(() => actionInput.parse({ action: "poll.create", data: {
    kind: "time", question: "When?", deadline_at: "2026-10-15T18:00:00Z", options: [{ id: "same", label: "Fri" }, { id: "same", label: "Sat" }],
  } }));
  assert.throws(() => actionInput.parse({ action: "plan.create", data: {
    title: "Dinner", starts_at: "2026-10-15T18:00:00Z", ends_at: "2026-10-15T17:00:00Z",
  } }));
  assert.throws(() => actionInput.parse({ action: "place.save", data: {
    name: "Invented place", address: "Nowhere", latitude: 999, longitude: 0, provider: "apple", provider_id: "id",
  } }));
});

test("device and profile writes have narrow authenticated payloads", () => {
  const token = "ab".repeat(32);
  assert.equal(deviceInput.parse({ token, environment: "sandbox" }).token, token);
  assert.throws(() => deviceInput.parse({ token: "a".repeat(65), environment: "sandbox" }));
  assert.throws(() => deviceInput.parse({ token, environment: "development" }));
  assert.throws(() => deviceInput.parse({ token, environment: "sandbox", user_id: otherId }));
  assert.throws(() => profileInput.parse({ display_name: "Friend", user_id: otherId }));
  assert.throws(() => profileInput.parse({ avatar_url: "javascript:alert(1)" }));
  assert.throws(() => profileInput.parse({ notifications_enabled: true, notification_preferences: { enabled: false } }));
});

test("URL ingestion is bounded and selective agent results support genuine silence", () => {
  assert.deepEqual(sharedUrls("Try https://example.com/post. Also https://example.com/post"), ["https://example.com/post"]);
  assert.deepEqual(sharedUrls("Do not use https://secret:password@example.com/x or javascript:alert(1)"), []);
  assert.equal(sharedUrls(Array.from({ length: 20 }, (_, index) => `https://example.com/${index}`).join(" ")).length, 10);
  assert.equal(agentReply.parse({ reply: "" }).reply, "");
  assert.throws(() => agentReply.parse({ reply: "Hello", arbitrary_html: "<script/>" }));
});

test("reminder retry identity is scoped to its job and source, rather than shared reminder contents", () => {
  const original = actionSourceKey(messageId, "reminder.create", otherId);
  assert.equal(actionSourceKey(messageId, "reminder.create", otherId), original);
  assert.notEqual(actionSourceKey(otherId, "reminder.create", otherId), original, "Two requests with identical bodies remain separate tasks.");
  assert.notEqual(actionSourceKey(messageId, "reminder.create", messageId), original, "Two speakers' source messages cannot share a retry identity.");
});
