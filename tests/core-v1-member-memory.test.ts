import assert from "node:assert/strict";
import { test } from "node:test";
import type { admin } from "../lib/db";
import { actionSourceKey, type Job, type SourceMessage } from "../lib/job-scope";
import { memberFactsInput, prepareMemberFacts, saveMemberFacts } from "../lib/member-memory";

const group = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const aliceMessage = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const bobMessage = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const batch: SourceMessage[] = [
  { id: aliceMessage, group_id: group, sender_id: "alice", role: "user", body: "I am vegetarian. Friday October 16 after 7 works for me.", created_at: "2026-10-11T23:00:00Z" },
  { id: bobMessage, group_id: group, sender_id: "bob", role: "user", body: "My dinner budget is $30.", created_at: "2026-10-11T23:00:01Z" },
];
const aliceFact = { source_message_id: aliceMessage, evidence: "I am vegetarian", kind: "preference" as const, key: "diet", value: "vegetarian" };
const bobFact = { source_message_id: bobMessage, evidence: "My dinner budget is $30", kind: "preference" as const, key: "budget", value: "$30" };
const job: Job = { id: group, group_id: group, requester_id: "alice", message_id: aliceMessage, status: "running", attempts: 1, result: null, lease_until: "2099-01-01T00:00:00Z" };

test("memory batches keep each fact attributed to its verified source speaker and preserve retry identity", () => {
  const prepared = prepareMemberFacts({ facts: [aliceFact, bobFact] }, batch);
  assert.deepEqual(prepared.map(fact => fact.source.sender_id), ["alice", "bob"]);
  assert.equal(prepared[1].data.source_message_id, bobMessage);
  assert.equal(prepared[0].identity, `${aliceMessage}:preference:diet`, "The original single-fact identity remains compatible.");
  assert.throws(() => prepareMemberFacts({ facts: [{ ...bobFact, source_message_id: group }] }, batch), /verified batch/);
  assert.throws(() => prepareMemberFacts({ facts: [{ ...bobFact, evidence: "I am vegetarian" }] }, batch), /quote the source/);
  assert.throws(() => memberFactsInput.parse({ facts: [{ ...bobFact, user_id: "alice" }] }));
});

test("memory batches refuse expired, duplicate, oversized and otherwise unsupported facts", () => {
  const availability = { ...aliceFact, kind: "availability", key: "friday", value: "Free October 16 after 7", evidence: "Friday October 16 after 7 works for me." };
  assert.throws(() => prepareMemberFacts({ facts: [availability] }, batch), /future expiry/);
  assert.throws(() => prepareMemberFacts({ facts: [{ ...availability, expires_at: "2026-10-11T22:00:00Z" }] }, batch, Date.parse("2026-10-11T23:00:00Z")), /future expiry/);
  assert.equal(prepareMemberFacts({ facts: [{ ...availability, expires_at: "2026-10-17T00:00:00Z" }] }, batch, Date.parse("2026-10-11T23:00:00Z"))[0].data.kind, "availability");
  assert.throws(() => prepareMemberFacts({ facts: [aliceFact, { ...aliceFact, value: "Different preference" }] }, batch), /one fact per speaker/);
  assert.throws(() => memberFactsInput.parse({ facts: Array(9).fill(aliceFact) }));
  assert.throws(() => memberFactsInput.parse({ facts: [] }));
});

test("a bad later fact causes zero writes, while independent facts share scope and keep SQL guards", async () => {
  const calls: Record<string, unknown>[] = [];
  const releases: (() => void)[] = [];
  const db = { rpc: async (name: string, args: Record<string, unknown>) => {
    assert.equal(name, "pal_agent_action");
    calls.push(args);
    await new Promise<void>(resolve => releases.push(resolve));
    return { data: { id: calls.length }, error: null };
  } } as unknown as ReturnType<typeof admin>;
  const scope = { job, db, batch };
  await assert.rejects(saveMemberFacts({ facts: [aliceFact, { ...bobFact, evidence: "not in source" }] }, scope), /quote the source/);
  assert.equal(calls.length, 0);
  const writing = saveMemberFacts({ facts: [aliceFact, bobFact] }, scope);
  assert.equal(calls.length, 2, "Both RPCs start without a second jobScope read or waiting for the other independent fact.");
  assert.deepEqual(calls.map(call => call.p_requester_id), ["alice", "bob"]);
  for (const [index, call] of calls.entries()) {
    assert.equal(call.p_group_id, group);
    assert.equal(call.p_action, "memory.save");
    const data = call.p_data as Record<string, unknown>;
    assert.equal(data.job_id, job.id, "The SQL mutation still receives the active job for authoritative lease checks.");
    assert.equal(data.source_key, actionSourceKey(job.id, "memory.save", `${batch[index].id}:preference:${index ? "budget" : "diet"}`));
    assert.equal(data.evidence, undefined, "Verbatim evidence is checked server-side rather than becoming an unsupported SQL field.");
  }
  releases.forEach(release => release());
  assert.equal((await writing).length, 2);
});

test("SQL refusal is surfaced without discarding successful independent writes or changing retry keys", async () => {
  const keys: unknown[] = [];
  let allowBob = false;
  const db = { rpc: async (_: string, args: Record<string, unknown>) => {
    keys.push((args.p_data as Record<string, unknown>).source_key);
    return args.p_requester_id === "bob" && !allowBob
      ? { data: null, error: { code: "42501", message: "Source membership was removed." } }
      : { data: { id: "persisted-memory" }, error: null };
  } } as unknown as ReturnType<typeof admin>;
  const scope = { job, db, batch };
  await assert.rejects(saveMemberFacts({ facts: [aliceFact, bobFact] }, scope), /membership was removed/);
  allowBob = true;
  await saveMemberFacts({ facts: [aliceFact, bobFact] }, scope);
  assert.deepEqual(keys.slice(0, 2), keys.slice(2), "Retries reuse each original RPC receipt; accepted facts are not recreated.");
});
