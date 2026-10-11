import assert from "node:assert/strict";
import { test } from "node:test";
import { groupCreationForm, groupCreationInput, ownsGroupPhoto } from "../lib/group-avatar";

test("group photos use trusted creator paths and stable creation identity", () => {
  const creator = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", image = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  assert.equal(ownsGroupPhoto(creator, `groups/${creator}/${image}.jpg`), true);
  assert.equal(ownsGroupPhoto(image, `groups/${creator}/${image}.jpg`), false);
  assert.equal(ownsGroupPhoto(creator, `groups/${creator}/../${image}.jpg`), false);
  assert.throws(() => groupCreationInput.parse({ name: "Dinner", client_id: image, creator_id: creator }));
});

test("creation accepts an optional photo while rejecting duplicate or forged fields", async () => {
  const form = new FormData();
  form.set("name", "Dinner"); form.set("client_id", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
  const request = () => new Request("https://pal.example/api/groups", { method: "POST", body: form });
  assert.equal((await groupCreationForm(request())).file, null);
  form.set("file", new File(["JPEG bytes"], "group.jpg", { type: "image/jpeg" }));
  assert.equal((await groupCreationForm(request())).file?.name, "group.jpg");
  form.set("avatar_path", "groups/someone/photo.jpg");
  await assert.rejects(groupCreationForm(request()));
  form.delete("avatar_path"); form.append("client_id", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
  await assert.rejects(groupCreationForm(request()));
});
