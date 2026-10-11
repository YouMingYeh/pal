import { authenticated, route } from "../../../lib/http";
import { checked } from "../../../lib/db";
import { groupInput } from "../../../lib/validation";
import { createGroupWithPhoto, groupCreationForm, groupCreationInput, signedGroupAvatar } from "../../../lib/group-avatar";

export function GET(request: Request) {
  return route(async () => {
    const { db } = await authenticated(request);
    const groups = checked(await db.rpc("pal_inbox")) as Parameters<typeof signedGroupAvatar>[0][];
    return Response.json({ groups: await Promise.all(groups.map(group => signedGroupAvatar(group))) });
  });
}

export function POST(request: Request) {
  return route(async () => {
    const { db, user } = await authenticated(request);
    if (request.headers.get("content-type")?.toLowerCase().startsWith("multipart/form-data;")) {
      const { input, file } = await groupCreationForm(request);
      return Response.json({ group: await createGroupWithPhoto(user.id, input, file) }, { status: 201 });
    }
    const body = await request.json();
    if (body?.client_id !== undefined) {
      const input = groupCreationInput.parse(body);
      return Response.json({ group: await createGroupWithPhoto(user.id, input) }, { status: 201 });
    }
    const { name } = groupInput.parse(body);
    return Response.json({ group: await signedGroupAvatar(checked(await db.rpc("create_group", { p_name: name }))) }, { status: 201 });
  });
}
