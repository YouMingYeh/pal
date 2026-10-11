import { eveChannel } from "eve/channels/eve";
import { id, matchesSecret } from "../../lib/validation";
import { jobScope } from "../../lib/job-scope";

export default eveChannel({
  auth: async (request) => {
    if (!matchesSecret(request.headers.get("authorization"), process.env.PAL_INTERNAL_SECRET)) return null;
    const jobId = id.parse(request.headers.get("x-pal-job-id"));
    const { job } = await jobScope(jobId);
    return {
      authenticator: "http-basic", principalType: "service", principalId: "pal-backend",
      attributes: { jobId: job.id, jobAttempt: String(job.attempts), groupId: job.group_id, requesterId: job.requester_id },
    };
  },
});
