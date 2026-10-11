import { test } from "node:test";
import assert from "node:assert/strict";
import sharp from "sharp";
import { attachmentForm, attachmentInput, normalizeAttachment, ownsAttachmentPath } from "../lib/attachments";

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
