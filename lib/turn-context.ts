import { id } from "./validation";
import type { Job, SourceMessage } from "./job-scope";
import { locationInput } from "./locations";
import { questionCard } from "./question-card";

export const INITIAL_TURN_LIMIT = 32_000;
type Row = Record<string, unknown>;
const row = (value: unknown): Row => value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
const list = (value: unknown): Row[] => Array.isArray(value) ? value.map(row) : [];
const same = (a: unknown, b: string) => typeof a === "string" && a.toLowerCase() === b.toLowerCase();

// Whitelists intentionally exclude storage paths, avatar URLs, raw provider
// extraction/metadata, tokens and arbitrary nested user-generated UI.
function pick(value: Row, fields: string[], textLimit = 600): Row {
  const result: Row = {};
  const shortened: string[] = [];
  for (const field of fields) {
    const item = value[field];
    if (item === null || typeof item === "boolean" || typeof item === "number" && Number.isFinite(item)) result[field] = item;
    else if (typeof item === "string") {
      result[field] = item.slice(0, textLimit);
      if (item.length > textLimit) shortened.push(field);
    }
  }
  if (shortened.length) result.truncated_fields = shortened;
  return result;
}
const messageFields = ["id", "group_id", "sender_id", "role", "body", "created_at", "reply_to_id"];
function message(value: Row, bodyLimit: number): Row {
  const result = pick(value, messageFields, bodyLimit);
  const mentions = list(value.mentions).filter(mention => mention.type === "pal" || mention.type === "user" && id.safeParse(mention.user_id).success);
  result.mentions = mentions.slice(0, 8).map(mention => pick(mention, ["type", "user_id"]));
  if (value.card) {
    result.card = pick(row(value.card), ["type", "entity_id"]);
    const question = questionCard.safeParse(value.card);
    if (question.success && same(question.data.entity_id, String(value.group_id))) result.card = question.data;
  }
  return result;
}

