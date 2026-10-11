import assert from "node:assert/strict";
import { test } from "node:test";
import { GET } from "../app/api/groups/[id]/messages/route";
import { GET as inboxGET } from "../app/api/groups/route";

const group = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", user = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const parent = "cccccccc-cccc-4ccc-8ccc-cccccccccccc", child = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const outside = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";

test("history reuses in-page quotes and only fetches missing parents within the current group", async () => {
  const originalFetch = globalThis.fetch;
  const previousURL = process.env.SUPABASE_URL, previousKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  process.env.SUPABASE_URL = "https://test.supabase.co";
  process.env.SUPABASE_PUBLISHABLE_KEY = "test-publishable-key";
  let readAllowed = true, includeOutside = false, historyReads = 0;
  const parentQueries: URL[] = [];
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    assert.equal(new Headers(init?.headers).get("authorization"), "Bearer test-owner-token");
    if (url.pathname === "/auth/v1/user") return Response.json({ id: user, email: "test@example.invalid" });
    if (url.pathname === "/rest/v1/group_members") {
      assert.equal(url.searchParams.get("group_id"), `eq.${group}`);
      assert.equal(url.searchParams.get("user_id"), `eq.${user}`);
      return Response.json(readAllowed ? [{ group_id: group }] : []);
    }
    if (url.pathname === "/rest/v1/message_attachments") return Response.json([]);
    assert.equal(url.pathname, "/rest/v1/messages");
    assert.equal(url.searchParams.get("group_id"), `eq.${group}`);
    if (url.searchParams.has("id")) {
      parentQueries.push(url);
      assert.equal(url.searchParams.get("id"), `in.(${outside})`);
      assert.equal(url.searchParams.get("role"), "in.(user,pal)");
      return Response.json([{ id: outside, sender_id: user, role: "user", body: "Older than the history page." }]);
    }
    historyReads += 1;
    assert.equal(url.searchParams.get("limit"), "200");
    assert.equal(url.searchParams.get("or"), "(source_key.is.null,and(source_key.not.like.weekly:%,source_key.not.like.pal:weekly:%))");
    const messages = [
      { id: child, group_id: group, sender_id: user, role: "user", body: "Friday works.", created_at: "2026-10-11T12:00:01Z", reply_to_id: parent },
      { id: parent, group_id: group, sender_id: null, role: "pal", body: "a".repeat(800), created_at: "2026-10-11T12:00:00Z", reply_to_id: null },
    ];
    if (includeOutside) messages[1].reply_to_id = outside;
    return Response.json(messages);
  };
  const request = () => new Request(`https://pal.example/api/groups/${group}/messages`, { headers: { authorization: "Bearer test-owner-token" } });
  const context = () => ({ params: Promise.resolve({ id: group }) });
  try {
    const response = await GET(request(), context());
    assert.equal(response.status, 200);
    const { messages } = await response.json();
    assert.deepEqual(messages.map((message: { id: string }) => message.id), [parent, child]);
    assert.equal(messages[1].reply.id, parent);
    assert.equal(messages[1].reply.body.length, 500);
    assert.equal(messages[0].body.length, 800, "Only the quote is abbreviated.");
    assert.equal(parentQueries.length, 0, "An already loaded quote needs no extra database read.");
    includeOutside = true;
    const extended = await (await GET(request(), context())).json();
    assert.equal(parentQueries.length, 1);
    assert.equal(extended.messages[0].reply.id, outside, "Older quotes remain available.");
    readAllowed = false;
    assert.equal((await GET(request(), context())).status, 403);
    assert.equal(historyReads, 2, "Membership denial stops all history reads.");
  } finally {
    globalThis.fetch = originalFetch;
    if (previousURL === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = previousURL;
    if (previousKey === undefined) delete process.env.SUPABASE_PUBLISHABLE_KEY; else process.env.SUPABASE_PUBLISHABLE_KEY = previousKey;
  }
});

