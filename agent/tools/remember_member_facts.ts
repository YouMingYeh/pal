import { defineTool } from "eve/tools";
import { jobScope, scopeId } from "../../lib/job-scope";
import { memberFactsInput, saveMemberFacts } from "../../lib/member-memory";

export default defineTool({
  description: "Remember one to eight independent explicitly stated preferences or dated availability facts in one call. Prefer this batch tool when several facts or speakers are present. Every fact needs its own verified human source and verbatim evidence; each fact belongs only to that source's speaker. Never infer or copy another person's facts. Availability needs a future expiry. Use only one fact per speaker/kind/key; this does not set votes or attendance.",
  inputSchema: memberFactsInput,
  async execute(input, context) {
    const scope = await jobScope(scopeId(context));
    return { memories: await saveMemberFacts(input, scope) };
  },
});
