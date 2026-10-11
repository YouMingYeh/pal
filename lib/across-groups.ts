import { z } from "zod";
import { checked } from "./db";
import { id } from "./validation";
import { type jobScope } from "./job-scope";

export const acrossGroupsInput = z.object({
  offset: z.number().int().min(0).max(1000).default(0),
  query: z.string().trim().min(1).max(100).nullable().optional()
    .describe("Optional literal text in a group name or its recent messages. Omit for general summaries; this is not SQL or a global search."),
}).strict();
const timestamp = z.string().datetime({ offset: true });
const card = z.object({ type: z.string().max(40), entity_id: id });
const message = z.object({
  id, sender_id: id.nullable(), role: z.enum(["user", "pal", "system"]), body: z.string().max(500),
  created_at: timestamp, body_truncated: z.boolean().default(false), card: card.nullable().optional(), reply_to_id: id.nullable().optional(),
});
const plan = z.object({
  id, title: z.string().max(160), status: z.enum(["draft", "confirmed", "cancelled"]),
  starts_at: timestamp, ends_at: timestamp, place_id: id.nullable().optional(),
  booking_status: z.enum(["needed", "requested", "booked", "failed"]).optional(), updated_at: timestamp.optional(),
});
const place = z.object({
  id, name: z.string().max(160), address: z.string().max(500), status: z.enum(["resolved", "needs_confirmation"]).optional(),
  latitude: z.number().min(-90).max(90).nullable().optional(), longitude: z.number().min(-180).max(180).nullable().optional(),
  created_at: timestamp.optional(),
});
const source = z.object({
  id, url: z.string().max(2000).nullable(), title: z.string().max(300).nullable().optional(),
  status: z.enum(["pending", "resolving", "resolved", "needs_confirmation", "failed"]),
  source_message_id: id.nullable().optional(), created_at: timestamp.optional(),
});
const memory = z.object({
  id, user_id: id.optional(), kind: z.enum(["preference", "availability"]), key: z.string().max(80),
  value: z.string().max(500), value_truncated: z.boolean().default(false), source_message_id: id.nullable().optional(),
  expires_at: timestamp.nullable(), updated_at: timestamp.optional(),
});
const group = z.object({
  id, name: z.string().max(100), timezone: z.string().max(100), is_demo: z.boolean().default(false),
  members: z.array(z.object({ user_id: id, display_name: z.string().max(60) })).max(100),
  messages: z.array(message).max(20), plans: z.array(plan).max(10), places: z.array(place).max(10),
  sources: z.array(source).max(10), memories: z.array(memory).max(10), truncated: z.boolean().default(false),
});
const contextSchema = z.object({
  groups: z.array(group).max(5), next_offset: z.number().int().min(0).max(1000).nullable(),
  truncated: z.boolean().default(false),
});
export const CROSS_GROUP_CONTEXT_LIMIT = 32_000;

export function boundedAcrossGroupContext(raw: unknown) {
  // Explicit whitelists strip private avatar paths, credentials and arbitrary UI fields.
  const context = contextSchema.parse(raw);
  for (const group of context.groups) {
    group.truncated ||= group.messages.some(message => message.body_truncated) || group.memories.some(memory => memory.value_truncated);
    context.truncated ||= group.truncated;
  }
  const arrays = ["messages", "sources", "memories", "places", "plans", "members"] as const;
  while (Buffer.byteLength(JSON.stringify(context), "utf8") > CROSS_GROUP_CONTEXT_LIMIT) {
    let removed = false;
    for (const key of arrays) {
      const candidate = context.groups.filter(group => group[key].length > (key === "messages" || key === "plans" ? 1 : 0))
        .sort((a, b) => Buffer.byteLength(JSON.stringify(b[key]), "utf8") - Buffer.byteLength(JSON.stringify(a[key]), "utf8"))[0];
      if (candidate) {
        // Message records arrive in chronological order; keep the newest context.
        if (key === "messages") candidate[key].shift();
        else candidate[key].pop();
        candidate.truncated = true;
        context.truncated = true;
        removed = true;
        break;
      }
    }
    if (!removed) throw new Error("The private context exceeds its safe bound.");
  }
  return context;
}

export async function readAcrossGroups(raw: unknown, scope: Awaited<ReturnType<typeof jobScope>>) {
  const input = acrossGroupsInput.parse(raw);
  const result = checked(await scope.db.rpc("pal_read_across_groups", {
    p_job_id: scope.job.id, p_attempt: scope.job.attempts, p_offset: input.offset, p_query: input.query ?? null,
  }));
  // The service RPC atomically checks the live, owner-only DM and all current memberships.
  return boundedAcrossGroupContext(result);
}
