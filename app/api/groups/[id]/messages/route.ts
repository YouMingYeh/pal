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
    const latest = checked(await db.from("messages").select("id,group_id,sender_id,role,body,client_id,created_at,reply_to_id,mentions,card,emotion")
      .eq("group_id", id).or("source_key.is.null,source_key.not.like.weekly:%")
      .order("created_at", { ascending: false }).order("id", { ascending: false }).limit(200));
    const replyIds = [...new Set((latest ?? []).map(message => message.reply_to_id).filter((value): value is string => typeof value === "string"))];
    const [attachmentRows, replyRows] = await Promise.all([
      latest?.length ? db.from("message_attachments").select("*").eq("group_id", id).in("message_id", latest.map(message => message.id)).then(checked) : [],
      replyIds.length ? db.from("messages").select("id,sender_id,role,body").eq("group_id", id).in("role", ["user", "pal"]).in("id", replyIds).then(checked) : [],
    ]);
    const replies = new Map((replyRows ?? []).map(reply => [reply.id, { ...reply, body: reply.body.slice(0, 500) }]));
    const attachments = new Map(await Promise.all((attachmentRows ?? []).map(async attachment => [attachment.message_id, await signedAttachment(attachment)] as const)));
    return Response.json({ messages: (latest ?? []).reverse().map(({ card, ...message }) => ({ ...message, mentions: message.mentions ?? [],
      reply: message.reply_to_id ? replies.get(message.reply_to_id) ?? null : null, cards: card ? [card] : [], attachments: attachments.has(message.id) ? [attachments.get(message.id)] : [] })) });
  });
}

export function POST(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { db } = await member(request, id);
    const group = checked(await db.from("groups").select("is_direct").eq("id", id).single());
    const { body, client_id, reply_to_id, mentions } = messageInput.parse(await request.json());
    const message = checked(await db.rpc("send_message", { p_group_id: id, p_body: body, p_client_id: client_id,
      p_reply_to_id: reply_to_id ?? null, p_mentions: mentions ?? [],
    }));
    after(async () => {
      let addressedToPal = /@pal\b/i.test(body) || mentions?.some(mention => mention.type === "pal");
      if (!group?.is_direct && !addressedToPal && reply_to_id) addressedToPal = checked(await db.from("messages").select("role")
        .eq("group_id", id).eq("id", reply_to_id).maybeSingle())?.role === "pal";
      if (!group?.is_direct && !addressedToPal) await sleep(10500);
      await dispatchJobs();
    });
    return Response.json({ message }, { status: 201 });
  });
}
