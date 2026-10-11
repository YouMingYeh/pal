import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, verify } from "node:crypto";
import { test } from "node:test";
import { calendarScope, completeGoogleConnection, googleAuthorization, googleEvent, googleEventId, stateHash, writeGoogleEvent, type CalendarSync } from "../lib/calendar";
import { encryptCredential, decryptCredential } from "../lib/integration-store";
import { apnsJWT, pushPayload } from "../lib/push";

process.env.PAL_INTERNAL_SECRET = "integration-tests-only-secret";
process.env.GOOGLE_CLIENT_ID = "integration-tests.apps.googleusercontent.com";
process.env.GOOGLE_CLIENT_SECRET = "integration-test-client-secret";
process.env.PAL_BASE_URL = "https://pal.example";

const plan = {
  id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", group_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  title: "Dinner", starts_at: "2026-11-02T03:00:00Z", ends_at: "2026-11-02T05:00:00Z", notes: "Four people", status: "confirmed", version: 1,
};
const sync = {
  id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", plan_id: plan.id, user_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
  event_id: null, desired_version: 1, attempts: 1, sync_required: true, plan,
  place: { name: "Restaurant", address: "10 Main St" }, group: { name: "Friends", timezone: "America/Los_Angeles" },
  connection: { id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", user_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", calendar_id: "pal-calendar", encrypted_refresh_token: "", encrypted_access_token: "", expires_at: null, status: "connected", error: null, calendar_attempts: 0 },
} satisfies CalendarSync;

test("credentials are encrypted, randomized, authenticated and bound to the owning context", () => {
  const sealed = encryptCredential("private refresh token", "user-a");
  assert.equal(decryptCredential(sealed, "user-a"), "private refresh token");
  assert.notEqual(encryptCredential("private refresh token", "user-a"), sealed);
  assert.ok(!sealed.includes("private refresh token"));
  assert.throws(() => decryptCredential(sealed, "user-b"));
  const parts = sealed.split(".");
  parts[2] = (parts[2][0] === "A" ? "B" : "A") + parts[2].slice(1);
  assert.throws(() => decryptCredential(parts.join("."), "user-a"));
  assert.throws(() => decryptCredential("plaintext", "user-a"));
});

test("Google consent requests only the app calendar scope with offline access and PKCE", () => {
  const verifier = "random-code-verifier";
  const url = new URL(googleAuthorization("opaque-state", verifier));
  assert.equal(url.origin, "https://accounts.google.com");
  assert.equal(url.searchParams.get("scope"), calendarScope);
  assert.equal(url.searchParams.get("access_type"), "offline");
  assert.equal(url.searchParams.get("code_challenge_method"), "S256");
  assert.equal(url.searchParams.get("code_challenge"), createHash("sha256").update(verifier).digest("base64url"));
  assert.equal(url.searchParams.get("redirect_uri"), "https://pal.example/api/calendar/callback");
  assert.equal(url.searchParams.get("state"), "opaque-state");
  assert.ok(!url.href.includes(process.env.GOOGLE_CLIENT_SECRET!));
  assert.notEqual(stateHash("opaque-state"), "opaque-state");
});

test("Calendar event IDs are stable per member; times preserve instants and group timezone", () => {
  assert.match(googleEventId(plan.id, sync.user_id), /^[a-v0-9]{5,1024}$/);
  assert.equal(googleEventId(plan.id, sync.user_id), googleEventId(plan.id, sync.user_id));
  assert.notEqual(googleEventId(plan.id, "another-user"), googleEventId(plan.id, sync.user_id));
  const event = googleEvent(sync);
  assert.equal(event.start.dateTime, plan.starts_at);
  assert.equal(event.start.timeZone, "America/Los_Angeles");
  assert.equal(event.location, "Restaurant, 10 Main St");
  assert.ok(event.description.includes(`pal://group/${plan.group_id}?plan=${plan.id}`));
  assert.deepEqual(event.reminders, { useDefault: false });
});

