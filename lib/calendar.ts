import { createHash, randomBytes, randomUUID } from "node:crypto";
import { env } from "./db";
import { decryptCredential, encryptCredential, integrationUpdate, retryAt } from "./integration-store";

export const calendarScope = "https://www.googleapis.com/auth/calendar.app.created";
const calendarApi = "https://www.googleapis.com/calendar/v3";
const tokenEndpoint = "https://oauth2.googleapis.com/token";

type Connection = {
  id: string; user_id: string; calendar_id: string | null; encrypted_refresh_token: string;
  encrypted_access_token: string | null; expires_at: string | null;
  status: "connected" | "revoked" | "error"; error: string | null; calendar_attempts: number;
};
type OAuthState = { id: string; user_id: string; encrypted_code_verifier: string; state_hash: string };
type TokenResponse = { access_token: string; refresh_token?: string; expires_in: number; scope?: string };
export type CalendarSync = {
  id: string; plan_id: string; user_id: string; event_id: string | null; desired_version: number;
  attempts: number; previous_state?: string; sync_required: boolean;
  plan: { id: string; group_id: string; title: string; starts_at: string; ends_at: string; notes: string; status: string; version: number };
  place: { name: string; address: string } | null;
  group: { timezone: string; name: string };
  connection: Connection;
};

class GoogleError extends Error {
  constructor(public status: number, public code = "provider_error") { super(`Google Calendar request failed (${status}).`); }
}

export function googleConfigured() {
  return Boolean(process.env.GOOGLE_CLIENT_ID && process.env.GOOGLE_CLIENT_SECRET && process.env.PAL_INTERNAL_SECRET && process.env.PAL_BASE_URL);
}

function redirectUri() {
  return process.env.GOOGLE_REDIRECT_URI || new URL("/api/calendar/callback", env("PAL_BASE_URL")).href;
}

export function stateHash(state: string) { return createHash("sha256").update(state).digest("hex"); }

export function googleAuthorization(state: string, verifier: string) {
  const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  url.search = new URLSearchParams({
    client_id: env("GOOGLE_CLIENT_ID"), redirect_uri: redirectUri(), response_type: "code",
    scope: calendarScope, access_type: "offline", prompt: "consent", state,
    code_challenge: createHash("sha256").update(verifier).digest("base64url"), code_challenge_method: "S256",
  }).toString();
  return url.href;
}

async function getConnection(userId: string) {
  return integrationUpdate<Connection | null>("google_connections", null, { op: "get", user_id: userId });
}

export async function beginGoogleConnection(userId: string) {
  if (!googleConfigured()) throw new Error("Google Calendar is not configured.");
  const state = randomBytes(32).toString("base64url");
  const verifier = randomBytes(48).toString("base64url");
  const hash = stateHash(state);
  await integrationUpdate("oauth_states", randomUUID(), {
    op: "put", user_id: userId, state_hash: hash,
    encrypted_code_verifier: encryptCredential(verifier, hash), expires_at: new Date(Date.now() + 600_000).toISOString(),
  });
  return googleAuthorization(state, verifier);
}

async function tokens(parameters: Record<string, string>): Promise<TokenResponse> {
  const response = await fetch(tokenEndpoint, {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: env("GOOGLE_CLIENT_ID"), client_secret: env("GOOGLE_CLIENT_SECRET"), ...parameters }),
    signal: AbortSignal.timeout(15_000), redirect: "error", cache: "no-store",
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new GoogleError(response.status, result.error === "invalid_grant" ? "invalid_grant" : "provider_error");
  if (typeof result.access_token !== "string" || typeof result.expires_in !== "number") throw new GoogleError(502);
  return result;
}

async function googleRequest(accessToken: string, path: string, method = "GET", body?: unknown, etag?: string) {
  const response = await fetch(calendarApi + path, {
    method, headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json", ...(etag ? { "if-match": etag } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(15_000), redirect: "error", cache: "no-store",
  });
  const result = response.status === 204 ? {} : await response.json().catch(() => ({}));
  if (!response.ok) throw new GoogleError(response.status);
  return result as Record<string, unknown>;
}

async function accessToken(connection: Connection) {
  if (connection.encrypted_access_token && connection.expires_at && Date.parse(connection.expires_at) > Date.now() + 60_000) {
    return decryptCredential(connection.encrypted_access_token, connection.user_id);
  }
  const result = await tokens({ grant_type: "refresh_token", refresh_token: decryptCredential(connection.encrypted_refresh_token, connection.user_id) });
  const saved = await integrationUpdate<Connection | null>("google_connections", connection.id, {
    op: "put", user_id: connection.user_id, encrypted_access_token: encryptCredential(result.access_token, connection.user_id),
    expected_status: "connected", expected_encrypted_refresh_token: connection.encrypted_refresh_token,
    ...(result.refresh_token ? { encrypted_refresh_token: encryptCredential(result.refresh_token, connection.user_id) } : {}),
    expires_at: new Date(Date.now() + result.expires_in * 1000).toISOString(), error: null,
  });
  if (!saved) throw new Error("Calendar connection changed. Retry shortly.");
  Object.assign(connection, saved);
  return result.access_token;
}

