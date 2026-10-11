import { timingSafeEqual } from "node:crypto";
import { z } from "zod";

export const id = z.string().uuid();
export const groupInput = z.object({ name: z.string().trim().min(1).max(80) }).strict();
export const joinInput = z.object({ invite_code: id }).strict();
export const messageInput = z.object({ body: z.string().trim().min(1).max(4000), client_id: id }).strict();

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
