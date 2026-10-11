import { authenticated, route } from "../../../lib/http";
import { checked } from "../../../lib/db";
import { deviceInput } from "../../../lib/validation";

function device(request: Request, remove: boolean) {
  return route(async () => {
    const { db } = await authenticated(request);
    const { token, environment } = deviceInput.parse(await request.json());
    return Response.json(checked(await db.rpc(remove ? "pal_device_delete" : "pal_device_register", {
      p_token: token.toLowerCase(), p_environment: environment,
    })));
  });
}
export function POST(request: Request) { return device(request, false); }
export function DELETE(request: Request) { return device(request, true); }
