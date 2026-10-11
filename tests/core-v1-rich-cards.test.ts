import assert from "node:assert/strict";
import { test } from "node:test";
import { prepareAvailabilityCard, prepareOptionsCard } from "../lib/rich-cards";
import { parsedPalOutputs, parseAgentAction } from "../lib/validation";
import { prepareMemberResponse, type ResponseState } from "../lib/member-response";
import type { SourceMessage } from "../lib/job-scope";

const group = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", placeID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const otherGroup = "cccccccc-cccc-4ccc-8ccc-cccccccccccc", board = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const message = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const now = Date.parse("2026-10-12T20:00:00Z");
const venue = { id: placeID, group_id: group, name: "Actual saved venue", status: "resolved" };
const choices = { title: "Dinner ideas", options: [{ place_id: placeID }, { inspiration: "Board games at home" }], deadline_at: "2026-10-15T20:00:00Z" };

test("option cards use verified saved venue identity and honest inspiration without fabricated details", () => {
  const result = prepareOptionsCard(choices, [venue], group, now);
  assert.deepEqual(result.options, [
    { id: "option-1", label: venue.name, place_id: placeID }, { id: "option-2", label: "Board games at home" },
  ]);
  assert.deepEqual(parseAgentAction("poll.create", result), result);
  assert.throws(() => prepareOptionsCard(choices, [{ ...venue, group_id: otherGroup }], group, now), /saved in this group/);
  assert.throws(() => prepareOptionsCard(choices, [{ ...venue, status: "pending" }], group, now), /saved in this group/);
  assert.throws(() => prepareOptionsCard({ ...choices, options: [{ place_id: placeID, label: "Fake price and availability" }, choices.options[1]] }, [venue], group, now));
  assert.throws(() => prepareOptionsCard({ ...choices, options: [{ inspiration: "Games", website: "https://made-up.example" }, choices.options[0]] }, [venue], group, now));
  assert.throws(() => prepareOptionsCard({ ...choices, options: [{ place_id: placeID }, { place_id: placeID.toUpperCase() }] }, [venue], group, now), /once/);
  assert.throws(() => prepareOptionsCard({ ...choices, options: [{ inspiration: "Games" }, { inspiration: " games " }] }, [venue], group, now), /once/);
});

test("availability proposals preserve dated instants, use group timezone and invent no responses", () => {
  const input = { title: "Which evening?", slots: [{ starts_at: "2026-10-17T02:00:00Z" }, { starts_at: "2026-10-17T03:00:00Z" }], deadline_at: choices.deadline_at };
  const result = prepareAvailabilityCard(input, "America/Los_Angeles", now);
  assert.equal(result.options[0].label, "Fri, Oct 16, 7:00 PM");
  assert.equal(result.options[1].starts_at, "2026-10-17T03:00:00.000Z");
  assert.equal("responses" in result, false);
  assert.equal("attendees" in result, false);
  assert.deepEqual(parseAgentAction("poll.create", result), result);
  assert.throws(() => prepareAvailabilityCard({ ...input, user_id: placeID }, "America/Los_Angeles", now));
  assert.throws(() => prepareAvailabilityCard({ ...input, slots: [{ ...input.slots[0], label: "Everyone is free" }, input.slots[1]] }, "America/Los_Angeles", now));
  assert.throws(() => prepareAvailabilityCard({ ...input, slots: [input.slots[0], { starts_at: "2026-10-16T19:00:00-07:00" }] }, "America/Los_Angeles", now), /once/);
  assert.throws(() => prepareAvailabilityCard({ ...input, deadline_at: "2026-10-18T00:00:00Z" }, "America/Los_Angeles", now), /after the response deadline/);
  assert.throws(() => prepareAvailabilityCard({ ...input, deadline_at: "2026-10-12T19:00:00Z" }, "America/Los_Angeles", now), /future response deadline/);
  assert.throws(() => parseAgentAction("poll.create", { ...result, presentation: "options" }), /match/);
});

