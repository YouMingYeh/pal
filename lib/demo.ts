import { z } from "zod";
import { admin, checked } from "./db";
import { id } from "./validation";
import { setTimeout as sleep } from "node:timers/promises";

export const demoRequest = z.discriminatedUnion("action", [
  z.object({ action: z.literal("next"), step: z.number().int().min(0).max(5), generation: id, client_id: id, body: z.string().trim().min(1).max(4000) }).strict(),
  z.object({ action: z.literal("reset") }).strict(),
]);
export const demoPrompts = [
  "Dinner Friday? Let's finally try one of the places we saved.",
  "7:30 works for me. I'm in the Mission. What fits everyone?",
  "Let's do Delfina on Friday at 7:30.",
  "Theo will be late. Let's make it eight.",
  "Confirm our Delfina dinner for Friday at 8 PM. Ask everyone to RSVP.",
  "I'm going to our confirmed Delfina dinner. Show the final invitation.",
] as const;
export const chatDemoPrompts = [
  "I finally closed all my tabs. Please clap.",
  "Pineapple on pizza: yes or no?",
  "Ben said he was five minutes away twenty minutes ago.",
  "Long day. I don't have the energy to make plans tonight.",
  "We still haven't gone to any of those places we saved.",
  "Okay, roast our group in one sentence.",
] as const;
export const promptsForDemo = (kind: string) => kind === "chat" ? chatDemoPrompts : demoPrompts;
// Both rehearsal casts and Pal's dialogue are scripted; shared plan/RSVP records remain real.
export function demoLines(step: number, actors: string[], kind = "plan") {
  if (actors.length !== 3 || !actors.every(actor => id.safeParse(actor).success)) throw new Error("Three registered rehearsal actors required.");
  const lines: [number, string][][] = kind === "chat" ? [
    [[1,"How many tabs are we talking?"], [2,"I still have fifty-four open. It's a filing system."]],
    [[0,"Yes. Sweet and salty is the point."], [1,"I was having a peaceful day until this question."]],
    [[2,"I meant emotionally five minutes away."]],
    [[0,"Same. Let's take the night off."]],
    [[1,"Our bookmarks have a more active social life than we do."]],
    [[2,"Keep it friendly. I'm fragile before coffee."]],
  ] : [
    [[0,"I'm free Friday after seven. Vegetarian here, and I'll be in the Mission."], [1,"I finish work at seven in SoMa. Pasta would be nice."], [2,"Friday works. I'll be downtown. Around $40 before drinks, please."]],
    [[0,"Delfina was the one I shared. Let's check the vegetarian options on the menu."], [2,"Pasta works for me."]],
    [[0,"Delfina is my preference."], [2,"Works for me."]],
    [[1,"I'll get there at eight. Sorry for the plot twist."], [0,"Eight works for me."], [2,"Eight works for me too."]],
    [[0,"Please send the invitation once the plan is confirmed."], [1,"Eight works."], [2,"Send it before we change our minds again."]],
    [[0,"I'm going to our confirmed Delfina dinner Friday at eight."], [1,"I'm going to the confirmed Delfina dinner Friday at eight too."], [2,"I'm going to our confirmed Delfina dinner Friday at eight."]],
  ];
  if (!Number.isInteger(step) || !lines[step]) throw new Error("Unknown rehearsal scene.");
  return lines[step].map(([actor, body]) => ({ user_id: actors[actor], body }));
}
export async function runDemoScenes(groupID?: string, expectedLines?: number) {
  // A persisted tick emits one actor per room. Cron resumes an interrupted sequence.
  for (let tick = 0; tick < 5; tick++) {
    const emitted = checked(await admin().rpc("pal_demo_tick", { p_group_id: groupID ?? null }));
    if (!emitted || groupID && expectedLines !== undefined && tick + 1 >= expectedLines) break;
    await sleep(1100);
  }
}
