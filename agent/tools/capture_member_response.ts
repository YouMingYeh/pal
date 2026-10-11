import { defineTool } from "eve/tools";
import { checked } from "../../lib/db";
import { jobScope, scopeId } from "../../lib/job-scope";
import { memberResponseInput, prepareMemberResponse, type ResponseState } from "../../lib/member-response";

export default defineTool({
  description: "Record a verified speaker's own explicit dated availability for saved time choices, attendance for a confirmed plan, or confirmation of a current future draft. Dated schedules in this frozen batch may be collected into an availability board created by this same job; vague either/none answers cannot predate the choices. Supply the entire source message as exact evidence; identity, choices and current plan version are checked by the server. Never infer attendance or confirmation from anything works, quote another person, or book anything. Ambiguous responses need one short clarification. After a successful visible action, explain the actual result in natural text.",
  inputSchema: memberResponseInput,
  async execute(input, context) {
    const { db, job, batch } = await jobScope(scopeId(context));
    const state = checked(await db.rpc("pal_group_state", { p_group_id: job.group_id })) as ResponseState;
    const { response } = prepareMemberResponse(input, batch, state, job.group_id, Date.now(), true);
    return checked(await db.rpc("pal_capture_member_response", {
      p_job_id: job.id, p_job_attempt: job.attempts, p_source_message_id: input.source_message_id,
      p_evidence: input.evidence, p_target_kind: input.target_kind, p_target_id: input.target_id, p_response: response,
    }));
  },
});
