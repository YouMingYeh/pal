import { createHash, randomUUID } from "node:crypto";
import { admin, checked } from "./db";
import { avatarForm, normalizeAvatar, AVATAR_MAX_BYTES } from "./avatar";
import { groupInput, id } from "./validation";
import { HttpError } from "./http";

export const groupCreationInput = groupInput.extend({ client_id: id });
type GroupPhoto = Record<string, unknown> & { creator_id: string; avatar_path?: string | null };
const cache = new Map<string, { url: string; until: number }>();

export function ownsGroupPhoto(creator: string, path: string) {
  const uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
  return new RegExp(`^groups/${uuid}/${uuid}\\.jpg$`).test(path) && path.startsWith(`groups/${creator}/`);
}

export async function signedGroupAvatar<T extends GroupPhoto>(group: T) {
  const { avatar_path, ...safe } = group;
  let avatar_url: string | null = null;
  if (avatar_path && ownsGroupPhoto(group.creator_id, avatar_path)) {
    try {
      const cached = cache.get(avatar_path);
      if (cached && cached.until > Date.now()) avatar_url = cached.url;
      else {
        const signed = checked(await admin().storage.from("avatars").createSignedUrl(avatar_path, 3600));
        if (!signed) throw new Error("Unavailable group photo");
        avatar_url = signed.signedUrl;
        if (cache.size >= 1000) cache.delete(cache.keys().next().value!);
        cache.set(avatar_path, { url: avatar_url, until: Date.now() + 50 * 60000 });
      }
    } catch { console.error("Group photo is temporarily unavailable."); }
  }
  return { ...safe, avatar_url };
}

export async function groupCreationForm(request: Request) {
  const form = await avatarForm(request);
  const fields = ["name", "client_id", "file"];
  if ([...form.keys()].some(key => !fields.includes(key)) || fields.some(key => form.getAll(key).length > 1)) throw new HttpError(400, "Choose a group name and an optional photo.");
  const input = groupCreationInput.parse({ name: form.get("name"), client_id: form.get("client_id") });
  const file = form.get("file");
  if (file !== null && (!(file instanceof File) || !file.size)) throw new HttpError(400, "Choose a photo.");
  if (file instanceof File && file.size > AVATAR_MAX_BYTES) throw new HttpError(413, "Choose a photo smaller than 5 MB.");
  return { input, file: file as File | null };
}

export async function createGroupWithPhoto(owner: string, input: { name: string; client_id: string }, file?: File | null) {
  const db = admin();
  let path: string | null = null, hash: string | null = null;
  if (file) {
    const source = Buffer.from(await file.arrayBuffer());
    const bytes = await normalizeAvatar(source, file.type);
    hash = createHash("sha256").update(source).digest("hex");
    path = `groups/${owner}/${randomUUID()}.jpg`;
    checked(await db.storage.from("avatars").upload(path, bytes, { contentType: "image/jpeg", cacheControl: "3600", upsert: false }));
  }
  const args = { p_user_id: owner, p_client_id: input.client_id, p_name: input.name, p_avatar_path: path, p_sha256: hash };
  let result: { group: GroupPhoto; uploaded_path_used: boolean };
  try { result = checked(await db.rpc("pal_group_create", args)); }
  catch (error) {
    // Repeat the exact operation under its creation lock when a response may have
    // been lost; this proves the blob's disposition before attempting cleanup.
    const retry = await db.rpc("pal_group_create", args);
    if (!retry.error && retry.data) result = retry.data;
    else {
      if (path && retry.error?.code === "22023") await cleanupGroupPhoto(owner, path);
      throw error;
    }
  }
  if (path && !result.uploaded_path_used) await cleanupGroupPhoto(owner, path);
  return signedGroupAvatar(result.group);
}

async function cleanupGroupPhoto(owner: string, path: string) {
  if (!ownsGroupPhoto(owner, path)) return;
  try { const result = await admin().storage.from("avatars").remove([path]); if (result.error) throw result.error; }
  catch { console.error("An unused group photo could not be cleaned up."); }
}
