import { z } from "zod";

export const questionInput = z.object({
  question: z.string().trim().min(1).max(200),
  suggestions: z.array(z.string().trim().min(1).max(60)).min(2).max(4)
    .refine(values => new Set(values.map(value => value.toLowerCase())).size === values.length, "Suggest each answer once."),
}).strict();

export const questionCard = questionInput.extend({ type: z.literal("question"), entity_id: z.string().uuid() }).strict();

export function prepareQuestionCard(input: unknown, groupId: string) {
  return questionCard.parse({ ...questionInput.parse(input), type: "question", entity_id: groupId });
}
