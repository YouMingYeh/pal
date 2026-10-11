import assert from "node:assert/strict";
import { test } from "node:test";
import { runSocialInspection } from "../lib/social";

test("finished inspection preserves paid extraction before a short reply and completion failures remain retryable", async () => {
  const originalFetch = globalThis.fetch;
  const names = ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "OPENAI_API_KEY", "OPENAI_MODEL"];
  const previous = Object.fromEntries(names.map(name => [name, process.env[name]]));
  Object.assign(process.env, { SUPABASE_URL: "https://test.supabase.co", SUPABASE_SERVICE_ROLE_KEY: "test-key", OPENAI_API_KEY: "test-openai", OPENAI_MODEL: "test-model" });
  const candidates = [{ name: "Tur", city: "San Francisco", address: "", dishes: [], prices: [], evidence: ["0:03 on-screen Tur"], confidence: "medium" }];
  const source = { id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", group_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", url: "https://www.instagram.com/reel/example", attempts: 4, extraction: { metadata: { title: "Dinner spot" }, places: candidates } };
  const order: string[] = [];
  let modelWorks = true, completionWorks = true;
  let final: Record<string, unknown> = {};
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    if (url.pathname === "/rest/v1/rpc/pal_claim_sources") return Response.json([source]);
    if (url.pathname === "/rest/v1/sources") {
      order.push("persist");
      assert.equal(url.searchParams.get("id"), `eq.${source.id}`);
      assert.equal(url.searchParams.get("attempts"), "eq.4");
      assert.deepEqual(JSON.parse(String(init?.body)), { extraction: source.extraction });
      return Response.json(null);
    }
    if (url.hostname === "maps-api.apple.com") return Response.json({ error: "Test map unavailable" }, { status: 503 });
    if (url.hostname === "api.openai.com") {
      order.push("reply");
      assert.equal(order[0], "persist");
      const request = JSON.parse(String(init?.body));
      assert.equal(request.store, false);
      assert.equal(JSON.parse(request.input).places[0].name, "Tur");
      return modelWorks ? Response.json({ output: [{ content: [{ type: "output_text", text: JSON.stringify({ body: "Tur in San Francisco looks promising. Which branch?", emotion: "curieux" }) }] }] }) : Response.json({ error: "Model unavailable" }, { status: 503 });
    }
    assert.equal(url.pathname, "/rest/v1/rpc/pal_complete_source");
    order.push("complete");
    const data = JSON.parse(String(init?.body));
    assert.equal(data.p_id, source.id);
    final = data.p_result;
    return completionWorks ? Response.json({ ok: true }) : Response.json({ message: "Completion temporarily unavailable", code: "TEST" }, { status: 503 });
  };
  try {
    assert.equal(await runSocialInspection(), 1);
    assert.deepEqual(order, ["persist", "reply", "complete"]);
    assert.equal(final.status, "needs_confirmation");
    assert.equal(final.expected_attempt, 4);
    assert.deepEqual(final.reply, { body: "Tur in San Francisco looks promising. Which branch?", emotion: "curieux" });
    assert.deepEqual((final.extraction as { places: unknown }).places, candidates);
    assert.deepEqual((final.candidates as { options: unknown[] }[])[0].options, []);
    order.length = 0;
    modelWorks = false;
    assert.equal(await runSocialInspection(), 1);
    assert.deepEqual(order, ["persist", "reply", "complete"]);
    assert.equal(final.status, "needs_confirmation", "Unavailable text generation does not erase a successful extraction.");
    assert.ok((final.reply as { body: string }).body.includes("Tur"));
    order.length = 0;
    completionWorks = false;
    await assert.rejects(runSocialInspection(), /Completion temporarily unavailable/);
    assert.deepEqual(order, ["persist", "reply", "complete"], "Failed completion is retried through its lease, never mislabeled as a failed video.");
  } finally {
    globalThis.fetch = originalFetch;
    for (const name of names) if (previous[name] === undefined) delete process.env[name]; else process.env[name] = previous[name];
  }
});

test("inaccessible sources finish with one guarded short reply instead of an unguarded failure mutation", async () => {
  const originalFetch = globalThis.fetch;
  const previousURL = process.env.SUPABASE_URL, previousKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  process.env.SUPABASE_URL = "https://test.supabase.co";
  process.env.SUPABASE_SERVICE_ROLE_KEY = "test-key";
  const source = { id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", group_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", url: "http://127.0.0.1", attempts: 8, extraction: {} };
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    if (url.pathname === "/rest/v1/rpc/pal_claim_sources") return Response.json([source]);
    assert.equal(url.pathname, "/rest/v1/rpc/pal_complete_source");
    const data = JSON.parse(String(init?.body));
    assert.equal(data.p_id, source.id);
    assert.equal(data.p_result.status, "failed");
    assert.equal(data.p_result.expected_attempt, 8);
    assert.ok(data.p_result.error);
    assert.equal(data.p_result.reply.emotion, "confus");
    assert.ok(data.p_result.reply.body.length <= 320);
    return Response.json({ ok: true });
  };
  try { assert.equal(await runSocialInspection(), 1); }
  finally {
    globalThis.fetch = originalFetch;
    if (previousURL === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = previousURL;
    if (previousKey === undefined) delete process.env.SUPABASE_SERVICE_ROLE_KEY; else process.env.SUPABASE_SERVICE_ROLE_KEY = previousKey;
  }
});
