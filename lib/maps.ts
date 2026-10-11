import { createHash, sign } from "node:crypto";
import { z } from "zod";
import { env } from "./db";

const mapPlace = z.object({ name: z.string().min(1).max(160), formattedAddressLines: z.array(z.string()).optional(),
  coordinate: z.object({ latitude: z.number().min(-90).max(90), longitude: z.number().min(-180).max(180) }),
  id: z.string().optional(), placeID: z.string().optional(), urls: z.array(z.string()).optional(),
});
let token: { value: string; expires: number } | undefined;

export function placeIdentity(name: string, address: string, latitude: number, longitude: number) {
  return "apple:" + createHash("sha256").update([name.trim().toLowerCase(), address.trim().toLowerCase(), latitude.toFixed(5), longitude.toFixed(5)].join("|")).digest("hex");
}

async function mapsToken() {
  if (token && token.expires > Date.now() + 60000) return token.value;
  const now = Math.floor(Date.now() / 1000);
  const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: env("APPLE_MAPS_KEY_ID"), typ: "JWT" })).toString("base64url");
  const claims = Buffer.from(JSON.stringify({ iss: env("APPLE_MAPS_TEAM_ID"), iat: now, exp: now + 1800, scope: "server_api" })).toString("base64url");
  const input = `${header}.${claims}`;
  const signature = sign("sha256", Buffer.from(input), { key: Buffer.from(env("APPLE_MAPS_PRIVATE_KEY_B64"), "base64").toString("utf8"), dsaEncoding: "ieee-p1363" }).toString("base64url");
  const response = await fetch("https://maps-api.apple.com/v1/token", { signal: AbortSignal.timeout(10000), headers: { Authorization: `Bearer ${input}.${signature}` } });
  if (!response.ok) throw new Error(`Place search is unavailable (${response.status}).`);
  const result = z.object({ accessToken: z.string(), expiresInSeconds: z.number().positive() }).parse(await response.json());
  token = { value: result.accessToken, expires: Date.now() + result.expiresInSeconds * 1000 };
  return token.value;
}

export async function resolvePlace(query: string, location?: { latitude: number; longitude: number }) {
  if (!query.trim() || query.length > 200) throw new Error("Use a short place name and city.");
  const url = new URL("https://maps-api.apple.com/v1/search");
  url.searchParams.set("q", query);
  url.searchParams.set("lang", "en-US");
  if (location) url.searchParams.set("searchLocation", `${location.latitude},${location.longitude}`);
  const response = await fetch(url, { signal: AbortSignal.timeout(10000), headers: { Authorization: `Bearer ${await mapsToken()}` } });
  if (!response.ok) throw new Error(`Place search is unavailable (${response.status}).`);
  const result = z.object({ results: z.array(mapPlace) }).parse(await response.json());
  return result.results.slice(0, 6).map(place => {
    const address = (place.formattedAddressLines ?? []).join(", ");
    const { latitude, longitude } = place.coordinate;
    return { name: place.name, address, latitude, longitude, provider: "apple" as const,
      provider_id: place.id ?? place.placeID ?? placeIdentity(place.name, address, latitude, longitude),
      website: place.urls?.find(value => /^https?:\/\//i.test(value)) };
  });
}
