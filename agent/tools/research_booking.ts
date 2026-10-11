import { defineTool } from "eve/tools";
import { z } from "zod";
import { checked } from "../../lib/db";
import { agentAction, jobScope, scopeId } from "../../lib/job-scope";
import { verifyBookingLink } from "../../lib/booking";
import { httpUrl, id } from "../../lib/validation";

export default defineTool({
  description: "Find, verify and save a venue's booking link for an existing resolved group place. This tool searches and checks readable sources, venue and branch itself. Optionally verify a proposed URL. It never checks table availability, submits a reservation, or changes booking status. The user opens the saved link to book.",
  inputSchema: z.object({ place_id: id, url: httpUrl.optional() }).strict(),
  async execute({ place_id, url }, context) {
    const { db, job } = await jobScope(scopeId(context));
    const place = checked(await db.from("places").select("id,name,address,website,status")
      .eq("id", place_id).eq("group_id", job.group_id).maybeSingle());
    if (!place || place.status !== "resolved") throw new Error("Choose an existing resolved place in this group.");
    const evidence = await verifyBookingLink(place, url);
    const saved = await agentAction(context, "place.correct", { id: place_id, booking_url: evidence.url }, `booking:${place_id}:${evidence.url}`);
    return { place_id: saved.id, booking_url: saved.booking_url, evidence, reservation_status: "not_checked" };
  },
});