test("Calendar retries, edits, cancellation and renewed attendance retain exactly one event", async () => {
  const original = globalThis.fetch;
  const events = new Map<string, Record<string, unknown>>();
  let inserts = 0;
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    assert.equal(url.origin, "https://www.googleapis.com");
    assert.equal(new Headers(init?.headers).get("authorization"), "Bearer test-access-token");
    const eventId = url.pathname.split("/").at(-1)!;
    const method = init?.method || "GET";
    const response = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
    const current = events.get(eventId);
    if (method === "GET") return current ? response(current) : response({}, 404);
    if (method === "POST") {
      const data = JSON.parse(String(init!.body));
      if (events.has(data.id)) return response({}, 409);
      inserts++;
      events.set(data.id, { ...data, etag: `version-${inserts}` });
      return response(data);
    }
    if (!current) return response({}, 404);
    const match = new Headers(init?.headers).get("if-match");
    if (match && match !== current.etag) return response({}, 412);
    if (method === "DELETE") {
      if (current.status === "cancelled") return response({}, 410);
      events.set(eventId, { ...current, status: "cancelled", etag: "cancelled" });
      return new Response(null, { status: 204 });
    }
    assert.equal(method, "PUT");
    const data = JSON.parse(String(init!.body));
    if (current.status === "cancelled") assert.ok(data.sequence > Number(current.sequence));
    events.set(eventId, { ...data, id: eventId, etag: `version-${data.sequence}` });
    return response(data);
  };
  try {
    const eventId = await writeGoogleEvent(sync, "test-access-token", "pal-calendar");
    await writeGoogleEvent(sync, "test-access-token", "pal-calendar");
    const changed = { ...sync, desired_version: 2, plan: { ...plan, version: 2, starts_at: "2026-11-03T03:00:00Z", ends_at: "2026-11-03T05:00:00Z" } };
    await writeGoogleEvent(changed, "test-access-token", "pal-calendar");
    assert.equal(events.get(eventId!)?.start && (events.get(eventId!)!.start as { dateTime: string }).dateTime, changed.plan.starts_at);
    await writeGoogleEvent({ ...changed, sync_required: false }, "test-access-token", "pal-calendar");
    await writeGoogleEvent({ ...changed, sync_required: false }, "test-access-token", "pal-calendar");
    assert.equal(events.get(eventId!)?.status, "cancelled");
    await writeGoogleEvent(changed, "test-access-token", "pal-calendar");
    assert.equal(events.get(eventId!)?.status, "confirmed");
    assert.equal(inserts, 1);
    assert.equal(events.size, 1);
    await writeGoogleEvent(sync, "test-access-token", "pal-calendar");
    assert.equal((events.get(eventId!)!.extendedProperties as { private: { palVersion: string } }).private.palVersion, "2");
    // RSVP changes advance the sync revision without changing the shared plan version.
    await writeGoogleEvent({ ...changed, desired_version: 4 }, "test-access-token", "pal-calendar");
    await writeGoogleEvent({ ...changed, desired_version: 3, sync_required: false }, "test-access-token", "pal-calendar");
    assert.equal(events.get(eventId!)?.status, "confirmed");
    assert.equal((events.get(eventId!)!.extendedProperties as { private: { palSyncRevision: string } }).private.palSyncRevision, "4");
    await assert.rejects(writeGoogleEvent(sync, "test-access-token", "primary"));
  } finally { globalThis.fetch = original; }
});

test("consumed or expired OAuth state cannot exchange a code or overwrite a connection", async () => {
  const original = globalThis.fetch;
  process.env.SUPABASE_URL = "https://test.supabase.co";
  process.env.SUPABASE_SERVICE_ROLE_KEY = "test-service-role-key";
  let claims = 0;
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    assert.equal(url.pathname, "/rest/v1/rpc/pal_integration_update");
    const data = JSON.parse(String(init?.body));
    assert.equal(data.p_kind, "oauth_states");
    assert.equal(data.p_data.op, "claim");
    assert.equal(data.p_data.state_hash, stateHash("a".repeat(43)));
    claims++;
    return new Response("null", { headers: { "content-type": "application/json" } });
  };
  try {
    await assert.rejects(completeGoogleConnection("a".repeat(43), "unused-code"), /expired/);
    assert.equal(claims, 1);
    await assert.rejects(completeGoogleConnection("invalid-state", "unused-code"), /Invalid/);
    assert.equal(claims, 1);
  } finally { globalThis.fetch = original; }
});

test("APNs tokens use a verifiable ES256 signature and safe card deep link payload", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const jwt = apnsJWT("TEAM123456", "KEY1234567", privateKey.export({ format: "pem", type: "pkcs8" }).toString(), 12345);
  const [header, claims, signature] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url").toString()), { alg: "ES256", kid: "KEY1234567" });
  assert.deepEqual(JSON.parse(Buffer.from(claims, "base64url").toString()), { iss: "TEAM123456", iat: 12345 });
  assert.equal(Buffer.from(signature, "base64url").length, 64);
  assert.equal(verify("sha256", Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url")), true);
  const payload = pushPayload({ id: sync.id, group_id: plan.group_id, message_id: plan.id, plan_id: plan.id, attempts: 1, payload: { body: "x".repeat(5000) }, devices: [] });
  assert.equal(payload.group_id, plan.group_id);
  assert.equal(payload.entity_id, plan.id);
  assert.equal(payload.type, "plan");
  assert.equal(payload.aps.alert.body.length, 500);
  assert.ok(Buffer.byteLength(JSON.stringify(payload)) < 4096);
});