async function ensureCalendar(connection: Connection, token: string) {
  if (connection.calendar_id && connection.calendar_id !== "primary") return connection.calendar_id;
  const claimed = await integrationUpdate<Connection | null>("google_connections", connection.id, { op: "claim" });
  if (!claimed) throw new Error("Calendar connection is being completed. Retry shortly.");
  const created = await googleRequest(token, "/calendars", "POST", { summary: "Pal", description: "Plans confirmed in Pal." });
  if (typeof created.id !== "string" || created.id === "primary") throw new GoogleError(502);
  const saved = await integrationUpdate<{ ok: boolean }>("google_connections", connection.id, {
    op: "finish", expected_attempt: claimed.calendar_attempts, calendar_id: created.id,
  });
  if (!saved.ok) {
    await googleRequest(token, `/calendars/${encodeURIComponent(created.id)}`, "DELETE").catch(() => undefined);
    throw new Error("Calendar connection changed. Reconnect Google Calendar.");
  }
  return created.id;
}

export async function completeGoogleConnection(state: string, code: string) {
  if (!googleConfigured() || !/^[A-Za-z0-9_-]{40,128}$/.test(state) || !code || code.length > 4096) throw new Error("Invalid calendar authorization.");
  const hash = stateHash(state);
  const saved = await integrationUpdate<OAuthState | null>("oauth_states", null, { op: "claim", state_hash: hash });
  if (!saved) throw new Error("Calendar authorization expired. Connect again.");
  const result = await tokens({
    grant_type: "authorization_code", code, redirect_uri: redirectUri(),
    code_verifier: decryptCredential(saved.encrypted_code_verifier, saved.state_hash),
  });
  if (result.scope && !result.scope.split(" ").includes(calendarScope)) throw new Error("Calendar permission was not granted.");
  const prior = await getConnection(saved.user_id);
  const refresh = result.refresh_token || (prior?.encrypted_refresh_token ? decryptCredential(prior.encrypted_refresh_token, saved.user_id) : null);
  if (!refresh) throw new Error("Offline calendar permission was not granted. Connect again.");
  const connection = await integrationUpdate<Connection>("google_connections", prior?.id || saved.user_id, {
    op: "put", user_id: saved.user_id, encrypted_refresh_token: encryptCredential(refresh, saved.user_id),
    encrypted_access_token: encryptCredential(result.access_token, saved.user_id),
    expires_at: new Date(Date.now() + result.expires_in * 1000).toISOString(), status: "connected", error: null, resync: true,
  });
  // Reconnecting may select a different Google account; never write into an inaccessible old calendar.
  if (connection.calendar_id) {
    try { await googleRequest(result.access_token, `/calendars/${encodeURIComponent(connection.calendar_id)}`); }
    catch (error) {
      if (!(error instanceof GoogleError) || ![403, 404].includes(error.status)) throw error;
      connection.calendar_id = null;
      await integrationUpdate("google_connections", connection.id, { op: "put", user_id: connection.user_id, calendar_id: null });
    }
  }
  await ensureCalendar(connection, result.access_token);
}

export async function googleConnectionStatus(userId: string) {
  const connection = await getConnection(userId);
  return { connected: connection?.status === "connected" && Boolean(connection.calendar_id), ...(connection?.error ? { sync_error: connection.error } : {}) };
}

export async function disconnectGoogle(userId: string) {
  const connection = await getConnection(userId);
  if (!connection) return;
  await integrationUpdate("google_connections", connection.id, { op: "put", user_id: userId, status: "revoked", error: null });
  try {
    if (connection.encrypted_refresh_token) {
      const response = await fetch("https://oauth2.googleapis.com/revoke", {
        method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ token: decryptCredential(connection.encrypted_refresh_token, userId) }),
        signal: AbortSignal.timeout(10_000), redirect: "error", cache: "no-store",
      });
      if (!response.ok && response.status !== 400) throw new GoogleError(response.status);
    }
  } finally {
    await integrationUpdate("google_connections", connection.id, {
      op: "put", user_id: userId, status: "revoked", encrypted_refresh_token: "", encrypted_access_token: null, expires_at: null,
    });
  }
}

