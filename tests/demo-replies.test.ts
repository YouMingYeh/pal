import assert from "node:assert/strict";
import { test } from "node:test";
import type { admin } from "../lib/db";
import { demoLines, promptsForDemo } from "../lib/demo";
import { chatDemoReplies, mockDemoReply, registeredDemoScene } from "../lib/demo-replies";
import type { Job, SourceMessage } from "../lib/job-scope";

const group = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", operatorId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const operatorMessage = "cccccccc-cccc-4ccc-8ccc-cccccccccccc", planId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const actors = ["eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1", "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2", "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee3"];
const now = Date.parse("2026-10-12T21:05:00Z"), start = "2026-10-17T02:30:00Z", editedStart = "2026-10-17T03:00:00Z";

function fixture(step: number, kind: "chat" | "plan" = "plan") {
  const job: Job = { id: group, group_id: group, requester_id: operatorId, message_id: operatorMessage, status: "running", attempts: 1, result: null, lease_until: "2026-10-12T21:10:00Z", job_kind: "chat" };
  const message = (sender: string, body: string, index: number): SourceMessage => ({ id: index ? `ffffffff-ffff-4fff-8fff-${String(index).padStart(12, "0")}` : operatorMessage,
    group_id: group, sender_id: sender, role: "user", body, created_at: `2026-10-12T21:00:0${index}Z` });
  const batch = [message(operatorId, promptsForDemo(kind)[step], 0), ...demoLines(step, actors, kind).map((line, index) => message(line.user_id, line.body, index + 1))];
  const plan = { id: planId, group_id: group, place_id: group, title: "Delfina dinner", status: step >= 5 ? "confirmed" : "draft",
    starts_at: step >= 3 ? editedStart : start, created_at: "2026-10-12T20:00:00Z", updated_at: "2026-10-12T20:30:00Z", version: step >= 5 ? 3 : 2 };
  const state = { settings: { is_demo: true, is_direct: false, timezone: "America/Los_Angeles" },
    demo: { kind, generation: group, run_id: group, step: step + 1, operator_message_id: operatorMessage, operator_user_id: operatorId, actor_ids: actors, starts_at: start },
    places: [{ id: group, group_id: group, name: "Delfina", status: "resolved", website: "https://www.delfinasf.com/", booking_url: "https://www.delfinasf.com/reservations" }],
    plans: step >= 3 ? [plan] : [], polls: [],
  };
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  let checkpoint: string | undefined;
  const db = {
    rpc: async (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      if (name === "pal_agent_action") {
        const data = args.p_data as Record<string, unknown>;
        assert.equal(args.p_group_id, group); assert.equal(data.job_id, job.id);
        if (args.p_action === "memory.save") return { data: { id: group }, error: null };
        assert.equal(args.p_action, "plan.create");
        return { data: { ...plan, ...data, status: "draft" }, error: null };
      }
      assert.equal(name, "pal_capture_member_response");
      assert.equal(args.p_job_id, job.id); assert.equal(args.p_job_attempt, job.attempts); assert.equal(args.p_target_id, planId);
      const source = batch.find(source => source.id === args.p_source_message_id);
      assert.ok(source); assert.equal(args.p_evidence, source.body);
      if (args.p_target_kind === "confirmation" && plan.status === "draft") { plan.status = "confirmed"; plan.version++; }
      return { data: { ...plan, captured: true, user_id: source.sender_id }, error: null };
    },
    from(table: string) {
      assert.equal(table, "agent_jobs");
      const builder = {
        update(data: { result: string }) { checkpoint = data.result; return builder; },
        eq(column: string, value: unknown) { assert.equal(value, column === "id" ? job.id : column === "attempts" ? job.attempts : column === "status" ? "running" : job.lease_until); return builder; },
        select() { return builder; }, async maybeSingle() { return { data: { id: job.id }, error: null }; },
      };
      return builder;
    },
  } as unknown as ReturnType<typeof admin>;
  return { scope: { job, db, batch }, state, calls, plan, checkpoint: () => checkpoint };
}

test("mock responses are restricted to registered current runs and exact operator sources", async () => {
  const { scope, state, calls } = fixture(0, "chat");
  for (const changed of [
    { ...state, settings: { ...state.settings, is_demo: false } },
    { ...state, settings: { ...state.settings, is_direct: true } },
    { ...state, demo: null }, { ...state, demo: { ...state.demo, kind: "arbitrary" } },
    { ...state, demo: { ...state.demo, operator_message_id: planId } },
    { ...state, demo: { ...state.demo, operator_user_id: actors[0] } },
  ]) assert.equal(await mockDemoReply(scope, changed, now), null);
  assert.equal(registeredDemoScene({ ...scope, batch: [{ ...scope.batch[0], body: "An actual custom request" }, ...scope.batch.slice(1)] }, state), null);
  assert.equal(registeredDemoScene({ ...scope, batch: [{ ...scope.batch[0], group_id: planId }, ...scope.batch.slice(1)] }, state), null);
  assert.throws(() => registeredDemoScene({ ...scope, batch: [scope.batch[0]] }, state), /cast to finish/);
  assert.equal(calls.length, 0);
});

