import assert from "node:assert/strict";
import test from "node:test";
import { assertPublicURL, pageText } from "../lib/research";
import { extractedPlaces, isSocialVideo } from "../lib/social";
import { placeIdentity } from "../lib/maps";

test("untrusted URL reading rejects local addresses, credentials and non-web schemes", async () => {
  for (const url of ["http://127.0.0.1", "http://[::1]", "http://169.254.169.254/latest/meta-data", "http://localhost", "http://10.0.0.1", "file:///etc/passwd", "https://name:secret@example.com", "https://example.com:8080"]) {
    await assert.rejects(assertPublicURL(url));
  }
});

test("video providers match real domains and extraction keeps evidence without inventing coordinates", () => {
  assert.equal(isSocialVideo("https://www.instagram.com/reel/example"), true);
  assert.equal(isSocialVideo("https://vm.tiktok.com/example"), true);
  assert.equal(isSocialVideo("https://instagram.com.attacker.example/reel/example"), false);
  assert.equal(extractedPlaces.safeParse({ places: [{ name: "Cafe", city: "", address: "", dishes: [], prices: [], evidence: ["0:04 on-screen Cafe"], confidence: "low" }] }).success, true);
  assert.equal(extractedPlaces.safeParse({ places: [{ name: "Cafe", latitude: 37 }] }).success, false);
});

test("same resolved branch has a stable map identity; different branches stay separate", () => {
  assert.equal(placeIdentity("Cafe", "One St", 37.123456, -122), placeIdentity(" cafe ", " one st ", 37.123456, -122));
  assert.notEqual(placeIdentity("Cafe", "One St", 37, -122), placeIdentity("Cafe", "Two St", 37, -122));
});

test("web page text excludes active content and bounds agent input", () => {
  assert.equal(pageText('<script>steal()</script><style>body{}</style><p>Menu &amp; hours</p>'), "Menu & hours");
  assert.equal(pageText("a".repeat(30000)).length, 24000);
});
