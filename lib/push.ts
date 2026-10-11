import { sign } from "node:crypto";
import { connect } from "node:http2";
import { env } from "./db";
import { integrationUpdate, retryAt } from "./integration-store";

type Device = { id: string; token: string; environment: "sandbox" | "production"; updated_at: string };
export type PushItem = {
  id: string; group_id: string; message_id: string | null; plan_id: string | null; attempts: number;
  payload: { title?: string; body?: string; type?: string; entity_id?: string; reminder_id?: string; poll_id?: string };
  devices: Device[];
};
type PushResult = { status: number; reason?: string; timestamp?: number };
const jwtCache = new Map<string, { jwt: string; expires: number }>();

function signingConfig(environment: Device["environment"]) {
  const prefix = environment === "production" ? "APNS_PRODUCTION_" : "APNS_";
  const keyId = process.env[prefix + "KEY_ID"];
  const key = process.env[prefix + "PRIVATE_KEY_B64"];
  if (!process.env.APNS_TEAM_ID || !keyId || !key) return null;
  return { teamId: env("APNS_TEAM_ID"), keyId, privateKey: Buffer.from(key, "base64").toString("utf8") };
}

export function apnsJWT(teamId: string, keyId: string, privateKey: string, issuedAt = Math.floor(Date.now() / 1000)) {
  const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: keyId })).toString("base64url");
  const claims = Buffer.from(JSON.stringify({ iss: teamId, iat: issuedAt })).toString("base64url");
  const unsigned = `${header}.${claims}`;
  return `${unsigned}.${sign("sha256", Buffer.from(unsigned), { key: privateKey, dsaEncoding: "ieee-p1363" }).toString("base64url")}`;
}

function providerToken(environment: Device["environment"]) {
  const config = signingConfig(environment);
  if (!config) throw new Error("Push notifications are not configured for this environment.");
  const key = `${config.teamId}:${config.keyId}`;
  let cached = jwtCache.get(key);
  if (!cached || cached.expires < Date.now()) {
    cached = { jwt: apnsJWT(config.teamId, config.keyId, config.privateKey), expires: Date.now() + 45 * 60_000 };
    jwtCache.set(key, cached);
  }
  return cached.jwt;
}

export function pushPayload(item: PushItem) {
  const entity = item.payload.entity_id || item.plan_id || item.payload.reminder_id || item.payload.poll_id;
  const type = item.payload.type || (item.plan_id ? "plan" : item.payload.poll_id ? "choice" : "reminder");
  return {
    aps: { alert: { title: (item.payload.title || "Pal").slice(0, 100), body: (item.payload.body || "New message in your group.").slice(0, 500) }, sound: "default", "thread-id": item.group_id },
    group_id: item.group_id, message_id: item.message_id, ...(entity ? { entity_id: entity } : {}), type,
    ...(item.plan_id ? { plan_id: item.plan_id } : {}),
  };
}

export function sendPush(device: Device, item: PushItem): Promise<PushResult> {
  const jwt = providerToken(device.environment);
  const host = device.environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  const payload = JSON.stringify(pushPayload(item));
  if (Buffer.byteLength(payload) > 4096 || !/^[a-fA-F0-9]{64,200}$/.test(device.token)) throw new Error("Invalid push payload.");
  return new Promise((resolve, reject) => {
    const session = connect(host);
    let settled = false;
    const finish = (error?: Error, result?: PushResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      session.destroy();
      if (error) reject(new Error("APNs connection failed.")); else resolve(result!);
    };
    const timer = setTimeout(() => finish(new Error("Timeout")), 10_000);
    session.once("error", error => finish(error));
    const stream = session.request({
      ":method": "POST", ":path": `/3/device/${device.token}`, authorization: `bearer ${jwt}`,
      "apns-topic": process.env.APNS_TOPIC || "com.pal.spike", "apns-push-type": "alert", "apns-priority": "10",
      "apns-id": item.id, "apns-collapse-id": item.id,
      "apns-expiration": "0", "content-type": "application/json",
    });
    let status = 0;
    let body = "";
    stream.once("response", headers => { status = Number(headers[":status"]); });
    stream.setEncoding("utf8");
    stream.on("data", chunk => { if (body.length < 8192) body += chunk; });
    stream.once("error", error => finish(error));
    stream.once("end", () => {
      let data: { reason?: string; timestamp?: number } = {};
      try { data = JSON.parse(body || "{}"); } catch { /* APNs can return an empty error body. */ }
      finish(undefined, { status, ...data });
    });
    stream.end(payload);
  });
}

export async function runPushDelivery() {
  if (!signingConfig("sandbox") && !signingConfig("production")) return 0;
  const rows = await integrationUpdate<PushItem[]>("push_outbox", null, { op: "claim", limit: 10 });
  let count = 0;
  for (const item of rows) {
    let sent = 0;
    let retry = false;
    await Promise.all(item.devices.map(async device => {
      if (!signingConfig(device.environment)) { retry = true; return; }
      try {
        const result = await sendPush(device, item);
        if (result.status === 200) sent++;
        else if (["Unregistered", "BadDeviceToken"].includes(result.reason || "")) {
          // A new token registration must survive a delayed APNs rejection for an older registration.
          if (!result.timestamp || Date.parse(device.updated_at) <= result.timestamp) {
            await integrationUpdate("push_devices", device.id, { op: "put", enabled: false, expected_updated_at: device.updated_at });
          }
        } else retry = true;
      } catch { retry = true; }
    }));
    await integrationUpdate("push_outbox", item.id, {
      op: "finish", expected_attempt: item.attempts,
      status: retry ? item.attempts >= 5 ? "failed" : "queued" : sent ? "sent" : "cancelled",
      error: retry ? item.attempts >= 5 ? "Push delivery failed. Open Pal to check notifications." : "Push delivery failed. Pal will retry." : !sent ? "No valid notification device." : null,
      next_attempt: retryAt(item.attempts),
    });
    if (sent) count++;
  }
  return count;
}
