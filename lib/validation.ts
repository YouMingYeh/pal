import { timingSafeEqual } from "node:crypto";
import { z } from "zod";

export const id = z.string().uuid();
export const groupInput = z.object({ name: z.string().trim().min(1).max(80) }).strict();
export const joinInput = z.object({ invite_code: id }).strict();
export const messageInput = z.object({ body: z.string().trim().min(1).max(4000), client_id: id, reply_to_id: id.optional() }).strict();

export const httpUrl = z.string().max(2000).url().refine(value => {
  const url = new URL(value);
  return ["http:", "https:"].includes(url.protocol) && !url.username && !url.password;
}, "Use a public HTTP or HTTPS link without credentials.");
export const timezone = z.string().max(80).refine(value => {
  try { new Intl.DateTimeFormat("en", { timeZone: value }); return true; }
  catch { return false; }
}, "Use a recognized time zone.");
const timestamp = z.string().datetime({ offset: true });
const sourceKey = { source_key: z.string().min(1).max(200).optional() };
const placeFields = {
  name: z.string().trim().min(1).max(160), address: z.string().trim().max(500),
  latitude: z.number().min(-90).max(90), longitude: z.number().min(-180).max(180),
  provider: z.literal("apple"), provider_id: z.string().min(1).max(300),
  source_id: id.optional(), website: httpUrl.nullable().optional(), booking_url: httpUrl.nullable().optional(),
};
const sourceFields = {
  url: httpUrl, canonical_url: httpUrl.optional(), title: z.string().max(300).optional(), source_message_id: id.optional(),
  status: z.enum(["pending", "resolved", "needs_confirmation", "failed"]).optional(), place_ids: z.array(id).max(20).optional(),
};
const planFields = {
  title: z.string().trim().min(1).max(160), place_id: id.nullable().optional(),
  starts_at: timestamp, ends_at: timestamp.nullable().optional(), notes: z.string().max(2000).optional(),
};
const reminderFields = {
  body: z.string().trim().min(1).max(2000), due_at: timestamp, timezone,
  target_user_ids: z.array(id).max(50).optional(), plan_id: id.nullable().optional(), poll_id: id.nullable().optional(),
};
const pollOption = z.object({ id: z.string().min(1).max(64), label: z.string().trim().min(1).max(160), place_id: id.optional(), starts_at: timestamp.optional() }).strict();
const memoryFields = {
  id: id.optional(), kind: z.enum(["preference", "availability"]), key: z.string().trim().min(1).max(80),
  value: z.string().trim().min(1).max(1000), source_message_id: id.optional(), expires_at: timestamp.nullable().optional(),
};

export const actionSchemas = {
  "group.settings": z.object({ timezone: timezone.optional(), proactive_suggestions: z.boolean().optional(), agent_paused: z.boolean().optional(), name: groupInput.shape.name.optional(), ...sourceKey }).strict(),
  "group.read": z.object({ message_id: id, ...sourceKey }).strict(),
  "reaction.toggle": z.object({ message_id: id, emoji: z.enum(["👍", "❤️", "😂", "🎉", "👀", "✅", "🤔"]), ...sourceKey }).strict(),
  "memory.save": z.object({ ...memoryFields, ...sourceKey }).strict().refine(value => value.kind !== "availability" || Boolean(value.expires_at), "Dated availability needs an expiry."),
  "memory.delete": z.object({ id, ...sourceKey }).strict(),
  "place.save": z.object({ ...placeFields, ...sourceKey }).strict(),
  "place.correct": z.object({ id, ...z.object(placeFields).partial().shape, ...sourceKey }).strict(),
  "place.delete": z.object({ id, ...sourceKey }).strict(),
  "source.create": z.object({ ...sourceFields, ...sourceKey }).strict(),
  "source.update": z.object({ id, ...z.object(sourceFields).partial().shape, ...sourceKey }).strict(),
  "poll.create": z.object({
    kind: z.enum(["place", "time"]), question: z.string().trim().min(1).max(300),
    options: z.array(pollOption).min(2).max(8), deadline_at: timestamp, ...sourceKey,
  }).strict().refine(value => new Set(value.options.map(option => option.id)).size === value.options.length, "Poll option IDs must be unique.")
    .refine(value => value.kind !== "time" || value.options.every(option => Boolean(option.starts_at)), "Time options need dated start times."),
  "poll.vote": z.object({ id, option_ids: z.array(z.string().min(1).max(64)).max(8), ...sourceKey }).strict(),
  "plan.create": z.object({ ...planFields, ...sourceKey }).strict().refine(value => !value.ends_at || Date.parse(value.ends_at) > Date.parse(value.starts_at), "Plan must end after it starts."),
  "plan.update": z.object({ id, ...z.object(planFields).partial().shape, ...sourceKey }).strict().refine(value => !value.starts_at || !value.ends_at || Date.parse(value.ends_at) > Date.parse(value.starts_at), "Plan must end after it starts."),
  "plan.confirm": z.object({ id, ...sourceKey }).strict(),
  "plan.cancel": z.object({ id, ...sourceKey }).strict(),
  "plan.rsvp": z.object({ id, status: z.enum(["going", "maybe", "declined"]), ...sourceKey }).strict(),
  "plan.booking": z.object({ id, status: z.enum(["needed", "requested", "booked", "failed"]), reference: z.string().max(500).optional(), ...sourceKey }).strict(),
  "reminder.create": z.object({ ...reminderFields, ...sourceKey }).strict(),
  "reminder.update": z.object({ id, ...z.object(reminderFields).partial().shape, ...sourceKey }).strict(),
  "reminder.cancel": z.object({ id, ...sourceKey }).strict(),
  "message.reply": z.object({ ...messageInput.shape, reply_to_id: id, ...sourceKey }).strict(),
} as const;

