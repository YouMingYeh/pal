import { defineTool } from "eve/tools";
import { z } from "zod";
import { resolvePlace } from "../../lib/maps";

export default defineTool({
  description: "Search verified Apple place candidates. Returned provider IDs and coordinates are the only ones save_place accepts.",
  inputSchema: z.object({ query: z.string().trim().min(1).max(200) }),
  execute({ query }) { return resolvePlace(query); },
});
