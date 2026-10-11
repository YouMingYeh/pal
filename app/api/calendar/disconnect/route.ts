import { disconnectGoogle } from "../../../../lib/calendar";
import { authenticated, route } from "../../../../lib/http";

export async function DELETE(request: Request) {
  return route(async () => {
    const { user } = await authenticated(request);
    await disconnectGoogle(user.id);
    return Response.json({ connected: false });
  });
}
