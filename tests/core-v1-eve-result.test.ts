import assert from "node:assert/strict";
import test from "node:test";
import type { MessageStreamEvent } from "eve/client";
import { EveInputPausedError, EveResult, recoverEveResult } from "../lib/eve-result";

const event = (type: string, data: unknown = {}) => ({ type, data, meta: { id: "event", at: "2026-10-11T23:00:00Z" } }) as MessageStreamEvent;
const waiting = event("session.waiting");
const budget = event("input.requested", { requests: [{ requestId: "limit", kind: "session-limit" }] });

test("actual session-limit event pattern is classified as an unsupported pause, never silence", () => {
  const state = new EveResult();
  for (const entry of [budget, event("turn.completed"), waiting]) state.observe(entry);
  assert.throws(() => state.settled(), error => error instanceof EveInputPausedError && /bounded session budget/.test(error.message));
});

test("durable recovery reads past already-resolved pauses without invoking tools again", async () => {
  const expected = { reply: "Saved your dinner draft.", emotion: "curious" };
  const events = [budget, event("turn.completed"), waiting,
    event("input.resolved", { resolutions: [{ requestId: "limit" }] }), event("turn.started"),
    event("result.completed", { result: expected }), waiting];
  const result = await recoverEveResult({
    snapshot: async () => ({ events, session: { sessionId: "existing", streamIndex: events.length } }),
    stream: async function* () { throw new Error("Settled session must not be followed or rerun."); },
  });
  assert.deepEqual(result.structured, expected);
});

test("task waits and turn completion do not hide the later structured result", async () => {
  const prefix = [event("turn.started"), event("turn.waiting", { on: "tasks" })];
  const result = await recoverEveResult({
    snapshot: async () => ({ events: prefix, session: { sessionId: "active", streamIndex: 2 } }),
    stream: async function* (options) {
      assert.equal(options?.startIndex, 2);
      assert.ok(options?.signal);
      yield event("message.completed", { message: "Tool commentary", finishReason: "tool-calls" });
      yield event("turn.completed");
      yield event("result.completed", { result: { reply: "", emotion: "fier" } });
      yield waiting;
      throw new Error("Read must stop at the real session boundary.");
    },
  });
  assert.equal(result.body, undefined);
  assert.deepEqual(result.structured, { reply: "", emotion: "fier" });
});

test("missing results remain missing and interactive or failed sessions cannot masquerade as success", () => {
  const missing = new EveResult(); missing.observe(waiting);
  assert.equal(missing.settled().structured, undefined);
  const interactive = new EveResult();
  interactive.observe(event("input.requested", { requests: [{ requestId: "approval", kind: "tool-approval" }] }));
  interactive.observe(event("turn.waiting", { on: "input" }));
  assert.throws(() => interactive.settled(), EveInputPausedError);
  const failed = new EveResult(); failed.observe(event("session.failed"));
  assert.throws(() => failed.settled(), /durable task failed/);
  const unfinished = new EveResult(); unfinished.observe(event("turn.waiting", { on: "tasks" }));
  assert.throws(() => unfinished.settled(), /has not finished/);
});
