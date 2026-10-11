import assert from "node:assert/strict";
import { test } from "node:test";
import { prepareMemberResponse, type ResponseState } from "../lib/member-response";
import { type SourceMessage } from "../lib/job-scope";

const groupId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const pollId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const planId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const messageId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const otherId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const now = Date.parse("2026-10-12T20:00:00Z");
const state: ResponseState = {
  settings: { timezone: "America/Los_Angeles" }, plans: [],
  polls: [{ id: pollId, group_id: groupId, kind: "time", status: "open", deadline_at: "2026-10-15T20:00:00Z", created_at: "2026-10-12T18:00:00Z", question: "When should we get dinner?", options: [
    { id: "seven", label: "Friday 7 PM", starts_at: "2026-10-17T02:00:00Z" },
    { id: "eight", label: "Friday 8 PM", starts_at: "2026-10-17T03:00:00Z" },
  ] }],
};
const planState: ResponseState = { ...state, polls: [], plans: [{ id: planId, group_id: groupId, title: "Dinner", status: "confirmed", version: 4, starts_at: "2026-10-17T03:00:00Z", created_at: "2026-10-12T17:00:00Z", updated_at: "2026-10-12T18:00:00Z" }] };
function source(body: string): SourceMessage { return { id: messageId, group_id: groupId, sender_id: "actual-speaker", role: "user", body, created_at: "2026-10-12T19:00:00Z" }; }
function vote(body: string, response: "options" | "either" | "none" = "options", option_ids = ["eight"], groupState = state) {
  return prepareMemberResponse({ target_kind: "poll", target_id: pollId, source_message_id: messageId, evidence: body, response, option_ids }, [source(body)], groupState, groupId, now);
}
function rsvp(body: string, status: "going" | "maybe" | "declined" = "going", groupState = planState) {
  return prepareMemberResponse({ target_kind: "plan", target_id: planId, source_message_id: messageId, evidence: body, status }, [source(body)], groupState, groupId, now);
}

test("explicit dated availability captures only matching actual time slots for its real speaker", () => {
  const result = vote("Friday after seven works");
  assert.equal(result.source.sender_id, "actual-speaker");
  assert.deepEqual(result.response, { kind: "options", option_ids: ["eight"] });
  assert.deepEqual(vote("I can do Friday", "options", ["seven", "eight"]).response, { kind: "options", option_ids: ["seven", "eight"] });
  assert.deepEqual(vote("Friday at 8 pm works").response, { kind: "options", option_ids: ["eight"] });
  assert.throws(() => vote("Friday after seven works", "options", ["seven"]), /ambiguous/);
  assert.throws(() => vote("Next Friday at eight works"), /ambiguous/);
  assert.throws(() => vote("Friday after seven might work"), /ambiguous/);
  assert.throws(() => vote("Friday after seven and before eight works"), /ambiguous/);
  assert.throws(() => vote("Friday 8 PM works after ten"), /ambiguous/);
  assert.throws(() => vote("Friday after seven works for Ben"), /ambiguous/);
  assert.throws(() => vote("Ben prefers Friday at 8 pm"), /ambiguous/);
});

test("either and none remain poll choices rather than attendance", () => {
  assert.deepEqual(vote("Anything works", "either", []).response, { kind: "either", option_ids: [] });
  assert.deepEqual(vote("None of these work for me", "none", []).response, { kind: "none", option_ids: [] });
  assert.throws(() => rsvp("Anything works"), /ambiguous/);
  assert.throws(() => vote("Either works", "either", ["eight"]), /ambiguous/);
  const places: ResponseState = { ...state, polls: [{ ...state.polls[0], kind: "place", options: [{ id: "korean", label: "Korean Garden" }, { id: "italian", label: "Pasta House" }] }] };
  assert.deepEqual(vote("I prefer Korean Garden", "options", ["korean"], places).response, { kind: "options", option_ids: ["korean"] });
  assert.throws(() => vote("I prefer Korean Garden, Ben prefers Pasta House", "options", ["korean", "italian"], places), /ambiguous/);
  assert.throws(() => vote("None work for me", "none", [], places), /ambiguous/);
});

test("clear own attendance is distinct from Maybe, No and banter", () => {
  assert.deepEqual(rsvp("I'm in!").response, { status: "going", plan_version: 4 });
  assert.deepEqual(rsvp("I might come", "maybe").response, { status: "maybe", plan_version: 4 });
  assert.deepEqual(rsvp("I can't make it", "declined").response, { status: "declined", plan_version: 4 });
  assert.deepEqual(rsvp("我會去").response, { status: "going", plan_version: 4 });
  for (const body of ["I'm in trouble", "I'm in if Ben comes", "I'm in, kidding", "Ben said I'm in", 'Ben said "I\'m in"', "Amy will go", "Yes?", "I might come"]) {
    assert.throws(() => rsvp(body), /ambiguous/, body);
  }
  assert.throws(() => rsvp("Maybe", "going"), /ambiguous/);
});

test("source evidence and narrow schemas prevent other-speaker and old-message injection", () => {
  const input = { target_kind: "plan", target_id: planId, source_message_id: messageId, evidence: "I'm in", status: "going" };
  assert.throws(() => prepareMemberResponse({ ...input, user_id: "someone-else" }, [source("I'm in")], planState, groupId, now));
  assert.throws(() => prepareMemberResponse({ ...input, source_message_id: otherId }, [source("I'm in")], planState, groupId, now), /verified batch/);
  assert.throws(() => prepareMemberResponse(input, [source("Ben said I'm in")], planState, groupId, now), /entire verified/);
  assert.throws(() => prepareMemberResponse(input, [{ ...source("I'm in"), group_id: otherId }], planState, groupId, now), /entire verified/);
  assert.throws(() => prepareMemberResponse(input, [{ ...source("I'm in"), role: "pal" } as unknown as SourceMessage], planState, groupId, now), /verified batch/);
  assert.throws(() => rsvp("I'm in", "going", { ...planState, plans: [{ ...planState.plans[0], updated_at: "2026-10-12T19:30:00Z" }] }), /latest change/);
  assert.throws(() => vote("Friday after seven works", "options", ["eight"], { ...state, polls: [{ ...state.polls[0], deadline_at: "2026-10-12T19:30:00Z" }] }), /open group poll/);
});

test("multiple possible targets require a focused clarification", () => {
  const multiple = { ...state, polls: [...state.polls, { ...state.polls[0], id: otherId }] };
  assert.throws(() => vote("Anything works", "either", [], multiple), /ambiguous/);
  assert.throws(() => vote("Friday after seven works", "options", ["eight"], multiple), /ambiguous/);
  assert.throws(() => rsvp("I'm in", "going", { ...planState, plans: [...planState.plans, { ...planState.plans[0], id: otherId, title: "Movie" }] }), /ambiguous/);
  assert.deepEqual(rsvp("I'm in for Dinner", "going", { ...planState, plans: [...planState.plans, { ...planState.plans[0], id: otherId, title: "Movie" }] }).response, { status: "going", plan_version: 4 });
  assert.throws(() => rsvp("Yes", "going", { ...planState, polls: state.polls }), /ambiguous/);
});
