import assert from "node:assert/strict";
import { test } from "node:test";
import { matchesSecret, messageInput, validateReminder } from "../lib/validation";

test("internal dispatcher authentication fails closed", () => {
  assert.equal(matchesSecret(null, "secret"), false);
  assert.equal(matchesSecret("Bearer secret", undefined), false);
  assert.equal(matchesSecret("Bearer wrong", "secret"), false);
  assert.equal(matchesSecret("Bearer secret", "secret"), true);
});
test("messages reject blank, too large, and arbitrary extra fields", () => {
  const client_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  assert.equal(messageInput.parse({ body: " Hello ", client_id }).body, "Hello");
  assert.throws(() => messageInput.parse({ body: " ", client_id }));
  assert.throws(() => messageInput.parse({ body: "x".repeat(4001), client_id }));
  assert.throws(() => messageInput.parse({ body: "Hello", client_id, group_id: "attacker" }));
});
test("reminders require a future timestamp and real IANA time zone", () => {
  const now = Date.parse("2026-10-11T18:00:00Z");
  assert.equal(validateReminder("2026-10-11T11:01:00-07:00", "America/Los_Angeles", now), "2026-10-11T18:01:00.000Z");
  assert.throws(() => validateReminder("2026-10-11T17:00:00Z", "UTC", now));
  assert.throws(() => validateReminder("2026-10-11T18:01:00Z", "Mars", now));
  assert.throws(() => validateReminder("2028-10-11T18:01:00Z", "UTC", now));
});
