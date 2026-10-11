import { member, route } from "../../../../../../../lib/http";
import { id as uuid } from "../../../../../../../lib/validation";
import { readMemberSummaryContext, summarizeMember } from "../../../../../../../lib/member-summary";

export const maxDuration = 60;
type Context = { params: Promise<{ id: string; memberId: string }> };

export function GET(request: Request, context: Context) {
  return route(async () => {
    const params = await context.params;
    const id = uuid.parse(params.id).toLowerCase(), memberId = uuid.parse(params.memberId).toLowerCase();
    const { db } = await member(request, id);
    const shared = await readMemberSummaryContext(db, id, memberId);
    const summary = await summarizeMember(id, memberId, shared);
    return Response.json({ ...summary,
      availability: shared.memories.filter(memory => memory.kind === "availability"),
      preferences: shared.memories.filter(memory => memory.kind === "preference"),
      generated_at: new Date().toISOString(),
    }, { headers: { "Cache-Control": "private, no-store" } });
  });
}
