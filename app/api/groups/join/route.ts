import { authenticated, route } from "../../../../lib/http";
import { checked } from "../../../../lib/db";
import { joinInput } from "../../../../lib/validation";

export function POST(request: Request) {
  return route(async () => {
    const { db } = await authenticated(request);
    const { invite_code } = joinInput.parse(await request.json());
    return Response.json({ group: checked(await db.rpc("join_group", { p_invite_code: invite_code })) });
  });
}
