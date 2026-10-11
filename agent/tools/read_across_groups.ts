import { defineTool } from "eve/tools";
import { jobScope, scopeId } from "../../lib/job-scope";
import { acrossGroupsInput, readAcrossGroups } from "../../lib/across-groups";

export default defineTool({
  description: "Only in the verified owner's private Pal chat: read recent messages, plans, places and the owner's explicit preferences from currently joined groups. Results are bounded pages with source timestamps; use next_offset or a literal query when needed. Shared group jobs are forbidden. This never changes another group.",
  inputSchema: acrossGroupsInput,
  async execute(input, context) {
    return readAcrossGroups(input, await jobScope(scopeId(context)));
  },
});
