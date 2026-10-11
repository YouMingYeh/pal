import { after } from "next/server";
import { member, route } from "../../../../../lib/http";
import { checked } from "../../../../../lib/db";
import { messageInput } from "../../../../../lib/validation";
import { dispatchJobs } from "../../../../../lib/jobs";
import { setTimeout as sleep } from "node:timers/promises";

export const maxDuration = 300;
type Context = { params: Promise<{ id: string }> };

export function GET(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { db } = await member(request, id);
    const latest = checked(await db.from("messages").select("id,group_id,sender_id,role,body,client_id,created_at,reply_to_id,card")
      .eq("group_id", id).or("source_key.is.null,source_key.not.like.weekly:%")
      .order("created_at", { ascending: false }).order("id", { ascending: false }).limit(200));
    return Response.json({ messages: (latest ?? []).reverse().map(({ card, ...message }) => ({ ...message, cards: card ? [card] : [] })) });
  });
}

export function POST(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { db } = await member(request, id);
    const { body, client_id, reply_to_id } = messageInput.parse(await request.json());
    const message = checked(await db.rpc("send_message", { p_group_id: id, p_body: body, p_client_id: client_id,
      ...(reply_to_id ? { p_reply_to_id: reply_to_id } : {}),
    }));
    after(async () => {
      if (!/@pal\b/i.test(body)) await sleep(10500);
      await dispatchJobs();
    });
    return Response.json({ message }, { status: 201 });
  });
}
