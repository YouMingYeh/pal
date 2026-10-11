import { defineTool } from "eve/tools";
import { jobScope, scopeId } from "../../lib/job-scope";
import { prepareQuestionCard, questionInput } from "../../lib/question-card";

export default defineTool({
  description: "Prepare one short, useful group question with two to four brief suggested answers. Suggestions help people reply; they are never votes, RSVPs or restrictions on free text. Match the conversation's language and suggest answers from its actual context. Use the question itself as the message body and attach the returned question card to that same conversational output, then call begin_reply immediately before writing that real response. The question is persisted with that message, not by this tool. Members can tap an answer or write anything in chat; taps quote the actual delivered message. This tool never pauses the session or waits for an answer; responses arrive as new chat messages.",
  inputSchema: questionInput,
  async execute(input, context) {
    const { job } = await jobScope(scopeId(context));
    return prepareQuestionCard(input, job.group_id);
  },
});
