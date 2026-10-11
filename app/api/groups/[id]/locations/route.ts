import { checked } from "../../../../../lib/db";
import { member, route } from "../../../../../lib/http";
import { locationInput } from "../../../../../lib/locations";

type Context = { params: Promise<{ id: string }> };

export function POST(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { db } = await member(request, id);
    const location = locationInput.parse(await request.json());
    return Response.json(checked(await db.rpc("pal_group_location", { p_group_id: id, p_location: location })),
      { headers: { "cache-control": "private, no-store" } });
  });
}

export function DELETE(request: Request, context: Context) {
  return route(async () => {
    const { id } = await context.params;
    const { db } = await member(request, id);
    return Response.json(checked(await db.rpc("pal_group_location", { p_group_id: id, p_location: null })),
      { headers: { "cache-control": "private, no-store" } });
  });
}
