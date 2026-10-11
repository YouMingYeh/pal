import { googleConnectionStatus } from "../../../../lib/calendar";
import { authenticated, route } from "../../../../lib/http";

export async function GET(request: Request) {
  return route(async () => {
    const { user } = await authenticated(request);
    return Response.json(await googleConnectionStatus(user.id), { headers: { "cache-control": "no-store" } });
  });
}
