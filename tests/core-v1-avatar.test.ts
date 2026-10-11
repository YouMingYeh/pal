import assert from "node:assert/strict";
import { test } from "node:test";
import sharp from "sharp";
import { AVATAR_MAX_BYTES, avatarForm, normalizeAvatar, ownsAvatarPath, signedAvatar } from "../lib/avatar";
import { HttpError } from "../lib/http";

const source = () => sharp({ create: { width: 80, height: 40, channels: 4, background: { r: 240, g: 80, b: 90, alpha: 0.5 } } });
const rejected = (status: number) => (error: unknown) => error instanceof HttpError && error.status === status;

test("photos are fully decoded, oriented, bounded and stripped of metadata", async () => {
  const original = await source().jpeg().withMetadata({ orientation: 6 }).withExif({ IFD0: { Copyright: "Private camera metadata" } }).toBuffer();
  assert.ok((await sharp(original).metadata()).exif);
  const normalized = await normalizeAvatar(original, "image/jpeg");
  const metadata = await sharp(normalized).metadata();
  assert.equal(metadata.format, "jpeg");
  assert.equal(metadata.width, 40);
  assert.equal(metadata.height, 80);
  assert.equal(metadata.exif, undefined);
  assert.equal(metadata.icc, undefined);
  for (const [format, mime] of [["png", "image/png"], ["webp", "image/webp"]] as const) {
    const image = await source().toFormat(format).toBuffer();
    const result = await sharp(await normalizeAvatar(image, mime)).metadata();
    assert.equal(result.format, "jpeg");
    assert.equal(result.hasAlpha, false);
  }
});

test("forged, truncated and oversized photos cannot enter private storage", async () => {
  const png = await source().png().toBuffer();
  await assert.rejects(normalizeAvatar(png, "image/jpeg"), rejected(400));
  await assert.rejects(normalizeAvatar(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"/>'), "image/png"), rejected(400));
  await assert.rejects(normalizeAvatar(Buffer.from([0xff, 0xd8, 0xff, 0x00]), "image/jpeg"), rejected(400));
  await assert.rejects(normalizeAvatar(Buffer.alloc(AVATAR_MAX_BYTES + 1), "image/jpeg"), rejected(413));
  const wide = await sharp({ create: { width: 8193, height: 1, channels: 3, background: "blue" } }).png().toBuffer();
  await assert.rejects(normalizeAvatar(wide, "image/png"), rejected(400));
});

test("multipart uploads have a streaming bound even when content length is missing", async () => {
  const form = new FormData();
  form.set("file", new File([await source().jpeg().toBuffer()], "photo.jpg", { type: "image/jpeg" }));
  form.set("display_name", "Alice");
  const valid = await avatarForm(new Request("https://pal.example/api/profile/avatar", { method: "POST", body: form }));
  assert.equal(valid.get("display_name"), "Alice");
  assert.ok(valid.get("file") instanceof File);
  const oversized = new Request("https://pal.example/api/profile/avatar", {
    method: "POST", headers: { "Content-Type": "multipart/form-data; boundary=photo" },
    body: Buffer.alloc(AVATAR_MAX_BYTES + 65537),
  });
  await assert.rejects(avatarForm(oversized), rejected(413));
});

test("private avatar paths belong to one identity and reject alternate paths", () => {
  const alice = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const bob = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const path = `${alice}/${bob}.jpg`;
  assert.equal(ownsAvatarPath(alice, path), true);
  assert.equal(ownsAvatarPath(bob, path), false);
  assert.equal(ownsAvatarPath(alice, `${alice}/../${bob}.jpg`), false);
  assert.equal(ownsAvatarPath(alice, `https://storage.example/${path}`), false);
  assert.equal(ownsAvatarPath(alice, `${alice}/photo.svg`), false);
});

test("unavailable photos cannot break chat state or leak another member's object path", async () => {
  const owner = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  const path = `${owner}/dddddddd-dddd-4ddd-8ddd-dddddddddddd.jpg`;
  const profile = { user_id: owner, display_name: "Alice", avatar_path: path };
  const unavailable = async () => { throw new Error("Storage unavailable"); };
  const fallback = await signedAvatar(profile, false, unavailable);
  assert.equal(fallback.avatar_url, null);
  assert.equal(fallback.display_name, "Alice");
  assert.equal("avatar_path" in fallback, false);
  await assert.rejects(signedAvatar(profile, true, unavailable), /Storage unavailable/);
  let requested = false;
  const foreign = await signedAvatar({ ...profile, user_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" }, false, async () => { requested = true; return "https://storage.example/signed"; });
  assert.equal(foreign.avatar_url, null);
  assert.equal(requested, false);
});

test("concurrent requests share private photo signing and failed signing can retry", async () => {
  const owner = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const profile = { user_id: owner, avatar_path: `${owner}/ffffffff-ffff-4fff-8fff-ffffffffffff.jpg` };
  let calls = 0;
  let finish: (url: string) => void = () => assert.fail("Signing did not start");
  const sign = async () => { calls++; return new Promise<string>(resolve => { finish = resolve; }); };
  const first = signedAvatar(profile, true, sign), second = signedAvatar(profile, true, sign);
  assert.equal(calls, 1, "The same member appearing in several rooms needs one signing request.");
  finish("https://storage.example/signed-photo");
  const results = await Promise.all([first, second]);
  assert.equal(results[0].avatar_url, results[1].avatar_url);
  assert.equal((await signedAvatar(profile, true, sign)).avatar_url, results[0].avatar_url);
  assert.equal(calls, 1);
  const another = { ...profile, avatar_path: `${owner}/11111111-1111-4111-8111-111111111111.jpg` };
  const unavailable = async () => { throw new Error("Storage unavailable"); };
  await assert.rejects(signedAvatar(another, true, unavailable), /Storage unavailable/);
  assert.equal((await signedAvatar(another, true, async () => "https://storage.example/retried")).avatar_url, "https://storage.example/retried");
});
