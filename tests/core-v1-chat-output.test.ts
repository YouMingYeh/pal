import assert from "node:assert/strict";
import { test } from "node:test";
import { messageInput, parsedPalOutputs } from "../lib/validation";
import { attachmentForm } from "../lib/attachments";

const alice = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", source = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const plan = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";

test("Pal keeps intentional text boundaries, per-message tone and genuine silence", () => {
  assert.deepEqual(parsedPalOutputs({ reply: "First paragraph.\n\nSecond paragraph.", emotion: "curieux" }), [
    { body: "First paragraph.\n\nSecond paragraph.", emotion: "curieux", reply_to_id: null, mentions: [], card: null },
  ], "Newlines do not manufacture separate messages.");
  assert.deepEqual(parsedPalOutputs({ reply: " ", emotion: "heureux", messages: [] }), []);
  assert.deepEqual(parsedPalOutputs({ reply: "", messages: [
    { body: "  @Alice, which evening?  ", emotion: "curieux", mentions: [{ type: "user", user_id: alice }], reply_to_id: source },
    { body: "No table booked yet.", emotion: "attentif" },
  ] }), [
    { body: "@Alice, which evening?", emotion: "curieux", mentions: [{ type: "user", user_id: alice }], reply_to_id: source, card: null },
    { body: "No table booked yet.", emotion: "attentif", mentions: [], reply_to_id: null, card: null },
  ]);
});

test("Pal drops identical bubbles in one turn without suppressing distinct replies or later turns", () => {
  const input = { reply: "", messages: [
    { body: "  Friday works.  ", reply_to_id: source, emotion: "heureux" },
    { body: "Friday works.", reply_to_id: source, emotion: "fier" },
    { body: "Which restaurant?", reply_to_id: plan, emotion: "curieux" },
  ] };
  const outputs = parsedPalOutputs(input);
  assert.equal(outputs.length, 2);
  assert.equal(outputs[0].emotion, "heureux");
  assert.equal(outputs[0].reply_to_id, source);
  assert.equal(outputs[1].reply_to_id, plan);
  assert.deepEqual(parsedPalOutputs(input), outputs, "Deduplication never crosses turns.");
  assert.equal(parsedPalOutputs({ reply: "", messages: [
    { body: "Yes.", reply_to_id: source }, { body: "Yes.", reply_to_id: plan },
  ] }).length, 2, "Identical words addressing distinct messages remain distinct.");
  assert.equal(parsedPalOutputs({ reply: "", messages: [
    { body: "Dinner?" }, { body: "Dinner?", card: { type: "plan", entity_id: plan } },
  ] }).length, 2, "Do not discard a real card because its caption repeats.");
});

test("Pal cannot inject generic UI, impersonate a sender, self-mention or duplicate responses", () => {
  const output = (message: unknown) => ({ reply: "", messages: [message] });
  assert.throws(() => parsedPalOutputs({ reply: "Duplicate", messages: [{ body: "Duplicate" }] }));
  assert.throws(() => parsedPalOutputs(output({ body: "Hello", sender_id: alice })));
  assert.throws(() => parsedPalOutputs(output({ body: "@Pal", mentions: [{ type: "pal" }] })));
  assert.throws(() => parsedPalOutputs(output({ body: "@Alice", mentions: [{ type: "user", user_id: alice }, { type: "user", user_id: alice.toUpperCase() }] })));
  assert.throws(() => parsedPalOutputs(output({ body: "Plan", card: { type: "html", entity_id: plan } })));
  assert.throws(() => parsedPalOutputs(output({ body: "Hello", reply_to_id: "other-group-or-made-up" })));
  assert.deepEqual(parsedPalOutputs(output({ body: "Who can join?", card: { type: "rsvp", entity_id: plan } }))[0].card, { type: "rsvp", entity_id: plan }, "SQL additionally checks current same-group confirmed plan.");
});

test("Pal output cannot turn one job into unbounded chat spam", () => {
  assert.throws(() => parsedPalOutputs({ reply: "", messages: Array.from({ length: 4 }, () => ({ body: "Hi" })) }));
  assert.throws(() => parsedPalOutputs({ reply: "", messages: [{ body: "x".repeat(2500) }, { body: "y".repeat(1501) }] }));
  assert.throws(() => parsedPalOutputs({ reply: "", messages: [{ body: "  " }] }));
});

test("human tags have explicit actor types and cannot carry identity overrides", () => {
  assert.equal(messageInput.parse({ body: "Can you help?", client_id: source, mentions: [{ type: "pal" }] }).mentions?.[0].type, "pal");
  assert.throws(() => messageInput.parse({ body: "Hello", client_id: source, mentions: [{ type: "user", user_id: alice, role: "admin" }] }));
  assert.throws(() => messageInput.parse({ body: "Hello", client_id: source, mentions: [{ type: "pal" }, { type: "pal" }] }));
});

test("multipart tags are parsed as bounded JSON and reject forged ownership or malformed metadata", async () => {
  const form = new FormData(); form.set("file", new File(["photo"], "camera.jpg", { type: "image/jpeg" }));
  form.set("kind", "image"); form.set("client_id", source); form.set("mentions", JSON.stringify([{ type: "user", user_id: alice }]));
  const request = () => new Request("https://pal.example/api/groups/one/attachments", { method: "POST", body: form });
  assert.deepEqual((await attachmentForm(request())).input.mentions, [{ type: "user", user_id: alice }]);
  form.set("mentions", "broken JSON"); await assert.rejects(attachmentForm(request()));
  form.set("mentions", JSON.stringify([{ type: "user", user_id: alice, uploader_id: source }])); await assert.rejects(attachmentForm(request()));
  form.set("mentions", " ".repeat(2049)); await assert.rejects(attachmentForm(request()));
});
