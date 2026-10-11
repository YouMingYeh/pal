import { after } from "next/server";
import { member, route, HttpError } from "../../../../../lib/http";
import { admin, checked } from "../../../../../lib/db";
import { demoLines, promptsForDemo, demoRequest, runDemoScenes } from "../../../../../lib/demo";
import { dispatchJobs } from "../../../../../lib/jobs";

type Context = { params: Promise<{ id: string }> };
export const maxDuration = 300;
export function POST(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { user } = await member(request, id);
    const input = demoRequest.parse(await request.json());
    const db = admin();
    if (input.action === "reset") {
      const demo = checked(await db.rpc("pal_demo_reset", { p_group_id: id, p_user_id: user.id }));
      return Response.json({ demo });
    }
    const state = checked(await db.rpc("pal_group_state", { p_group_id: id }));
    if (!state.demo) throw new HttpError(400, "This conversation does not offer a suggested sequence.");
    const kind = state.demo.kind ?? "plan";
    if (input.body !== promptsForDemo(kind)[input.step]) throw new HttpError(400, "Refresh the suggested message.");
    const cast = checked(await db.rpc("pal_demo_cast", { p_group_id: id, p_user_id: user.id })) as string[];
    const lines = demoLines(input.step, cast, kind);
    const message = checked(await db.rpc("pal_demo_begin", { p_group_id: id, p_user_id: user.id, p_step: input.step,
      p_generation: input.generation, p_client_id: input.client_id, p_body: input.body, p_lines: lines }));
    after(async () => { await runDemoScenes(id, lines.length); await dispatchJobs(); });
    return Response.json({ message }, { status: 201 });
  });
}
