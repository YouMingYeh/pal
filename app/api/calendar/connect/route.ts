import { beginGoogleConnection } from "../../../../lib/calendar";
import { authenticated, route } from "../../../../lib/http";

export async function GET(request: Request) {
  return route(async () => {
    const { user } = await authenticated(request);
    return Response.json({ url: await beginGoogleConnection(user.id) }, { headers: { "cache-control": "no-store" } });
  });
}
