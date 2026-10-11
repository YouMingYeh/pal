import { defineTool } from "eve/tools";
import { checked } from "../../lib/db";
import { agentAction, jobScope, scopeId } from "../../lib/job-scope";
import { availabilityCardInput, prepareAvailabilityCard } from "../../lib/rich-cards";

export default defineTool({
  description: "Save a dated availability board with two to eight concrete proposed times, using the group's timezone and future response deadline before those times. This creates no member responses: everyone remains unknown until their own explicit dated schedule or own edit is recorded. After saving, capture clear matching schedule statements from this job's verified sources using capture_member_response; never infer another person's availability. Return its saved ID as an availability card and ask one useful question. Reuse an existing suitable board rather than making duplicates.",
  inputSchema: availabilityCardInput,
  async execute(input, context) {
    const { db, job } = await jobScope(scopeId(context));
    const state = checked(await db.rpc("pal_group_state", { p_group_id: job.group_id }));
    const data = prepareAvailabilityCard(input, state.settings.timezone);
    return agentAction(context, "poll.create", data, JSON.stringify(data));
  },
});
