import type { ClientSession, InputRequest, MessageStreamEvent } from "eve/client";

/** A parked human-input request cannot be answered by the group-chat dispatcher. */
export class EveInputPausedError extends Error {}

export class EveResult {
  body: string | undefined;
  structured: unknown;
  boundary = false;
  private failed = false;
  private pending = new Map<string, InputRequest>();

  observe(event: MessageStreamEvent) {
    if (event.type === "turn.started" || event.type === "step.started") this.boundary = false;
    if (event.type === "message.completed" && event.data.finishReason !== "tool-calls") this.body = event.data.message;
    if (event.type === "result.completed") this.structured = event.data.result;
    if (event.type === "input.requested") for (const request of event.data.requests) this.pending.set(request.requestId, request);
    if (event.type === "input.resolved") for (const resolution of event.data.resolutions) this.pending.delete(resolution.requestId);
    if (event.type === "turn.failed" || event.type === "session.failed") this.failed = true;
    if (["session.waiting", "session.completed", "session.failed"].includes(event.type)
      || (event.type === "turn.waiting" && event.data.on === "input")) this.boundary = true;
    // turn.completed and task waits can precede the authoritative result; keep reading.
  }

  settled() {
    if (this.failed) throw new Error("Pal's durable task failed.");
    if (this.pending.size) {
      const budget = [...this.pending.values()].some(request => request.kind === "session-limit");
      throw new EveInputPausedError(budget
        ? "Pal reached its bounded session budget; its existing session is retained for review."
        : "Pal's session requires unsupported interactive input; its existing session is retained for review.");
    }
    if (!this.boundary) throw new Error("Pal's durable task has not finished; its existing session is retained.");
    return { body: this.body, structured: this.structured };
  }
}

export async function recoverEveResult(session: Pick<ClientSession, "snapshot" | "stream">) {
  const collected = new EveResult();
  // Read the complete durable prefix so an already-resolved pause is not mistaken for a new one.
  const snapshot = await session.snapshot({ signal: AbortSignal.timeout(20_000) });
  for (const event of snapshot.events) collected.observe(event);
  if (!collected.boundary) {
    for await (const event of session.stream({ startIndex: snapshot.session.streamIndex, signal: AbortSignal.timeout(240_000) })) {
      collected.observe(event);
      if (collected.boundary) break;
    }
  }
  return collected.settled();
}