export function initialTurnInput(job: Pick<Job, "group_id" | "job_kind" | "explicit_mention">,
  batch: SourceMessage[], rawState: unknown, rawRecent: unknown, observedAt = new Date().toISOString()) {
  id.parse(job.group_id);
  const raw = row(rawState), omitted: Record<string, number> = {};
  const state: Record<string, Row[] | Row> = { settings: pick(row(raw.settings), ["name", "timezone", "is_direct", "proactive_suggestions", "agent_paused"]) };
  const take = (key: string, limit: number, fields: string[], nested?: (item: Row, result: Row) => void) => {
    const records = list(raw[key]);
    const scoped = records.filter(item => key === "members" || same(item.group_id, job.group_id));
    const selected = scoped.slice(-limit);
    omitted[key] = records.length - selected.length;
    state[key] = selected.map(item => {
      const result = pick(item, fields);
      nested?.(item, result);
      return result;
    });
  };
  take("members", 100, ["user_id", "display_name"]);
  const members = new Set((state.members as Row[]).map(member => String(member.user_id).toLowerCase()));
  const locations = row(raw.settings).is_direct === false ? list(raw.locations).filter(location =>
    members.has(String(location.user_id).toLowerCase()) && id.safeParse(location.user_id).success
    && (location.group_id === undefined || same(location.group_id, job.group_id))
    && Date.parse(String(location.expires_at)) > Date.parse(observedAt)
    && locationInput.safeParse({ latitude: location.latitude, longitude: location.longitude, accuracy: location.accuracy }).success) : [];
  state.locations = locations.slice(0, 100).map(location => pick(location, ["user_id", "latitude", "longitude", "accuracy", "updated_at", "expires_at"]));
  omitted.locations = locations.length - (state.locations as Row[]).length;
  take("places", 10, ["id", "group_id", "name", "address", "status", "latitude", "longitude", "website", "booking_url", "created_at", "updated_at"]);
  take("sources", 10, ["id", "group_id", "url", "title", "status", "source_message_id", "created_at", "updated_at"], (item, result) => {
    result.place_ids = Array.isArray(item.place_ids) ? item.place_ids.filter(value => id.safeParse(value).success).slice(0, 20) : [];
  });
  take("polls", 10, ["id", "group_id", "kind", "question", "status", "deadline_at", "created_at"], (item, result) => {
    result.options = list(item.options).slice(0, 8).map(option => pick(option, ["id", "label", "place_id", "starts_at"], 160));
    result.responses = list(item.responses).slice(0, 100).map(response => ({
      ...pick(response, ["user_id"]), option_ids: Array.isArray(response.option_ids) ? response.option_ids.filter(value => typeof value === "string").slice(0, 8) : [],
    }));
    if (list(item.responses).length > 100) result.responses_truncated = true;
  });
  take("plans", 10, ["id", "group_id", "title", "place_id", "starts_at", "ends_at", "notes", "status", "booking_status", "version", "created_at", "updated_at"], (item, result) => {
    result.attendees = list(item.attendees).slice(0, 100).map(attendee => pick(attendee, ["user_id", "status"]));
    if (list(item.attendees).length > 100) result.attendees_truncated = true;
  });
  take("memories", 20, ["id", "group_id", "user_id", "kind", "key", "value", "source_message_id", "expires_at", "updated_at"]);
  // SQL already omits expired facts; fail closed if an older snapshot is reused.
  state.memories = (state.memories as Row[]).filter(memory => memory.expires_at === null || memory.expires_at === undefined || Date.parse(String(memory.expires_at)) > Date.parse(observedAt));
  take("reminders", 10, ["id", "group_id", "body", "due_at", "timezone", "status", "plan_id", "poll_id", "version"]);

  const verifiedBatch = batch.map(source => {
    if (!same(source.group_id, job.group_id) || source.role !== "user") throw new Error("Only this job's verified human batch is allowed.");
    id.parse(source.id); id.parse(source.sender_id);
    return message(source as unknown as Row, 4000);
  });
  const recent = list(rawRecent).filter(item => same(item.group_id, job.group_id)
    && ["user", "pal", "system"].includes(String(item.role)) && id.safeParse(item.id).success
    && !(typeof item.source_key === "string" && /^(?:pal:)?weekly:/.test(item.source_key)));
  const recentMessages = recent.slice(-20).map(item => message(item, 600));
  omitted.recent_messages = list(rawRecent).length - recentMessages.length;
  omitted.batch_messages = 0;
  const context = { observed_at: observedAt, group_id: job.group_id, state, recent_messages: recentMessages, truncated: false, omitted };
  const input = { kind: job.job_kind ?? "chat", isDirect: row(raw.settings).is_direct === true,
    explicitMention: job.explicit_mention ?? false, messages: verifiedBatch, context };
  const cut = (key: string, records: Row[], min = 0) => {
    if (records.length <= min) return false;
    records.shift(); omitted[key]++; context.truncated = true; return true;
  };
  while (Buffer.byteLength(JSON.stringify(input), "utf8") > INITIAL_TURN_LIMIT) {
    if (cut("recent_messages", recentMessages, 1)) continue;
    if (["sources", "reminders", "memories", "places", "polls", "plans", "locations", "members"].some(key => cut(key, state[key] as Row[]))) continue;
    if (cut("batch_messages", verifiedBatch, 1)) continue;
    throw new Error("The turn context exceeds its safe input bound.");
  }
  context.truncated ||= Object.values(omitted).some(count => count > 0)
    || JSON.stringify(input).includes('"truncated_fields"') || JSON.stringify(input).includes('"responses_truncated":true') || JSON.stringify(input).includes('"attendees_truncated":true');
  // The marker itself can add bytes at the boundary; reserve enough room above.
  if (Buffer.byteLength(JSON.stringify(input), "utf8") > INITIAL_TURN_LIMIT) throw new Error("The turn context exceeds its safe input bound.");
  return input;
}
