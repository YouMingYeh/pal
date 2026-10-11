import { authenticated, route } from "../../../lib/http";
import { checked } from "../../../lib/db";
import { groupInput } from "../../../lib/validation";

export function GET(request: Request) {
  return route(async () => {
    const { db } = await authenticated(request);
    const groups = checked(await db.from("groups").select("id,name,invite_code").order("created_at"));
    return Response.json({ groups });
  });
}

export function POST(request: Request) {
  return route(async () => {
    const { db } = await authenticated(request);
    const { name } = groupInput.parse(await request.json());
    return Response.json({ group: checked(await db.rpc("create_group", { p_name: name })) }, { status: 201 });
  });
}
