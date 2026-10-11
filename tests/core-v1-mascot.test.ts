import assert from "node:assert/strict";
import { test } from "node:test";
import { z } from "zod";
import { agentReply, palEmotions, palEmotion, parsedPalReply } from "../lib/validation";

test("structured replies retain each supported message-specific expression", () => {
  for (const emotion of palEmotions) {
    assert.equal(palEmotion.parse(emotion), emotion);
    assert.deepEqual(parsedPalReply({ reply: "  Actual reply.  ", emotion }), { body: "Actual reply.", emotion });
  }
  assert.deepEqual(parsedPalReply({ reply: "I'm sorry. That sounds rough.", emotion: "triste" }), { body: "I'm sorry. That sounds rough.", emotion: "triste" });
  assert.deepEqual(parsedPalReply({ reply: "Another one for your someday collection.", emotion: "fier" }), { body: "Another one for your someday collection.", emotion: "fier" });
});

test("old, missing or unknown expressions fall back without changing the actual reply", () => {
  assert.deepEqual(parsedPalReply({ reply: "Old reply." }), { body: "Old reply.", emotion: "fier" });
  for (const emotion of ["unknown", null, "<svg onload=bad()>", { activity: "speaking" }]) {
    assert.deepEqual(parsedPalReply({ reply: "Helpful reply.", emotion }), { body: "Helpful reply.", emotion: "fier" });
  }
  assert.deepEqual(parsedPalReply({ reply: "   ", emotion: "triste" }), { body: "", emotion: "triste" }, "An emotion never creates reply text for a silent observation.");
  assert.throws(() => parsedPalReply({ reply: "Reply", html: "<svg/>" }));
  assert.throws(() => parsedPalReply({ reply: 123, emotion: "heureux" }));
});

test("the provider output schema advertises exact supported keys rather than arbitrary UI", () => {
  const schema = z.toJSONSchema(agentReply);
  const emotion = schema.properties!.emotion as { enum: string[] };
  assert.deepEqual(emotion.enum, [...palEmotions]);
  assert.equal(schema.additionalProperties, false);
  const original = parsedPalReply({ reply: "A sympathetic reply.", emotion: "triste" });
  parsedPalReply({ reply: "Next reply!", emotion: "heureux" });
  assert.equal(original.emotion, "triste", "Parsing a later reply cannot mutate a historical message's expression.");
});