test("rich outputs reference persisted entities rather than accepting generated UI or member state", () => {
  for (const type of ["plan", "options", "availability", "rsvp", "choice"]) {
    const output = parsedPalOutputs({ reply: "", messages: [{ body: "Here are the actual details.", card: { type, entity_id: board } }] });
    assert.deepEqual(output[0].card, { type, entity_id: board }); // SQL additionally checks current entity/group/status.
  }
  for (const card of [
    { type: "calendar", entity_id: board }, { type: "plan", entity_id: board, attendees: [placeID] },
    { type: "options", entity_id: board, html: "<iframe>" }, { type: "availability", entity_id: board, responses: { [placeID]: "free" } },
  ]) assert.throws(() => parsedPalOutputs({ reply: "", messages: [{ body: "Details", card }] }));
  assert.deepEqual(parsedPalOutputs({ reply: "", messages: [] }), [], "Rich cards do not remove selective silence.");
});

test("collecting an earlier schedule requires clear own dated facts; vague responses still need existing choices", () => {
  const state: ResponseState = { settings: { timezone: "America/Los_Angeles" }, plans: [], polls: [{
    id: board, group_id: group, kind: "time", status: "open", question: "Friday dinner?",
    created_at: "2026-10-12T19:30:00Z", deadline_at: choices.deadline_at,
    options: [{ id: "seven", label: "Friday 7 PM", starts_at: "2026-10-17T02:00:00Z" }, { id: "eight", label: "Friday 8 PM", starts_at: "2026-10-17T03:00:00Z" }],
  }] };
  const source = (body: string): SourceMessage => ({ id: message, group_id: group, sender_id: placeID, role: "user", body, created_at: "2026-10-12T19:00:00Z" });
  const response = (body: string, kind: "options" | "either" | "none" = "options", ids = ["eight"]) => ({
    source_message_id: message, evidence: body, target_id: board, target_kind: "poll", response: kind, option_ids: ids,
  });
  assert.throws(() => prepareMemberResponse(response("I'm free Friday after 7 pm"), [source("I'm free Friday after 7 pm")], state, group, now), /existed/);
  assert.deepEqual(prepareMemberResponse(response("I'm free Friday after 7 pm"), [source("I'm free Friday after 7 pm")], state, group, now, true).response,
    { kind: "options", option_ids: ["eight"] }); // SQL requires the exact same active job's trusted creation receipt.
  for (const [body, kind] of [["Anything works", "either"], ["None of these times work for me", "none"]] as const) {
    assert.throws(() => prepareMemberResponse(response(body, kind, []), [source(body)], state, group, now, true), /existed/);
  }
  assert.throws(() => prepareMemberResponse(response("Ben is free Friday after 7 pm"), [source("Ben is free Friday after 7 pm")], state, group, now, true), /ambiguous/);
  const existing = { ...state, polls: [{ ...state.polls[0], created_at: "2026-10-12T18:00:00Z" }] };
  assert.deepEqual(prepareMemberResponse(response("None of these times work for me", "none", []), [source("None of these times work for me")], existing, group, now).response,
    { kind: "none", option_ids: [] });
  const alongsideIdeas: ResponseState = { ...existing, polls: [...existing.polls, { ...existing.polls[0], id: otherGroup, kind: "place", options: [{ id: "games", label: "Board games" }, { id: "picnic", label: "Picnic" }] }] };
  assert.deepEqual(prepareMemberResponse(response("I'm free Friday after 7 pm"), [source("I'm free Friday after 7 pm")], alongsideIdeas, group, now).response,
    { kind: "options", option_ids: ["eight"] }, "An inspiration list does not make a clear dated schedule ambiguous.");
  assert.deepEqual(prepareMemberResponse(response("None of these times work for me", "none", []), [source("None of these times work for me")], alongsideIdeas, group, now).response,
    { kind: "none", option_ids: [] });
  assert.throws(() => prepareMemberResponse(response("Anything works", "either", []), [source("Anything works")], alongsideIdeas, group, now), /ambiguous/);
});
