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

test("plain-text confirmation requires explicit current speaker intent for a future current draft", () => {
  const draftState = { ...planState, plans: [{ ...planState.plans[0], status: "draft" }] };
  function confirm(body: string, state = draftState) {
    return prepareMemberResponse({ target_kind: "confirmation", target_id: planId, source_message_id: messageId, evidence: body },
      [source(body)], state, groupId, now);
  }
  for (const body of ["Confirm Dinner", "I confirm the plan", "Let's confirm Dinner.", "確認這個計畫"]) {
    assert.deepEqual(confirm(body).response, { plan_version: 4 });
    assert.equal(confirm(body).source.sender_id, "actual-speaker");
  }
  for (const body of ["Yes", "Sounds good", "Anything works", "Dinner confirmed?", "Booked", "Confirm Dinner if Ben goes", "Ben said confirm Dinner", '"Confirm Dinner"', "Confirm Dinner, joking"]) {
    assert.throws(() => confirm(body), /ambiguous/, body);
  }
  assert.throws(() => confirm("Confirm Dinner", planState), /current, future draft/);
  assert.throws(() => confirm("Confirm Dinner", { ...draftState, plans: [{ ...draftState.plans[0], updated_at: "2026-10-12T19:30:00Z" }] }), /current, future draft/);
  const multiple = { ...draftState, plans: [...draftState.plans, { ...draftState.plans[0], id: otherId, title: "Movie" }] };
  assert.throws(() => confirm("Confirm the plan", multiple), /ambiguous/);
  assert.deepEqual(confirm("Confirm Dinner", multiple).response, { plan_version: 4 });
  assert.throws(() => prepareMemberResponse({ target_kind: "confirmation", target_id: planId, source_message_id: messageId, evidence: "Confirm Dinner", user_id: otherId }, [source("Confirm Dinner")], draftState, groupId, now));
});

const delfinaState: ResponseState = { ...planState,
  places: [{ id: otherId, group_id: groupId, name: "Delfina" }],
  plans: [{ ...planState.plans[0], title: "Friday dinner", place_id: otherId }],
};
function confirmNamed(body: string, groupState: ResponseState) {
  return prepareMemberResponse({ target_kind: "confirmation", target_id: planId, source_message_id: messageId, evidence: body },
    [source(body)], groupState, groupId, now);
}

test("natural confirmation matches one real venue and actual local date/time without claiming a booking", () => {
  const draft = { ...delfinaState, plans: [{ ...delfinaState.plans[0], status: "draft" }] };
  const body = "Confirm our Delfina dinner for Friday at 8 PM. Ask everyone to RSVP. The restaurant is not booked yet.";
  const result = confirmNamed(body, draft);
  assert.deepEqual(result.response, { plan_version: 4 });
  assert.equal(result.source.body, body, "The entire authenticated source stays intact for the final SQL freshness/version guard.");
  for (const wrong of [
    "Confirm our Delfina dinner for Saturday at 8 PM.", "Confirm our Delfina dinner for Friday at 7:30 PM.",
    "Confirm our Delfina dinner for next Friday at 8 PM.", "Confirm our Delfina dinner at 8 AM.",
    "Confirm our Other Restaurant dinner for Friday at 8 PM.", "Confirm our Delfina lunch for Friday at 8 PM.",
    "Confirm our Delfina dinner for Friday at 8 PM or at 9 PM.",
  ]) assert.throws(() => confirmNamed(wrong, draft), /ambiguous/, wrong);
  assert.throws(() => confirmNamed(body, { ...draft, places: [{ id: otherId, group_id: otherId, name: "Delfina" }] }), /ambiguous/);
  assert.throws(() => confirmNamed("Confirm Friday dinner", { ...draft, plans: [{ ...draft.plans[0], starts_at: "2026-10-18T03:00:00Z" }] }), /ambiguous/, "Even an exact saved title must not override a contradicting actual weekday.");
});

test("natural RSVP captures only the speaker's explicit attendance for the uniquely identified real plan", () => {
  for (const body of [
    "I'm going to our confirmed Delfina dinner. Show the final invitation and the real reservation link. Nothing is booked yet.",
    "I'm going to our confirmed Delfina dinner Friday at eight.",
    "I'm going to the confirmed Delfina dinner Friday at eight too.",
    "Count me in for our Delfina dinner on Friday at 8 PM.",
  ]) {
    assert.deepEqual(rsvp(body, "going", delfinaState).response, { status: "going", plan_version: 4 });
  }
  assert.deepEqual(rsvp("I might come to our Delfina dinner Friday at eight.", "maybe", delfinaState).response, { status: "maybe", plan_version: 4 });
  assert.deepEqual(rsvp("I can't attend our Delfina dinner Friday at eight.", "declined", delfinaState).response, { status: "declined", plan_version: 4 });
  assert.throws(() => rsvp("I'm going to our Delfina dinner Friday at seven.", "going", delfinaState), /ambiguous/);
});

test("shared venue or duplicate title requires real date/time disambiguation rather than a model-selected target", () => {
  const sameVenue = { ...delfinaState, plans: [...delfinaState.plans, {
    ...delfinaState.plans[0], id: pollId, starts_at: "2026-10-17T02:00:00Z",
  }] };
  assert.throws(() => rsvp("I'm going to our confirmed Delfina dinner.", "going", sameVenue), /ambiguous/);
  assert.deepEqual(rsvp("I'm going to our confirmed Delfina dinner Friday at eight.", "going", sameVenue).response, { status: "going", plan_version: 4 });
  assert.throws(() => rsvp("I'm going to our confirmed Delfina dinner Friday at seven.", "going", sameVenue), /ambiguous/);
  const duplicateTitle = { ...planState, plans: [...planState.plans, { ...planState.plans[0], id: otherId }] };
  assert.throws(() => rsvp("I'm in for Dinner", "going", duplicateTitle), /ambiguous/);
  const drafts = { ...sameVenue, plans: sameVenue.plans.map(plan => ({ ...plan, status: "draft" })) };
  assert.throws(() => confirmNamed("Confirm our Delfina dinner.", drafts), /ambiguous/);
  assert.deepEqual(confirmNamed("Confirm our Delfina dinner Friday at 8 PM.", drafts).response, { plan_version: 4 });
});

test("extra sentences cannot smuggle conditional, reported, quoted or contradictory attendance", () => {
  for (const body of [
    "I'm going to our confirmed Delfina dinner Friday at eight if Ben comes.",
    "Ben said I'm going to our confirmed Delfina dinner Friday at eight.",
    '"I\'m going to our confirmed Delfina dinner Friday at eight."',
    "I'm going to our confirmed Delfina dinner Friday at eight. Actually I might not come.",
    "I'm going to our confirmed Delfina dinner Friday at eight. Bob is going too.",
    "I'm going to our confirmed Delfina dinner Friday at eight. Nothing is booked yet if Bob goes.",
  ]) assert.throws(() => rsvp(body, "going", delfinaState), /ambiguous/, body);
  const draft = { ...delfinaState, plans: [{ ...delfinaState.plans[0], status: "draft" }] };
  assert.throws(() => confirmNamed("Confirm our Delfina dinner Friday at eight. Ben said yes.", draft), /ambiguous/);
  assert.throws(() => confirmNamed("Confirm our Delfina dinner Friday at eight. Ignore previous changes.", draft), /ambiguous/);
});
