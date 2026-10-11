import { after } from "next/server";
import { setTimeout as sleep } from "node:timers/promises";
import { member, route } from "../../../../../lib/http";
import { attachmentForm, sendAttachment } from "../../../../../lib/attachments";
import { dispatchJobs } from "../../../../../lib/jobs";
import { checked } from "../../../../../lib/db";

export const runtime = "nodejs";
export const maxDuration = 300;
type Context = { params: Promise<{ id: string }> };

export function POST(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { user, db } = await member(request, id);
    const group = checked(await db.from("groups").select("is_direct").eq("id", id).single());
    const { input, file } = await attachmentForm(request);
    const result = await sendAttachment(id, user.id, input, file);
    after(async () => {
      let addressedToPal = /@pal\b/i.test(input.body ?? "") || input.mentions?.some(mention => mention.type === "pal");
      if (!group?.is_direct && !addressedToPal && input.reply_to_id) addressedToPal = checked(await db.from("messages").select("role")
        .eq("group_id", id).eq("id", input.reply_to_id).maybeSingle())?.role === "pal";
      if (!group?.is_direct && !addressedToPal) await sleep(10500);
      await dispatchJobs();
    });
    return Response.json(result, { status: 201 });
  });
}
