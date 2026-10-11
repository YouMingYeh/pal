import { after } from "next/server";
import { authenticated, member, route } from "../../../../../lib/http";
import { checked } from "../../../../../lib/db";
import { actionInput, id as groupID } from "../../../../../lib/validation";
import { dispatchJobs } from "../../../../../lib/jobs";
import { setTimeout as sleep } from "node:timers/promises";
import { signedAvatar } from "../../../../../lib/avatar";
import { signedGroupAvatar } from "../../../../../lib/group-avatar";

export const maxDuration = 300;
type Context = { params: Promise<{ id: string }> };

export function GET(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    groupID.parse(id);
    const { db } = await authenticated(request);
    // The RPC checks current membership atomically before returning any group data.
    const state = checked(await db.rpc("pal_group_state", { p_group_id: id }));
    [state.members, state.settings] = await Promise.all([
      Promise.all(state.members.map((member: Parameters<typeof signedAvatar>[0]) => signedAvatar(member))),
      signedGroupAvatar(state.settings),
    ]);
    return Response.json(state);
  });
}

export function POST(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { db } = await member(request, id);
    const { action, data } = actionInput.parse(await request.json());
    const result = checked(await db.rpc("pal_action", { p_group_id: id, p_action: action, p_data: data }));
    if (action === "message.reply") {
      after(async () => {
        const message = data as { body: string; reply_to_id: string; mentions?: { type: string }[] };
        let addressedToPal = /@pal\b/i.test(message.body) || message.mentions?.some(mention => mention.type === "pal");
        if (!addressedToPal) {
          try {
            const [group, reply] = await Promise.all([
              db.from("groups").select("is_direct").eq("id", id).single().then(checked),
              db.from("messages").select("role").eq("group_id", id).eq("id", message.reply_to_id).maybeSingle().then(checked),
            ]);
            addressedToPal = group?.is_direct || reply?.role === "pal";
          } catch { console.error("Pal response routing could not refresh; the saved message remains queued."); }
        }
        if (!addressedToPal) await sleep(3500);
        await dispatchJobs();
      });
    }
    return Response.json(result);
  });
}
