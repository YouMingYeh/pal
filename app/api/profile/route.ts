import { authenticated, route } from "../../../lib/http";
import { checked } from "../../../lib/db";
import { profileInput } from "../../../lib/validation";

export function GET(request: Request) {
  return route(async () => {
    const { db, user } = await authenticated(request);
    let profile = checked(await db.from("profiles").select("user_id,display_name,avatar_url,notification_preferences,notifications_enabled").eq("user_id", user.id).maybeSingle());
    if (!profile) profile = checked(await db.rpc("pal_profile_save", { p_data: {} }));
    return Response.json({ profile });
  });
}

export function PATCH(request: Request) {
  return route(async () => {
    const { db } = await authenticated(request);
    const data = profileInput.parse(await request.json());
    return Response.json({ profile: checked(await db.rpc("pal_profile_save", { p_data: data })) });
  });
}
