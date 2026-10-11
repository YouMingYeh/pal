import { authenticated, HttpError, route } from "../../../../lib/http";
import { avatarForm, normalizeAvatar, replaceAvatar, AVATAR_MAX_BYTES } from "../../../../lib/avatar";
import { profileInput } from "../../../../lib/validation";

export const runtime = "nodejs";
export const maxDuration = 30;

export function POST(request: Request) {
  return route(async () => {
    const { user } = await authenticated(request);
    const form = await avatarForm(request);
    if ([...form.keys()].some(key => !["file", "display_name"].includes(key))
      || form.getAll("file").length !== 1 || form.getAll("display_name").length > 1) {
      throw new HttpError(400, "Send one photo and an optional display name.");
    }
    const file = form.get("file");
    if (!(file instanceof File)) throw new HttpError(400, "Choose a photo.");
    if (file.size > AVATAR_MAX_BYTES) throw new HttpError(413, "Choose a photo smaller than 5 MB.");
    const name = form.get("display_name");
    const displayName = name === null ? undefined : profileInput.shape.display_name.parse(name);
    const image = await normalizeAvatar(Buffer.from(await file.arrayBuffer()), file.type);
    return Response.json({ profile: await replaceAvatar(user.id, image, displayName) });
  });
}

export function DELETE(request: Request) {
  return route(async () => {
    const { user } = await authenticated(request);
    return Response.json({ profile: await replaceAvatar(user.id, null) });
  });
}
