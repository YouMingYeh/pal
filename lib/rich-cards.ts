import { z } from "zod";
import { id, timezone } from "./validation";

const title = z.string().trim().min(1).max(300);
const timestamp = z.string().datetime({ offset: true });
export const optionsCardInput = z.object({
  title,
  options: z.array(z.union([
    z.object({ place_id: id }).strict(),
    z.object({ inspiration: z.string().trim().min(1).max(160) }).strict(),
  ])).min(2).max(8),
  deadline_at: timestamp,
}).strict();
export const availabilityCardInput = z.object({
  title,
  slots: z.array(z.object({ starts_at: timestamp }).strict()).min(2).max(8),
  deadline_at: timestamp,
}).strict();
type Place = { id: string; group_id: string; name: string; status: string };

function deadline(value: string, now: number) {
  const date = Date.parse(value);
  if (date <= now || date > now + 366 * 86400_000) throw new Error("Choose a future response deadline within one year.");
  return new Date(date).toISOString();
}

export function prepareOptionsCard(raw: unknown, places: Place[], groupId: string, now = Date.now()) {
  const input = optionsCardInput.parse(raw);
  const identities = new Set<string>();
  const options = input.options.map((option, index) => {
    if ("place_id" in option) {
      const place = places.find(place => place.id.toLowerCase() === option.place_id.toLowerCase()
        && place.group_id.toLowerCase() === groupId.toLowerCase() && place.status === "resolved");
      if (!place) throw new Error("Choose a resolved place saved in this group; resolve and save it first.");
      if (identities.has(`place:${place.id.toLowerCase()}`)) throw new Error("Show each option once.");
      identities.add(`place:${place.id.toLowerCase()}`);
      return { id: `option-${index + 1}`, label: place.name, place_id: place.id };
    }
    const identity = `inspiration:${option.inspiration.toLocaleLowerCase()}`;
    if (identities.has(identity)) throw new Error("Show each option once.");
    identities.add(identity);
    return { id: `option-${index + 1}`, label: option.inspiration };
  });
  return { kind: "place" as const, presentation: "options" as const, question: input.title, options,
    deadline_at: deadline(input.deadline_at, now) };
}

export function prepareAvailabilityCard(raw: unknown, groupTimezone: string, now = Date.now()) {
  const input = availabilityCardInput.parse(raw);
  timezone.parse(groupTimezone);
  const due = deadline(input.deadline_at, now);
  const dates = input.slots.map(slot => Date.parse(slot.starts_at));
  if (new Set(dates).size !== dates.length) throw new Error("Show each dated time once.");
  if (dates.some(date => date <= Date.parse(due) || date > now + 366 * 86400_000)) {
    throw new Error("Proposed times must be future, after the response deadline and within one year.");
  }
  const format = new Intl.DateTimeFormat("en-US", { timeZone: groupTimezone, weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  return { kind: "time" as const, presentation: "availability" as const, question: input.title,
    options: input.slots.map((slot, index) => ({ id: `time-${index + 1}`, label: format.format(dates[index]), starts_at: new Date(dates[index]).toISOString() })),
    deadline_at: due };
}
