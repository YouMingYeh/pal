import { defineTool } from "eve/tools";
import { checked } from "../../lib/db";
import { jobScope, scopeId } from "../../lib/job-scope";
import { memberResponseInput, prepareMemberResponse, type ResponseState } from "../../lib/member-response";

export default defineTool({
  description: "Record the verified speaker's own explicit message response to an existing open poll or confirmed plan. Supply the entire source message as exact evidence. Never infer RSVP from anything works, quote another person, confirm a plan or book anything. Ambiguous responses require one short clarification.",
  inputSchema: memberResponseInput,
  async execute(input, context) {
    const { db, job, batch } = await jobScope(scopeId(context));
    const state = checked(await db.rpc("pal_group_state", { p_group_id: job.group_id })) as ResponseState;
    const { response } = prepareMemberResponse(input, batch, state, job.group_id);
    return checked(await db.rpc("pal_capture_member_response", {
      p_job_id: job.id, p_job_attempt: job.attempts, p_source_message_id: input.source_message_id,
      p_evidence: input.evidence, p_target_kind: input.target_kind, p_target_id: input.target_id, p_response: response,
    }));
  },
});
