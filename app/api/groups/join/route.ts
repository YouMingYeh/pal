import { authenticated, route } from "../../../../lib/http";
import { checked } from "../../../../lib/db";
import { joinInput } from "../../../../lib/validation";
import { signedGroupAvatar } from "../../../../lib/group-avatar";

export function POST(request: Request) {
  return route(async () => {
    const { db } = await authenticated(request);
    const { invite_code } = joinInput.parse(await request.json());
    return Response.json({ group: await signedGroupAvatar(checked(await db.rpc("join_group", { p_invite_code: invite_code }))) });
  });
}
