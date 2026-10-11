import { test } from "node:test";
import assert from "node:assert/strict";
import sharp from "sharp";
import { attachmentForm, attachmentInput, normalizeAttachment, ownsAttachmentPath, sendAttachment } from "../lib/attachments";

test("attachment identities stay scoped to their authenticated group and speaker", () => {
  const group = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", owner = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", blob = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  assert.equal(ownsAttachmentPath(group, owner, `${group}/${owner}/${blob}.m4a`), true);
  assert.equal(ownsAttachmentPath(owner, group, `${group}/${owner}/${blob}.jpg`), false);
  assert.equal(ownsAttachmentPath(group, owner, `${group}/${owner}/../${blob}.jpg`), false);
  assert.throws(() => attachmentInput.parse({ kind: "image", client_id: blob, uploader_id: owner }));
});

test("photo attachments are reencoded with dimensions and stable source identity", async () => {
  const png = await sharp({ create: { width: 1600, height: 800, channels: 3, background: "red" } }).png().toBuffer();
  const file = new File([png], "camera.png", { type: "image/png" });
  const first = await normalizeAttachment(file, "image"), retry = await normalizeAttachment(file, "image");
  assert.equal(first.width, 1024); assert.equal(first.height, 512);
  assert.equal(first.mime_type, "image/jpeg"); assert.equal(first.duration_ms, null);
  assert.equal(first.hash, retry.hash); assert.deepEqual(first.bytes, retry.bytes);
});

test("multipart chat uploads reject forged ownership, duplicate fields and unsupported files", async () => {
  const create = () => new Request("https://pal.example/api/groups/one/attachments", { method: "POST", body: form });
  const form = new FormData();
  form.set("file", new File(["photo"], "camera.jpg", { type: "image/jpeg" }));
  form.set("kind", "image"); form.set("client_id", "cccccccc-cccc-4ccc-8ccc-cccccccccccc");
  assert.equal((await attachmentForm(create())).input.kind, "image");
  form.set("uploader_id", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
  await assert.rejects(attachmentForm(create()));
  form.delete("uploader_id"); form.append("kind", "audio");
  await assert.rejects(attachmentForm(create()));
  await assert.rejects(normalizeAttachment(new File(["not a JPEG"], "camera.jpg", { type: "image/jpeg" }), "image"));
});


test("photo decoding overlaps the scoped replay lookup without publishing before the RPC commits", async () => {
  const originalFetch = globalThis.fetch;
  const originalURL = process.env.SUPABASE_URL, originalKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  process.env.SUPABASE_URL = "https://attachment-query.test.supabase.co";
  process.env.SUPABASE_SERVICE_ROLE_KEY = "attachment-query-tests-service-role";
  const group = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", owner = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const client = "cccccccc-cccc-4ccc-8ccc-cccccccccccc", message = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
  const bytes = await sharp({ create: { width: 32, height: 32, channels: 3, background: "red" } }).png().toBuffer();
  const file = new File([bytes], "photo.png", { type: "image/png" });
  let finishDecoding: (data: ArrayBuffer) => void = () => assert.fail("Decoding did not start");
  Object.defineProperty(file, "arrayBuffer", { value: () => new Promise<ArrayBuffer>(resolve => { finishDecoding = resolve; }) });
  let lookupStarted: () => void = () => assert.fail("Replay lookup did not start");
  const lookup = new Promise<void>(resolve => { lookupStarted = resolve; });
  let committed = false, uploads = 0, signs = 0;
  globalThis.fetch = async (input, init) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    assert.equal(url.hostname, "attachment-query.test.supabase.co");
    const response = (value: unknown) => new Response(JSON.stringify(value), { headers: { "content-type": "application/json" } });
    if (url.pathname === "/rest/v1/message_attachments") {
      assert.equal(url.searchParams.get("select"), "object_path");
      assert.equal(url.searchParams.get("group_id"), `eq.${group}`);
      assert.equal(url.searchParams.get("uploader_id"), `eq.${owner}`);
      assert.equal(url.searchParams.get("client_id"), `eq.${client}`);
      lookupStarted();
      return response(null);
    }
    if (url.pathname.startsWith("/storage/v1/object/sign/")) {
      assert.equal(committed, true, "The file URL must refer to a successfully committed message.");
      signs++;
      return response({ signedURL: url.pathname.replace("/storage/v1", "") + "?token=test" });
    }
    if (url.pathname.startsWith("/storage/v1/object/")) { uploads++; return response({ Key: url.pathname }); }
    assert.equal(url.pathname, "/rest/v1/rpc/send_attachment_with_mentions");
    const args = JSON.parse(String(init?.body));
    committed = true;
    return response({ uploaded_path_used: true, message: { id: message, group_id: group, role: "user", body: "Look at this" },
      attachment: { id: client, group_id: group, message_id: message, uploader_id: owner, client_id: client, object_path: args.p_object_path,
        input_sha256: args.p_sha256, kind: args.p_kind, mime_type: args.p_mime_type, byte_size: args.p_byte_size, width: args.p_width, height: args.p_height, duration_ms: null } });
  };
  try {
    const sending = sendAttachment(group.toUpperCase(), owner.toUpperCase(), { kind: "image", client_id: client, body: "Look at this" }, file);
    await Promise.race([lookup, new Promise<never>((_, reject) => setTimeout(() => reject(new Error("Lookup waited for decoding")), 1000))]);
    assert.equal(committed, false);
    finishDecoding(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    const result = await sending;
    assert.equal((result.message as Record<string, unknown>).id, message);
    assert.equal(uploads, 1); assert.equal(signs, 1);
  } finally {
    globalThis.fetch = originalFetch;
    if (originalURL === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = originalURL;
    if (originalKey === undefined) delete process.env.SUPABASE_SERVICE_ROLE_KEY; else process.env.SUPABASE_SERVICE_ROLE_KEY = originalKey;
  }
});
