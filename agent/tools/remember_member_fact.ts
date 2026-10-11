import { defineTool } from "eve/tools";
import { jobScope, scopeId } from "../../lib/job-scope";
import { memberFactInput, saveMemberFacts } from "../../lib/member-memory";

export default defineTool({
  description: "Remember only a speaker's own explicitly stated preference or dated availability, with a real source message and verbatim evidence. Never infer another person's facts.",
  inputSchema: memberFactInput,
  async execute(input, context) {
    const scope = await jobScope(scopeId(context));
    return (await saveMemberFacts({ facts: [input] }, scope))[0];
  },
});
