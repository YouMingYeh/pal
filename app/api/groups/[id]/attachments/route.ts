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
    const { input, file } = await attachmentForm(request);
    const result = await sendAttachment(id, user.id, input, file);
    after(async () => {
      let addressedToPal = /@pal\b/i.test(input.body ?? "") || input.mentions?.some(mention => mention.type === "pal");
      if (!addressedToPal) {
        try {
          const [group, reply] = await Promise.all([
            db.from("groups").select("is_direct").eq("id", id).single().then(checked),
            input.reply_to_id ? db.from("messages").select("role").eq("group_id", id).eq("id", input.reply_to_id).maybeSingle().then(checked) : null,
          ]);
          addressedToPal = group?.is_direct || reply?.role === "pal";
        } catch { console.error("Pal response routing could not refresh; the saved message remains queued."); }
      }
      if (!addressedToPal) await sleep(3500);
      await dispatchJobs();
    });
    return Response.json(result, { status: 201 });
  });
}
