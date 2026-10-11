import assert from "node:assert/strict";
import test from "node:test";
import { checked } from "../lib/db";
import { route } from "../lib/http";

test("database permission and input failures do not ask clients to retry or expose database details", async () => {
  for (const [code, status] of [["42501", 403], ["22023", 400], ["23503", 400], ["23514", 400], ["23505", 409]] as const) {
    const response = await route(async () => {
      checked({ data: null, error: { code, message: "private database details" } });
      return Response.json({ ok: true });
    });
    assert.equal(response.status, status);
    assert.equal((await response.text()).includes("private database details"), false);
  }
});
