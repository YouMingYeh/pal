import assert from "node:assert/strict";
import { test } from "node:test";
import { prepareQuestionCard, questionInput } from "../lib/question-card";
import { messageInput, parsedPalOutputs } from "../lib/validation";

const group = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", delivered = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

test("short group questions preserve suggested answers in the delivered card without creating votes", () => {
  const card = prepareQuestionCard({ question: "  Dinner or coffee?  ", suggestions: [" Dinner ", "Coffee", "Another idea"] }, group);
  assert.deepEqual(card, { type: "question", entity_id: group, question: "Dinner or coffee?", suggestions: ["Dinner", "Coffee", "Another idea"] });
  const outputs = parsedPalOutputs({ reply: "", messages: [{ body: card.question, emotion: "curieux", card }] });
  assert.deepEqual(outputs[0].card, card);
  assert.deepEqual(outputs[0].mentions, []);
  assert.equal(outputs[0].reply_to_id, null);
  for (const answer of ["Coffee", "Actually, a picnic after seven would be better."]) {
    const message = messageInput.parse({ body: answer, client_id: group, reply_to_id: delivered });
    assert.equal(message.body, answer, "Suggested and free-text answers use the same human message operation.");
    assert.equal(message.reply_to_id, delivered, "The quote targets the delivered question message, not its scope identity.");
  }
});

test("question suggestions are bounded and unique, and inline cards cannot inject unknown fields", () => {
  const input = { question: "What time?", suggestions: ["Seven", "Eight"] };
  for (const raw of [
    { ...input, question: " " }, { ...input, question: "x".repeat(201) },
    { ...input, suggestions: ["Seven"] }, { ...input, suggestions: ["One", "Two", "Three", "Four", "Five"] },
    { ...input, suggestions: ["Seven", " seven "] }, { ...input, suggestions: ["Seven", " "] },
    { ...input, suggestions: ["Seven", "x".repeat(61)] }, { ...input, suggestions: ["Seven", { body: "Eight" }] },
    { ...input, user_id: group }, { ...input, html: "<button>vote</button>" },
  ]) assert.throws(() => questionInput.parse(raw));
  assert.throws(() => prepareQuestionCard(input, "not-a-group"));
  const card = prepareQuestionCard(input, group);
  assert.throws(() => parsedPalOutputs({ reply: "", messages: [{ body: "What time?", card: { ...card, action: "plan.rsvp" } }] }));
  assert.throws(() => parsedPalOutputs({ reply: "", messages: [{ body: "Plan?", card: { type: "plan", entity_id: group, suggestions: input.suggestions } }] }));
});
