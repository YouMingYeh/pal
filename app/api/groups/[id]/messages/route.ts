import { after } from "next/server";
import { member, route } from "../../../../../lib/http";
import { checked } from "../../../../../lib/db";
import { messageInput } from "../../../../../lib/validation";
import { dispatchJobs } from "../../../../../lib/jobs";

export const maxDuration = 300;
type Context = { params: Promise<{ id: string }> };

export function GET(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { db } = await member(request, id);
    const latest = checked(await db.from("messages").select("id,group_id,sender_id,role,body,created_at")
      .eq("group_id", id).order("created_at", { ascending: false }).limit(200));
    return Response.json({ messages: (latest ?? []).reverse() });
  });
}

export function POST(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { db } = await member(request, id);
    const { body, client_id } = messageInput.parse(await request.json());
    const message = checked(await db.rpc("send_message", { p_group_id: id, p_body: body, p_client_id: client_id }));
    if (/@pal\b/i.test(body)) after(async () => { await dispatchJobs(); });
    return Response.json({ message }, { status: 201 });
  });
}
