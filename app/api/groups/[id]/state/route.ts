import { after } from "next/server";
import { member, route } from "../../../../../lib/http";
import { checked } from "../../../../../lib/db";
import { actionInput } from "../../../../../lib/validation";
import { dispatchJobs } from "../../../../../lib/jobs";
import { setTimeout as sleep } from "node:timers/promises";
import { signedAvatar } from "../../../../../lib/avatar";
import { signedGroupAvatar } from "../../../../../lib/group-avatar";

export const maxDuration = 300;
type Context = { params: Promise<{ id: string }> };

export function GET(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { db } = await member(request, id);
    const state = checked(await db.rpc("pal_group_state", { p_group_id: id }));
    state.members = await Promise.all(state.members.map((member: Parameters<typeof signedAvatar>[0]) => signedAvatar(member)));
    state.settings = await signedGroupAvatar(state.settings);
    return Response.json(state);
  });
}

export function POST(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { db } = await member(request, id);
    const { action, data } = actionInput.parse(await request.json());
    const result = checked(await db.rpc("pal_action", { p_group_id: id, p_action: action, p_data: data }));
    if (action === "message.reply") after(async () => {
      if (!/@pal\b/i.test((data as { body: string }).body)) await sleep(10500);
      await dispatchJobs();
    });
    return Response.json(result);
  });
}
