import { authenticated, route } from "../../../lib/http";
import { checked } from "../../../lib/db";
import { profileInput } from "../../../lib/validation";
import { removeAvatarObject, signedAvatar } from "../../../lib/avatar";

export function GET(request: Request) {
  return route(async () => {
    const { db, user } = await authenticated(request);
    let profile = checked(await db.from("profiles").select("user_id,display_name,avatar_url,avatar_path,notification_preferences,notifications_enabled").eq("user_id", user.id).maybeSingle());
    if (!profile) profile = checked(await db.rpc("pal_profile_save", { p_data: {} }));
    if (!profile) throw new Error("Could not load profile.");
    return Response.json({ profile: await signedAvatar(profile) });
  });
}

export function PATCH(request: Request) {
  return route(async () => {
    const { db, user } = await authenticated(request);
    const data = profileInput.parse(await request.json());
    const profile = checked(await db.rpc("pal_profile_save", { p_data: data }));
    await removeAvatarObject(user.id, profile._previous_avatar_path);
    return Response.json({ profile: await signedAvatar(profile) });
  });
}
