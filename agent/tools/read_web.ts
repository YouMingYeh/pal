import { defineTool } from "eve/tools";
import { z } from "zod";
import { readWeb } from "../../lib/research";
import { httpUrl } from "../../lib/validation";

export default defineTool({
  description: "Read a public page with the guarded research service. Research only: never submit a reservation, payment, form, or login.",
  inputSchema: z.object({ url: httpUrl }),
  execute({ url }) { return readWeb(url); },
});