const actionVariants = Object.entries(actionSchemas).map(([action, data]) => z.object({ action: z.literal(action), data }).strict());
export const actionInput = z.discriminatedUnion("action", actionVariants as [typeof actionVariants[number], ...typeof actionVariants[number][]]);
export const agentAllowedActions = new Set(["reaction.toggle", "memory.save", "place.save", "place.correct", "source.create", "poll.create", "plan.create", "reminder.create"]);

export function parseAgentAction(action: keyof typeof actionSchemas, data: unknown) {
  if (!agentAllowedActions.has(action)) throw new Error("This action requires a group member.");
  if (action === "place.correct") return z.object({ id, booking_url: httpUrl }).strict().parse(data);
  return actionSchemas[action].parse(data);
}

export const profileInput = z.object({
  display_name: z.string().trim().min(1).max(60).optional(), avatar_url: httpUrl.refine(value => new URL(value).protocol === "https:", "Avatar must use HTTPS.").nullable().optional(),
  notifications_enabled: z.boolean().optional(),
  notification_preferences: z.object({ enabled: z.boolean() }).strict().optional(),
}).strict().refine(value => value.notifications_enabled === undefined || value.notification_preferences === undefined, "Choose one notification setting field.");
export const deviceInput = z.object({ token: z.string().regex(/^[a-fA-F0-9]{64,200}$/).refine(value => value.length % 2 === 0, "Token must encode complete bytes."), environment: z.enum(["sandbox", "production"]) }).strict();
export const palEmotions = ["fier", "heureux", "hilare", "curieux", "confus", "surpris", "timide", "triste", "colere", "somnolent", "attentif", "neutre"] as const;
export const palEmotion = z.enum(palEmotions);
export const agentReply = z.object({
  reply: z.string().max(4000).describe("The short chat reply. Return an empty string to stay silent after observations or tool/card actions."),
  emotion: palEmotion.catch("fier").optional().describe("The mascot expression matching this reply's actual tone; use fier when no more specific emotion fits."),
}).strict();

export function parsedPalReply(value: unknown) {
  const reply = agentReply.parse(value);
  return { body: reply.reply.trim(), emotion: reply.emotion ?? "fier" };
}

export function sharedUrls(body: string) {
  const found = body.match(/https?:\/\/[^\s<>]+/gi) ?? [];
  return [...new Set(found.map(value => value.replace(/[),.!?;'"\]\}]+$/, "")).filter(value => httpUrl.safeParse(value).success))].slice(0, 10);
}

export function matchesSecret(header: string | null, secret: string | undefined) {
  if (!secret || !header?.startsWith("Bearer ")) return false;
  const actual = Buffer.from(header.slice(7));
  const expected = Buffer.from(secret);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export function validateReminder(dueAt: string, timezone: string, now = Date.now()) {
  const date = Date.parse(dueAt);
  if (!Number.isFinite(date) || date <= now || date > now + 366 * 86400000) {
    throw new Error("Reminder must be in the future, within one year.");
  }
  new Intl.DateTimeFormat("en", { timeZone: timezone }).format(date);
  return new Date(date).toISOString();
}
