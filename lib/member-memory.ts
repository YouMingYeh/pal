import { z } from "zod";
import { agentActionInScope, batchSpeaker, type jobScope, type SourceMessage } from "./job-scope";
import { actionSchemas, id } from "./validation";

export const memberFactInput = z.object({
  source_message_id: id, evidence: z.string().trim().min(1).max(1000),
  kind: z.enum(["preference", "availability"]), key: z.string().trim().min(1).max(80),
  value: z.string().trim().min(1).max(1000), expires_at: z.string().datetime({ offset: true }).nullable().optional(),
}).strict();
export const memberFactsInput = z.object({ facts: z.array(memberFactInput).min(1).max(8) }).strict();

export function prepareMemberFacts(input: unknown, batch: SourceMessage[], now = Date.now()) {
  const { facts } = memberFactsInput.parse(input);
  const identities = new Set<string>();
  return facts.map(({ evidence, ...data }) => {
    const source = batchSpeaker(batch, data.source_message_id);
    if (!source.body.includes(evidence)) throw new Error("Evidence must quote the source message exactly.");
    if (data.kind === "availability" && (!data.expires_at || Date.parse(data.expires_at) <= now)) {
      throw new Error("Availability needs a future expiry.");
    }
    const memberKey = JSON.stringify([source.sender_id, data.kind, data.key]);
    if (identities.has(memberKey)) throw new Error("Choose one fact per speaker, kind and key in a batch.");
    identities.add(memberKey);
    return { data: actionSchemas["memory.save"].parse(data), source,
      identity: `${source.id}:${data.kind}:${data.key}` };
  });
}

export async function saveMemberFacts(input: unknown, scope: Awaited<ReturnType<typeof jobScope>>) {
  // Complete all source/evidence checks before starting independent writes. Successful partial writes are retry-safe.
  const facts = prepareMemberFacts(input, scope.batch);
  return Promise.all(facts.map(({ data, source, identity }) =>
    agentActionInScope(scope, "memory.save", data, identity, source.id)));
}
