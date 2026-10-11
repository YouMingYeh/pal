import { createHash, randomUUID } from "node:crypto";
import sharp from "sharp";
import { z } from "zod";
import { admin, checked } from "./db";
import { HttpError } from "./http";
import { normalizeAvatar } from "./avatar";
import { inspectAudio } from "./audio";
import { id } from "./validation";

export const ATTACHMENT_MAX_BYTES = 4 * 1024 * 1024;
export const attachmentInput = z.object({
  kind: z.enum(["image", "audio"]), client_id: id,
  body: z.string().trim().max(4000).optional(), reply_to_id: id.optional(),
}).strict();
type Input = z.infer<typeof attachmentInput>;
type Attachment = { id: string; group_id: string; message_id: string; uploader_id: string; client_id: string; object_path: string; input_sha256: string; kind: "image" | "audio"; mime_type: string; byte_size: number; width: number | null; height: number | null; duration_ms: number | null };
const signed = new Map<string, { url: string; until: number }>();

export function ownsAttachmentPath(group: string, owner: string, path: string) {
  const uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
  return new RegExp(`^${uuid}/${uuid}/${uuid}\\.(jpg|m4a)$`).test(path) && path.startsWith(`${group}/${owner}/`);
}

export async function attachmentForm(request: Request) {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("multipart/form-data;") || !request.body) throw new HttpError(400, "Choose a photo or voice recording.");
  const chunks: Uint8Array[] = []; let size = 0;
  const reader = request.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > ATTACHMENT_MAX_BYTES + 64 * 1024) { await reader.cancel(); throw new HttpError(413, "Choose a file smaller than 4 MB."); }
    chunks.push(value);
  }
  let form: FormData;
  try { form = await new Request(request.url, { method: "POST", headers: { "Content-Type": contentType }, body: Buffer.concat(chunks) }).formData(); }
  catch { throw new HttpError(400, "Send a valid photo or voice recording."); }
  const fields = ["file", "kind", "client_id", "body", "reply_to_id"];
  if ([...form.keys()].some(key => !fields.includes(key)) || fields.some(key => form.getAll(key).length > 1)) throw new HttpError(400, "Send one file with a message ID.");
  const file = form.get("file");
  if (!(file instanceof File) || !file.size) throw new HttpError(400, "Choose a photo or voice recording.");
  if (file.size > ATTACHMENT_MAX_BYTES) throw new HttpError(413, "Choose a file smaller than 4 MB.");
  const input = attachmentInput.parse(Object.fromEntries([...form.entries()].filter(([key]) => key !== "file")));
  return { input, file };
}

export async function normalizeAttachment(file: File, kind: Input["kind"]) {
  const source = Buffer.from(await file.arrayBuffer());
  if (!source.length || source.length > ATTACHMENT_MAX_BYTES) throw new HttpError(413, "Choose a file smaller than 4 MB.");
  const hash = createHash("sha256").update(source).digest("hex");
  if (kind === "audio") return { bytes: source, hash, mime_type: "audio/mp4", width: null, height: null, ...inspectAudio(source, file.type) };
  const bytes = await normalizeAvatar(source, file.type), metadata = await sharp(bytes).metadata();
  return { bytes, hash, mime_type: "image/jpeg", width: metadata.width!, height: metadata.height!, duration_ms: null };
}

export async function signedAttachment(row: Attachment) {
  let url: string | null = null;
  if (ownsAttachmentPath(row.group_id, row.uploader_id, row.object_path)) {
    try {
      const cached = signed.get(row.object_path);
      if (cached && cached.until > Date.now()) url = cached.url;
      else {
        const data = checked(await admin().storage.from("message-attachments").createSignedUrl(row.object_path, 3600));
        if (!data) throw new Error("Unavailable attachment");
        url = data.signedUrl;
        if (signed.size >= 1000) signed.delete(signed.keys().next().value!);
        signed.set(row.object_path, { url, until: Date.now() + 50 * 60000 });
      }
    } catch { console.error("A chat attachment is temporarily unavailable."); }
  }
  return { id: row.id, kind: row.kind, url, mime_type: row.mime_type, byte_size: row.byte_size, width: row.width, height: row.height, duration_ms: row.duration_ms };
}

async function removeUnused(group: string, owner: string, path: string) {
  if (!ownsAttachmentPath(group, owner, path)) return;
  try { const result = await admin().storage.from("message-attachments").remove([path]); if (result.error) throw result.error; }
  catch { console.error("An unused attachment could not be cleaned up."); }
}

export async function sendAttachment(group: string, owner: string, input: Input, file: File) {
  const media = await normalizeAttachment(file, input.kind), db = admin();
  const existing = checked(await db.from("message_attachments").select("*").eq("group_id", group).eq("uploader_id", owner).eq("client_id", input.client_id).maybeSingle()) as Attachment | null;
  // A replay passes through the authoritative RPC without uploading another blob.
  const path = existing?.object_path ?? `${group}/${owner}/${randomUUID()}.${input.kind === "image" ? "jpg" : "m4a"}`;
  if (!existing) checked(await db.storage.from("message-attachments").upload(path, media.bytes, { contentType: media.mime_type, cacheControl: "3600", upsert: false }));
  let result: { message: Record<string, unknown>; attachment: Attachment; uploaded_path_used: boolean };
  const args = {
    p_group_id: group, p_user_id: owner, p_client_id: input.client_id, p_object_path: path,
    p_kind: input.kind, p_mime_type: media.mime_type, p_byte_size: media.bytes.length,
    p_width: media.width, p_height: media.height, p_duration_ms: media.duration_ms,
    p_sha256: media.hash, p_body: input.body || null, p_reply_to_id: input.reply_to_id ?? null,
  };
  try {
    result = checked(await db.rpc("send_attachment", args));
  } catch (error) {
    // A second identical call waits on the same SQL group lock, so a lost response
    // cannot cause cleanup to race a still-committing message transaction.
    const retry = await db.rpc("send_attachment", args);
    if (!retry.error && retry.data) result = retry.data;
    else {
      if (!existing && retry.error?.code === "22023") await removeUnused(group, owner, path);
      throw error;
    }
  }
  if (!existing && !result.uploaded_path_used) await removeUnused(group, owner, path);
  return { message: { ...result.message, attachments: [await signedAttachment(result.attachment)] } };
}
