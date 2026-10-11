import sharp from "sharp";
import { randomUUID } from "node:crypto";
import { admin, checked } from "./db";
import { HttpError } from "./http";

export const AVATAR_MAX_BYTES = 5 * 1024 * 1024;
const maxPixels = 25_000_000;
const maxDimension = 8192;
const signedTTL = 3600;
const signedCache = new Map<string, { url: string; refreshAt: number }>();
const photoPath = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/;

export function ownsAvatarPath(owner: string, path: string) {
  return photoPath.test(path) && path.startsWith(`${owner.toLowerCase()}/`);
}

function rasterFormat(data: Buffer) {
  if (data.length >= 3 && data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff) return "jpeg";
  if (data.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return "png";
  if (data.length >= 12 && data.toString("ascii", 0, 4) === "RIFF" && data.toString("ascii", 8, 12) === "WEBP") return "webp";
  return null;
}

export async function normalizeAvatar(data: Buffer, mime: string) {
  if (data.length > AVATAR_MAX_BYTES) throw new HttpError(413, "Choose a photo smaller than 5 MB.");
  const expected = { "image/jpeg": "jpeg", "image/png": "png", "image/webp": "webp" }[mime];
  if (!expected || rasterFormat(data) !== expected) throw new HttpError(400, "Choose a JPEG, PNG, or WebP photo.");
  try {
    const image = sharp(data, { limitInputPixels: maxPixels, failOn: "warning", sequentialRead: true });
    const metadata = await image.metadata();
    if (metadata.format !== expected || !metadata.width || !metadata.height
      || metadata.width > maxDimension || metadata.height > maxDimension || (metadata.pages ?? 1) !== 1) {
      throw new Error("Invalid photo dimensions or animation");
    }
    // Decode, auto-orient and re-encode rather than trusting a filename or carrying EXIF/location metadata.
    return await image.autoOrient().resize(1024, 1024, { fit: "inside", withoutEnlargement: true })
      .toColourspace("srgb").flatten({ background: "white" }).jpeg({ quality: 82, mozjpeg: true })
      .timeout({ seconds: 10 }).toBuffer();
  } catch {
    throw new HttpError(400, "This photo could not be read. Choose a still photo up to 8192 pixels per side.");
  }
}

export async function avatarForm(request: Request) {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("multipart/form-data;")) throw new HttpError(400, "Send a photo file.");
  if (!request.body) throw new HttpError(400, "Choose a photo.");
  const limit = AVATAR_MAX_BYTES + 64 * 1024;
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) { await reader.cancel(); throw new HttpError(413, "Choose a photo smaller than 5 MB."); }
    chunks.push(value);
  }
  try {
    const copy = new Request(request.url, { method: "POST", headers: { "Content-Type": contentType }, body: Buffer.concat(chunks) });
    return await copy.formData();
  } catch { throw new HttpError(400, "Send a valid photo file."); }
}

type Profile = Record<string, unknown> & { user_id: string; avatar_path?: string | null; avatar_url?: string | null; _previous_avatar_path?: string | null };
async function signPhoto(path: string) {
  const signed = checked(await admin().storage.from("avatars").createSignedUrl(path, signedTTL));
  if (!signed) throw new Error("Could not load profile photo.");
  return signed.signedUrl;
}

export async function signedAvatar<T extends Profile>(profile: T, required = false, sign = signPhoto) {
  const { avatar_path, _previous_avatar_path, ...safe } = profile;
  if (!avatar_path) return { ...safe, avatar_url: profile.avatar_url ?? null };
  try {
    if (!ownsAvatarPath(profile.user_id, avatar_path)) throw new Error("Stored avatar ownership is invalid.");
    const cached = signedCache.get(avatar_path);
    if (cached && cached.refreshAt > Date.now()) return { ...safe, avatar_url: cached.url };
    const url = await sign(avatar_path);
    if (signedCache.size >= 1000) signedCache.delete(signedCache.keys().next().value!);
    signedCache.set(avatar_path, { url, refreshAt: Date.now() + (signedTTL - 600) * 1000 });
    return { ...safe, avatar_url: url };
  } catch (error) {
    console.error("Profile photo is temporarily unavailable.");
    if (required) throw error;
    return { ...safe, avatar_url: null };
  }
}

export async function removeAvatarObject(owner: string, path: string | null | undefined) {
  if (!path || !ownsAvatarPath(owner, path)) return;
  signedCache.delete(path);
  const { error } = await admin().storage.from("avatars").remove([path]);
  if (error) console.error("Old profile photo cleanup could not finish.");
}

export async function replaceAvatar(userId: string, image: Buffer | null, displayName?: string) {
  const db = admin();
  const path = image ? `${userId}/${randomUUID()}.jpg` : null;
  if (path && image) checked(await db.storage.from("avatars").upload(path, image, {
    contentType: "image/jpeg", cacheControl: "3600", upsert: false,
  }));
  let result: { profile: Profile; previous_path: string | null };
  try {
    result = checked(await db.rpc("pal_avatar_replace", {
      p_user_id: userId, p_avatar_path: path, p_display_name: displayName ?? null,
    }));
  } catch (error) {
    // A lost response may follow a committed profile update. Never delete its active photo.
    if (path) {
      const observed = await db.from("profiles").select("*").eq("user_id", userId).maybeSingle();
      if (!observed.error && observed.data?.avatar_path === path) return signedAvatar(observed.data as Profile, true);
      if (!observed.error) await removeAvatarObject(userId, path);
    }
    throw error;
  }
  await removeAvatarObject(userId, result.previous_path);
  return signedAvatar(result.profile, Boolean(image));
}