export function googleEventId(planId: string, userId: string) {
  return "pal" + createHash("sha256").update(`${planId}:${userId}`).digest("hex");
}

export function googleEvent(sync: CalendarSync) {
  const { plan, place, group } = sync;
  return {
    id: googleEventId(plan.id, sync.user_id), summary: plan.title, status: "confirmed",
    description: [plan.notes, `Group: ${group.name}`, `pal://group/${plan.group_id}?plan=${plan.id}`].filter(Boolean).join("\n"),
    ...(place ? { location: [place.name, place.address].filter(Boolean).join(", ") } : {}),
    start: { dateTime: plan.starts_at, timeZone: group.timezone }, end: { dateTime: plan.ends_at, timeZone: group.timezone },
    extendedProperties: { private: { palPlanId: plan.id, palVersion: String(plan.version), palSyncRevision: String(sync.desired_version) } },
    reminders: { useDefault: false },
  };
}

export async function writeGoogleEvent(sync: CalendarSync, token: string, calendarId: string) {
  if (calendarId === "primary") throw new Error("Pal only synchronizes its own calendar.");
  const eventId = sync.event_id || googleEventId(sync.plan_id, sync.user_id);
  const path = `/calendars/${encodeURIComponent(calendarId)}/events/${eventId}`;
  let existing: Record<string, unknown> | null = null;
  try { existing = await googleRequest(token, path); }
  catch (error) { if (!(error instanceof GoogleError) || ![404, 410].includes(error.status)) throw error; }
  const properties = existing?.extendedProperties as { private?: { palVersion?: string; palSyncRevision?: string } } | undefined;
  if (Number(properties?.private?.palSyncRevision || properties?.private?.palVersion) > sync.desired_version) return sync.sync_required ? eventId : null;
  const etag = typeof existing?.etag === "string" ? existing.etag : undefined;
  if (!sync.sync_required) {
    try { await googleRequest(token, path, "DELETE", undefined, etag); }
    catch (error) { if (!(error instanceof GoogleError) || ![404, 410].includes(error.status)) throw error; }
    return null;
  }
  const { id: ignored, ...data } = googleEvent(sync);
  void ignored;
  const event = { ...data, sequence: typeof existing?.sequence === "number" ? existing.sequence + 1 : 0 };
  if (existing) await googleRequest(token, path, "PUT", event, etag);
  else {
    try { await googleRequest(token, `/calendars/${encodeURIComponent(calendarId)}/events`, "POST", { ...event, id: eventId }); }
    catch (insertError) {
      if (!(insertError instanceof GoogleError) || insertError.status !== 409) throw insertError;
      const current = await googleRequest(token, path);
      await googleRequest(token, path, "PUT", { ...event, sequence: typeof current.sequence === "number" ? current.sequence + 1 : 1 }, typeof current.etag === "string" ? current.etag : undefined);
    }
  }
  return eventId;
}

export async function runCalendarSync() {
  if (!googleConfigured()) return 0;
  const rows = await integrationUpdate<CalendarSync[]>("google_sync_items", null, { op: "claim", limit: 10 });
  let count = 0;
  for (const sync of rows) {
    try {
      const token = await accessToken(sync.connection);
      const calendarId = await ensureCalendar(sync.connection, token);
      const eventId = await writeGoogleEvent(sync, token, calendarId);
      const result = await integrationUpdate<{ ok: boolean }>("google_sync_items", sync.id, {
        op: "finish", expected_attempt: sync.attempts, expected_version: sync.desired_version, state: "synced", event_id: eventId, error: null,
      });
      if (result.ok) {
        count++;
        await integrationUpdate("google_connections", sync.connection.id, {
          op: "put", user_id: sync.user_id, expected_status: "connected",
          expected_encrypted_refresh_token: sync.connection.encrypted_refresh_token, error: null,
        });
      }
    } catch (error) {
      const revoked = error instanceof GoogleError && error.code === "invalid_grant";
      const message = revoked || sync.attempts >= 10 ? "Reconnect Google Calendar." : "Calendar sync failed. Pal will retry.";
      await integrationUpdate("google_connections", sync.connection.id, {
        op: "put", user_id: sync.user_id, expected_status: "connected", error: message, ...(revoked ? { status: "revoked" } : {}),
        expected_encrypted_refresh_token: sync.connection.encrypted_refresh_token,
        ...(error instanceof GoogleError && error.status === 401 ? { encrypted_access_token: null, expires_at: null } : {}),
      });
      await integrationUpdate("google_sync_items", sync.id, {
        op: "finish", expected_attempt: sync.attempts, expected_version: sync.desired_version,
        state: "failed", error: message, next_attempt: retryAt(sync.attempts),
      });
    }
  }
  return count;
}
