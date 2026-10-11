import { after } from "next/server";
import { member, route } from "../../../../../lib/http";
import { checked } from "../../../../../lib/db";
import { messageInput } from "../../../../../lib/validation";
import { dispatchJobs } from "../../../../../lib/jobs";
import { setTimeout as sleep } from "node:timers/promises";
import { signedAttachment } from "../../../../../lib/attachments";

export const maxDuration = 300;
type Context = { params: Promise<{ id: string }> };

export function GET(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { db } = await member(request, id);
    const latest = checked(await db.from("messages").select("id,group_id,sender_id,role,body,client_id,created_at,reply_to_id,card,emotion")
      .eq("group_id", id).or("source_key.is.null,source_key.not.like.weekly:%")
      .order("created_at", { ascending: false }).order("id", { ascending: false }).limit(200));
    const attachmentRows = latest?.length ? checked(await db.from("message_attachments").select("*")
      .eq("group_id", id).in("message_id", latest.map(message => message.id))) ?? [] : [];
    const attachments = new Map(await Promise.all(attachmentRows.map(async attachment => [attachment.message_id, await signedAttachment(attachment)] as const)));
    return Response.json({ messages: (latest ?? []).reverse().map(({ card, ...message }) => ({ ...message, cards: card ? [card] : [], attachments: attachments.has(message.id) ? [attachments.get(message.id)] : [] })) });
  });
}

export function POST(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { db } = await member(request, id);
    const group = checked(await db.from("groups").select("is_direct").eq("id", id).single());
    const { body, client_id, reply_to_id } = messageInput.parse(await request.json());
    const message = checked(await db.rpc("send_message", { p_group_id: id, p_body: body, p_client_id: client_id,
      ...(reply_to_id ? { p_reply_to_id: reply_to_id } : {}),
    }));
    after(async () => {
      if (!group?.is_direct && !/@pal\b/i.test(body)) await sleep(10500);
      await dispatchJobs();
    });
    return Response.json({ message }, { status: 201 });
  });
}
