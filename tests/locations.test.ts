import assert from "node:assert/strict";
import { test } from "node:test";
import { locationInput } from "../lib/locations";
import { boundedAcrossGroupContext } from "../lib/across-groups";
import { POST, DELETE } from "../app/api/groups/[id]/locations/route";

test("shared locations accept finite coordinates and accuracy without client-owned identity or timestamps", () => {
  const location = { latitude: 37.78, longitude: -122.41, accuracy: 12 };
  assert.deepEqual(locationInput.parse(location), location);
  assert.deepEqual(locationInput.parse({ latitude: -90, longitude: 180, accuracy: 0 }), { latitude: -90, longitude: 180, accuracy: 0 });
  for (const input of [
    { ...location, latitude: 91 }, { ...location, longitude: -181 }, { ...location, accuracy: -1 }, { ...location, accuracy: 10001 },
    { ...location, latitude: NaN }, { ...location, latitude: Infinity }, { ...location, longitude: "-122.41" },
    { ...location, user_id: "someone-else" }, { ...location, group_id: "another-group" },
    { ...location, updated_at: "2099-01-01" }, { ...location, expires_at: "2099-01-01" }, {}, null,
  ]) assert.throws(() => locationInput.parse(input));
});

test("private Pal cross-group context strips member GPS data while retaining venue coordinates", () => {
  const id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const result = boundedAcrossGroupContext({ next_offset: null, groups: [{
    id, name: "Friends", timezone: "UTC", members: [{ user_id: id, display_name: "Amy", latitude: 37.78, longitude: -122.41 }],
    messages: [], plans: [], sources: [], memories: [],
    locations: [{ user_id: id, latitude: 37.78, longitude: -122.41, accuracy: 10, updated_at: "2026-10-11T22:00:00Z" }],
    places: [{ id, name: "Cafe", address: "Main St", latitude: 37.8, longitude: -122.4 }],
  }] });
  assert.equal("locations" in result.groups[0], false);
  assert.equal("latitude" in result.groups[0].members[0], false);
  assert.equal(result.groups[0].places[0].latitude, 37.8);
  assert.ok(!JSON.stringify(result).includes("37.78"));
});

test("location endpoints use verified group membership and never accept caller-owned identity or clocks", async () => {
  const originalFetch = globalThis.fetch;
  const priorURL = process.env.SUPABASE_URL, priorKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  process.env.SUPABASE_URL = "https://test.supabase.co";
  process.env.SUPABASE_PUBLISHABLE_KEY = "test-key";
  const group = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", user = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  let allowed = true;
  const updates: Record<string, unknown>[] = [];
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    assert.equal(new Headers(init?.headers).get("authorization"), "Bearer location-owner-token");
    if (url.pathname === "/auth/v1/user") return Response.json({ id: user, email: "test@example.invalid" });
    if (url.pathname === "/rest/v1/group_members") {
      assert.equal(url.searchParams.get("group_id"), `eq.${group}`);
      assert.equal(url.searchParams.get("user_id"), `eq.${user}`);
      return Response.json(allowed ? [{ group_id: group }] : []);
    }
    assert.equal(url.pathname, "/rest/v1/rpc/pal_group_location");
    const data = JSON.parse(String(init?.body));
    updates.push(data);
    return Response.json({ location: data.p_location === null ? null : { ...data.p_location, user_id: user, updated_at: "2026-10-11T22:00:00Z", expires_at: "2026-10-11T23:00:00Z" } });
  };
  const context = () => ({ params: Promise.resolve({ id: group }) });
  const request = (method: "POST" | "DELETE", value?: unknown) => new Request(`https://pal.example/api/groups/${group}/locations`, {
    method, headers: { authorization: "Bearer location-owner-token", "content-type": "application/json" },
    ...(value === undefined ? {} : { body: JSON.stringify(value) }),
  });
  try {
    const coordinates = { latitude: 37.78, longitude: -122.41, accuracy: 12 };
    const response = await POST(request("POST", coordinates), context());
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "private, no-store");
    assert.equal((await response.json()).location.user_id, user);
    assert.deepEqual(updates[0], { p_group_id: group, p_location: coordinates });
    assert.equal((await POST(request("POST", { ...coordinates, user_id: "another-person" }), context())).status, 400);
    assert.equal(updates.length, 1, "Forged identity never reaches the database operation.");
    const stopped = await DELETE(request("DELETE"), context());
    assert.equal(stopped.status, 200);
    assert.deepEqual(await stopped.json(), { location: null });
    assert.deepEqual(updates[1], { p_group_id: group, p_location: null });
    allowed = false;
    assert.equal((await POST(request("POST", coordinates), context())).status, 403);
    assert.equal((await DELETE(request("DELETE"), context())).status, 403);
    assert.equal(updates.length, 2, "Removed members cannot read or mutate location state.");
  } finally {
    globalThis.fetch = originalFetch;
    if (priorURL === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = priorURL;
    if (priorKey === undefined) delete process.env.SUPABASE_PUBLISHABLE_KEY; else process.env.SUPABASE_PUBLISHABLE_KEY = priorKey;
  }
});
