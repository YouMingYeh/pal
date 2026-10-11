import { runSocialInspection } from "./social";
import { runCalendarSync } from "./calendar";
import { runPushDelivery } from "./push";

export async function runIntegrations() {
  const results = await Promise.allSettled([runSocialInspection(), runCalendarSync(), runPushDelivery()]);
  return Object.fromEntries(results.map((result, index) => {
    const name = ["sources", "calendar", "push"][index];
    if (result.status === "rejected") console.error(`Pal ${name} worker could not finish; persisted work remains queued.`);
    return [name, result.status === "fulfilled" ? result.value : 0];
  }));
}
