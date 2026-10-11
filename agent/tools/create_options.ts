import { defineTool } from "eve/tools";
import { checked } from "../../lib/db";
import { agentAction, jobScope, scopeId } from "../../lib/job-scope";
import { optionsCardInput, prepareOptionsCard } from "../../lib/rich-cards";

export default defineTool({
  description: "Save two to eight useful options for a requested group outing. For restaurants/venues, use resolved saved place IDs from current group state; the server uses their actual names. For activity inspiration, supply a short honest idea without unverified venue, price or availability claims. This creates no votes or attendance. Return the saved ID as an options card with a natural short introduction; people can answer in chat. Do not create duplicate lists when an existing one fits.",
  inputSchema: optionsCardInput,
  async execute(input, context) {
    const { db, job } = await jobScope(scopeId(context));
    const state = checked(await db.rpc("pal_group_state", { p_group_id: job.group_id }));
    const data = prepareOptionsCard(input, state.places, job.group_id);
    return agentAction(context, "poll.create", data, JSON.stringify(data));
  },
});
