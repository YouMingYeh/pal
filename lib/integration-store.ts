import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import { admin, checked, env } from "./db";

export type IntegrationKind = "oauth_states" | "google_connections" | "google_sync_items" | "push_devices" | "push_outbox";

export async function integrationState<T>(kind: IntegrationKind, limit = 100): Promise<T[]> {
  return checked(await admin().rpc("pal_integration_state", { p_kind: kind, p_limit: limit })) as T[];
}

export async function integrationUpdate<T>(kind: IntegrationKind, id: string | null, data: Record<string, unknown>): Promise<T> {
  return checked(await admin().rpc("pal_integration_update", { p_kind: kind, p_id: id, p_data: data })) as T;
}

function credentialKey() {
  return createHash("sha256").update(env("PAL_INTERNAL_SECRET") + ":pal-integrations:v1").digest();
}

export function encryptCredential(value: string, context: string) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", credentialKey(), iv);
  cipher.setAAD(Buffer.from(context));
  const ciphertext = Buffer.concat([cipher.update(value, "utf8"), cipher.final()]);
  return ["v1", iv.toString("base64url"), cipher.getAuthTag().toString("base64url"), ciphertext.toString("base64url")].join(".");
}

export function decryptCredential(value: string, context: string) {
  const [version, iv, tag, ciphertext, extra] = value.split(".");
  if (version !== "v1" || !iv || !tag || ciphertext === undefined || extra) throw new Error("Invalid encrypted credential.");
  const decipher = createDecipheriv("aes-256-gcm", credentialKey(), Buffer.from(iv, "base64url"));
  decipher.setAAD(Buffer.from(context));
  decipher.setAuthTag(Buffer.from(tag, "base64url"));
  return Buffer.concat([decipher.update(Buffer.from(ciphertext, "base64url")), decipher.final()]).toString("utf8");
}

export function retryAt(attempt: number) {
  return new Date(Date.now() + Math.min(3_600_000, 60_000 * 2 ** Math.min(attempt, 6))).toISOString();
}