test("inbox uses one owner-scoped RPC regardless of the number of groups and strips private photo paths", async () => {
  const originalFetch = globalThis.fetch;
  const previousURL = process.env.SUPABASE_URL, previousKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  process.env.SUPABASE_URL = "https://test.supabase.co";
  process.env.SUPABASE_PUBLISHABLE_KEY = "test-publishable-key";
  const requests: string[] = [];
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    requests.push(url.pathname);
    assert.equal(new Headers(init?.headers).get("authorization"), "Bearer test-owner-token");
    if (url.pathname === "/auth/v1/user") return Response.json({ id: user, email: "test@example.invalid" });
    assert.equal(url.pathname, "/rest/v1/rpc/pal_inbox");
    assert.deepEqual(JSON.parse(String(init?.body)), {}, "The inbox owner comes from verified JWT identity, not caller input.");
    return Response.json(Array.from({ length: 8 }, (_, index) => ({ id: `room-${index}`, name: `Room ${index}`,
      creator_id: user, avatar_path: "not-owned", is_direct: index === 0, invite_code: index === 0 ? null : parent,
      last_read_at: null, last_message: index === 0 ? null : { id: child, body: "Dinner?" }, unread_count: index })));
  };
  try {
    const response = await inboxGET(new Request("https://pal.example/api/groups", { headers: { authorization: "Bearer test-owner-token" } }));
    assert.equal(response.status, 200);
    const { groups } = await response.json();
    assert.equal(groups.length, 8);
    assert.equal(groups[0].invite_code, null);
    assert.equal(groups[7].unread_count, 7);
    assert.equal(groups[1].last_message.body, "Dinner?");
    assert.ok(groups.every((row: Record<string, unknown>) => !("avatar_path" in row) && row.avatar_url === null));
    assert.deepEqual(requests, ["/auth/v1/user", "/rest/v1/rpc/pal_inbox"], "Inbox has no per-group database calls.");
  } finally {
    globalThis.fetch = originalFetch;
    if (previousURL === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = previousURL;
    if (previousKey === undefined) delete process.env.SUPABASE_PUBLISHABLE_KEY; else process.env.SUPABASE_PUBLISHABLE_KEY = previousKey;
  }
});

test("group state uses one authoritative membership-checked RPC and retains outsider denial", async () => {
  const { GET: stateGET } = await import("../app/api/groups/[id]/state/route");
  const originalFetch = globalThis.fetch;
  const previousURL = process.env.SUPABASE_URL, previousKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  process.env.SUPABASE_URL = "https://test.supabase.co";
  process.env.SUPABASE_PUBLISHABLE_KEY = "test-publishable-key";
  let allowed = true, reads = 0;
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    if (url.pathname === "/auth/v1/user") return Response.json({ id: user });
    assert.equal(url.pathname, "/rest/v1/rpc/pal_group_state", "No redundant membership or state query.");
    assert.deepEqual(JSON.parse(String(init?.body)), { p_group_id: group });
    reads += 1;
    return allowed ? Response.json({ members: [], settings: { name: "Group" } })
      : Response.json({ message: "Group membership required", code: "42501" }, { status: 403 });
  };
  try {
    const request = () => new Request(`https://pal.example/api/groups/${group}/state`, { headers: { authorization: "Bearer test-owner-token" } });
    assert.equal((await stateGET(request(), { params: Promise.resolve({ id: group }) })).status, 200);
    assert.equal(reads, 1);
    allowed = false;
    assert.equal((await stateGET(request(), { params: Promise.resolve({ id: group }) })).status, 403);
    assert.equal(reads, 2);
  } finally {
    globalThis.fetch = originalFetch;
    if (previousURL === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = previousURL;
    if (previousKey === undefined) delete process.env.SUPABASE_PUBLISHABLE_KEY; else process.env.SUPABASE_PUBLISHABLE_KEY = previousKey;
  }
});
