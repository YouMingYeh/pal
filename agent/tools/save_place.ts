import { defineTool } from "eve/tools";
import { z } from "zod";
import { agentAction } from "../../lib/job-scope";
import { id } from "../../lib/validation";
import { resolvePlace } from "../../lib/maps";

export default defineTool({
  description: "Save a verified place candidate from find_places. No invented coordinates, address, reservation availability, or booking status.",
  inputSchema: z.object({ query: z.string().trim().min(1).max(200), provider_id: z.string().min(1).max(300), source_id: id.optional() }),
  async execute({ query, provider_id, source_id }, context) {
    const candidate = (await resolvePlace(query)).find(place => place.provider_id === provider_id);
    if (!candidate) throw new Error("The requested place is not a verified search candidate.");
    return agentAction(context, "place.save", {
      name: candidate.name, address: candidate.address, latitude: candidate.latitude, longitude: candidate.longitude,
      provider: "apple", provider_id: candidate.provider_id,
      ...(candidate.website ? { website: candidate.website } : {}), ...(source_id ? { source_id } : {}),
    }, provider_id);
  },
});
