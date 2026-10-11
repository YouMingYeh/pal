import { defineAgent } from "eve";
import { openai } from "eve/models/openai";

export default defineAgent({
  model: openai(process.env.OPENAI_MODEL || "gpt-5-mini"),
  defaultTools: false,
  tool: false,
  reasoning: "low",
  limits: { maxInputTokensPerSession: 30000, maxOutputTokensPerSession: 4000 },
});