test("all six everyday scenes produce one specific short friend reply, including a gentle tired-day response", async () => {
  for (let step = 0; step < 6; step++) {
    const { scope, state, calls } = fixture(step, "chat"); state.places = [];
    const result = await mockDemoReply(scope, state, now);
    assert.ok(result); assert.equal(result.outputs.length, 1); assert.equal(result.outputs[0].body, chatDemoReplies[step].body);
    assert.ok(result.outputs[0].body.length < 180); assert.equal(result.outputs[0].reply_to_id, step === 2 ? scope.batch[1].id : null);
    assert.equal(result.outputs[0].card, null); assert.equal(calls.length, 0);
    assert.equal(result.result.mockDemo, true); assert.equal(result.result.kind, "chat");
    assert.doesNotMatch(result.outputs[0].body, /let me know|would you like|can i help|I can find/i);
  }
  assert.equal(chatDemoReplies[3].emotion, "attentif"); assert.match(chatDemoReplies[3].body, /No itinerary, no guilt/);
});

test("planning memory is saved for its six actual speaker facts, while options remain honest and short", async t => {
  t.mock.method(Date, "now", () => now);
  const first = fixture(0), result = await mockDemoReply(first.scope, first.state, now);
  assert.ok(result); assert.equal(result.outputs.length, 1); assert.equal(first.calls.length, 6);
  assert.deepEqual(first.calls.map(call => call.args.p_requester_id), [actors[0], actors[0], actors[1], actors[1], actors[2], actors[2]]);
  for (const call of first.calls) {
    const data = call.args.p_data as Record<string, unknown>;
    assert.equal(call.args.p_action, "memory.save"); assert.ok(first.scope.batch.some(source => source.id === data.source_message_id && source.sender_id === call.args.p_requester_id));
  }
  const second = fixture(1), options = await mockDemoReply(second.scope, second.state, now);
  assert.ok(options); assert.match(options.outputs[0].body, /Menu and prices still need checking/); assert.equal(second.calls.length, 0);
});

test("draft and edit replies use actual saved plan identity and cannot invent an eight o'clock edit", async () => {
  const draft = fixture(2), created = await mockDemoReply(draft.scope, draft.state, now);
  assert.ok(created); assert.equal(created.outputs[0].card?.entity_id, planId); assert.match(created.outputs[0].body, /7:30.*Draft saved/);
  const moved = fixture(3), edited = await mockDemoReply(moved.scope, moved.state, now);
  assert.ok(edited); assert.equal(edited.outputs[0].card?.entity_id, planId); assert.equal(moved.calls.length, 0);
  moved.plan.starts_at = start;
  await assert.rejects(mockDemoReply(moved.scope, moved.state, now), /dinner at eight/);
});

test("real confirmation posts no duplicate invitation and interrupted completion replays its guarded receipt", async () => {
  const fixture4 = fixture(4), result = await mockDemoReply(fixture4.scope, fixture4.state, now);
  assert.ok(result); assert.deepEqual(result.outputs, []); assert.equal(fixture4.plan.status, "confirmed");
  assert.equal(fixture4.calls[0].args.p_target_kind, "confirmation");
  assert.ok(fixture4.checkpoint()); fixture4.scope.job.result = fixture4.checkpoint()!; fixture4.scope.job.attempts = 2;
  const retried = await mockDemoReply(fixture4.scope, fixture4.state, now);
  assert.ok(retried); assert.deepEqual(retried.outputs, []); assert.equal(fixture4.plan.version, 3);
  assert.deepEqual(fixture4.calls[1].args.p_response, fixture4.calls[0].args.p_response, "Retry uses the original source and draft version, never reconfirms a changed plan.");
});

test("final invitation captures every actual own RSVP chronologically without adding a booking flow", async () => {
  const last = fixture(5), result = await mockDemoReply(last.scope, last.state, now);
  assert.ok(result); assert.equal(result.outputs.length, 1); assert.equal(result.outputs[0].card?.entity_id, planId);
  assert.deepEqual(last.calls.map(call => call.args.p_source_message_id), last.scope.batch.map(source => source.id));
  assert.ok(last.calls.every(call => call.args.p_target_kind === "plan" && (call.args.p_response as { status: string }).status === "going"));
  assert.doesNotMatch(result.outputs.map(reply => reply.body).join(" "), /https?:|book|reservation|calendar synced/i);
  last.plan.status = "draft";
  await assert.rejects(mockDemoReply(last.scope, last.state, now), /current, future confirmed/);
});
