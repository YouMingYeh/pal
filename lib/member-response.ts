import { z } from "zod";
import { batchSpeaker, type SourceMessage } from "./job-scope";
import { id } from "./validation";

const sourceFields = { source_message_id: id, evidence: z.string().min(1).max(2000), target_id: id };
export const memberResponseInput = z.discriminatedUnion("target_kind", [
  z.object({ ...sourceFields, target_kind: z.literal("poll"), response: z.enum(["options", "either", "none"]), option_ids: z.array(z.string().min(1).max(64)).max(8).default([]) }).strict(),
  z.object({ ...sourceFields, target_kind: z.literal("plan"), status: z.enum(["going", "maybe", "declined"]) }).strict(),
  z.object({ ...sourceFields, target_kind: z.literal("confirmation") }).strict(),
]);
type Input = z.infer<typeof memberResponseInput>;
type Option = { id: string; label: string; starts_at?: string };
type Poll = { id: string; group_id: string; kind: "place" | "time"; status: string; deadline_at: string; created_at: string; question: string; options: Option[] };
type Plan = { id: string; group_id: string; title: string; status: string; starts_at: string; created_at: string; updated_at: string; version: number };
export type ResponseState = { polls: Poll[]; plans: Plan[]; settings: { timezone: string } };
const clarify = () => { throw new Error("The speaker's response is ambiguous. Ask one short clarification; do not record a vote or RSVP."); };
const normalized = (value: string) => value.toLowerCase().replace(/[’‘]/g, "'").replace(/[^\p{L}\p{N}:]+/gu, " ").trim();
const sameChoices = (a: string[], b: string[]) => a.length === b.length && a.every(value => b.includes(value));
const either = /^(?:either(?: one| option)?(?: works(?: for me)?)?|both(?: work| works)?(?: for me)?|anything works(?: for me)?|any of (?:them|these) (?:work|works)(?: for me)?|都可以|都行|兩個都可以|两个都可以)[.!。！]*$/i;
const none = /^(?:none(?: of (?:these|those|them))?(?: work| works)?(?: for me)?|neither(?: works)?(?: for me)?|i (?:can't|cannot) (?:do|make) (?:any|either)(?: of (?:these|those|them))?(?: times?| slots?)?|這些時間都不行|这些时间都不行|都不行)[.!。！]*$/i;

function explicitRsvp(text: string, title: string) {
  const escaped = title.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const suffix = `(?: (?:for|to) ${escaped})?[.!。！]*$`;
  if (new RegExp("^(?:yes|yes[, ]+(?:i'm in|i am in)|i(?:'m| am) (?:in|coming|going|attending)|count me in|i(?:'ll| will) (?:be there|come|attend|join)|我會去|我会去|我會到|我会到|我參加|我参加|算我一個|算我一个)" + suffix, "i").test(text)) return "going";
  if (new RegExp("^(?:no|i (?:can't|cannot|won't|will not) (?:make it|come|attend|join)|i(?:'m| am) not (?:coming|going|attending)|我不去|我不能去|我沒辦法去|我没办法去)" + suffix, "i").test(text)) return "declined";
  if (new RegExp("^(?:maybe|i(?:'m| am) (?:a )?maybe|i (?:might|may) (?:come|attend|join)|我可能會去|我可能会去|我還不確定|我还不确定)" + suffix, "i").test(text)) return "maybe";
  return null;
}

function explicitConfirmation(text: string, title: string) {
  const escaped = title.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`^(?:(?:i confirm|confirm|let's confirm|let us confirm) (?:the plan|this plan|${escaped})|(?:我確認|我确认|確認|确认)(?:這個計畫|这个计划|計畫|计划|${escaped}))[.!。！]*$`, "i").test(text);
}

function localParts(date: string, timezone: string) {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit", weekday: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(new Date(date));
  const read = (key: string) => parts.find(part => part.type === key)!.value;
  return { day: `${read("year")}-${read("month")}-${read("day")}`, weekday: read("weekday").toLowerCase(), minute: Number(read("hour")) * 60 + Number(read("minute")) };
}

function timeChoices(text: string, poll: Poll, source: SourceMessage, timezone: string) {
  const weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
  const names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
  const mentioned = weekdays.filter((day, index) => new RegExp(`\\b(?:${day}|${names[index]})\\b`, "i").test(text));
  if (mentioned.length !== 1 || /\bnext\b/i.test(text)) return [];
  // Resolve the weekday from the immutable source date, so a retry cannot move a vote to next week.
  const anchor = localParts(source.created_at, timezone);
  const delta = (weekdays.indexOf(mentioned[0]) - weekdays.indexOf(anchor.weekday) + 7) % 7;
  const targetDay = new Date(Date.parse(`${anchor.day}T12:00:00Z`) + delta * 86400_000).toISOString().slice(0, 10);
  const dated = poll.options.filter(option => option.starts_at && localParts(option.starts_at, timezone).day === targetDay);
  const clockText = text.toLowerCase().replace(/\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b/g, word => String(["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"].indexOf(word) + 1));
  if ([...clockText.matchAll(/\b(after|from|at|before)\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?\b/g)].length > 1) return [];
  const clock = clockText.match(/\b(after|from|at|before)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b/);
  if (!clock) return /\b(?:\d|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b/i.test(text) ? [] : dated.map(option => option.id);
  let hour = Number(clock[2]);
  const minute = Number(clock[3] || 0);
  if (hour > 23 || minute > 59 || (clock[4] && (hour < 1 || hour > 12))) return [];
  if (clock[4]) hour = hour % 12 + (clock[4] === "pm" ? 12 : 0);
  else if (hour >= 1 && hour <= 12) {
    const periods = new Set(dated.map(option => localParts(option.starts_at!, timezone).minute >= 720));
    if (periods.size !== 1) return [];
    if (periods.has(true) && hour < 12) hour += 12;
  }
  const boundary = hour * 60 + minute;
  return dated.filter(option => {
    const value = localParts(option.starts_at!, timezone).minute;
    return clock[1] === "after" ? value > boundary : clock[1] === "from" ? value >= boundary : clock[1] === "before" ? value < boundary : value === boundary;
  }).map(option => option.id);
}

export function prepareMemberResponse(raw: unknown, batch: SourceMessage[], state: ResponseState, groupId: string, now = Date.now()) {
  const input: Input = memberResponseInput.parse(raw);
  const source = batchSpeaker(batch, input.source_message_id);
  if (source.group_id !== groupId || source.body.trim() !== input.evidence) throw new Error("Use the entire verified speaker message as verbatim evidence.");
  const text = input.evidence.trim().replace(/[’‘]/g, "'");
  // Reject reported speech, quoted utterances, conditions and banter before interpreting first-person language.
  if (/["“”«»]|(?:^|\s)'[^']+'|[?？]|\b(?:said|says|told|asked|joking|kidding|jk|unless|if|depends|pretend|ignore|override)\b/i.test(text)
    || /\b(?:he|she|they|you|we)\s+(?:can|can't|will|won't|are|is|might|prefer|choose|vote|agree)\b/i.test(text)
    || /\b[A-Z][a-z]+\s+(?:can|can't|will|won't|is|might|prefers?|chooses?|votes?|agrees?)\b/.test(text)) clarify();
  if (input.target_kind === "confirmation") {
    const target = state.plans.find(plan => plan.id === input.target_id && plan.group_id === groupId);
    if (!target || target.status !== "draft" || Date.parse(target.starts_at) <= now || Date.parse(source.created_at) < Date.parse(target.updated_at)) {
      throw new Error("Choose a current, future draft plan discussed after its latest change.");
    }
    if (!explicitConfirmation(text, target.title)) clarify();
    const active = state.plans.filter(plan => plan.status === "draft" && Date.parse(plan.starts_at) > now);
    if (active.length !== 1 && !normalized(text).includes(normalized(target.title))) clarify();
    return { source, response: { plan_version: target.version } };
  }
  if (input.target_kind === "plan") {
    const target = state.plans.find(plan => plan.id === input.target_id && plan.group_id === groupId);
    if (!target || target.status !== "confirmed" || Date.parse(target.starts_at) <= now || Date.parse(source.created_at) < Date.parse(target.updated_at)) throw new Error("Choose a current, future confirmed plan discussed after its latest change.");
    const stated = explicitRsvp(text, target.title);
    if (stated !== input.status || either.test(text) || /\b(?:maybe|might|may)\b/i.test(text) && stated !== "maybe") clarify();
    const active = state.plans.filter(plan => plan.status === "confirmed" && Date.parse(plan.starts_at) > now);
    const named = normalized(text).includes(normalized(target.title));
    if (active.length !== 1 && !named) clarify();
    // A bare yes/no/maybe is only meaningful in reply to the confirmed plan, not an open poll.
    if (/^(?:yes|no|maybe)[.!。！]*$/i.test(text) && state.polls.some(poll => poll.status === "open" && Date.parse(poll.deadline_at) > now)) clarify();
    return { source, response: { status: input.status, plan_version: target.version } };
  }
  const target = state.polls.find(poll => poll.id === input.target_id && poll.group_id === groupId);
  if (!target || target.status !== "open" || Date.parse(target.deadline_at) <= now || Date.parse(source.created_at) < Date.parse(target.created_at)) throw new Error("Choose an open group poll that existed when this message was sent.");
  if (/\b(?:maybe|might|may|perhaps|probably|not sure)\b/i.test(text)) clarify();
  const active = state.polls.filter(poll => poll.status === "open" && Date.parse(poll.deadline_at) > now);
  if (input.response === "either" || input.response === "none") {
    if (active.length !== 1 || !(input.response === "either" ? either : none).test(text) || input.option_ids.length || input.response === "none" && target.kind !== "time") clarify();
    return { source, response: { kind: input.response, option_ids: [] } };
  }
  if (!input.option_ids.length || new Set(input.option_ids).size !== input.option_ids.length) clarify();
  if (!/\b(?:works?|prefer|choose|vote|can do|can make|am free|i'm free)\b|我選|我选|我可以|有空|可以|都行/i.test(text) || /\b(?:can't|cannot|won't|not|no)\b|不行|不能/i.test(text)) clarify();
  const own = /^(?:i(?:'m| am) free|i (?:prefer|choose|vote|can (?:do|make))|我(?:選|选|可以))/i.test(text);
  const terse = /\bworks?(?: for me)?[.!]*$/i.test(text) && !/\bfor (?!me\b)\w+/i.test(text);
  if (!own && !terse) clarify();
  const direct = target.options.filter(option => normalized(text).includes(normalized(option.label))).map(option => option.id);
  const selected = target.kind === "time" ? timeChoices(text, target, source, state.settings.timezone) : direct;
  const constrained = target.kind === "time" && /\b(?:after|from|at|before|next)\b/i.test(text);
  if (!sameChoices(input.option_ids, constrained || selected.length ? selected : direct)) clarify();
  if (active.length !== 1 && !normalized(text).includes(normalized(target.question))) clarify();
  return { source, response: { kind: "options", option_ids: input.option_ids } };
}
