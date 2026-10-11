import { defineTool } from "eve/tools";
import { z } from "zod";
import { checked } from "../../lib/db";
import { jobScope, scopeId } from "../../lib/job-scope";

export default defineTool({
  description: "Read verified group members, saved places/sources, current option lists and dated availability boards (polls), draft/confirmed plans with actual attendees, reminders, unexpired speaker-owned preferences/availability, reactions, timezone settings, and fresh opted-in member locations (user_id, latitude, longitude, accuracy, updated_at, expires_at) for this exact group. Missing or expired locations are unknown; no location history or tracking across groups. A missing response is unknown, never unavailable or attending.",
  inputSchema: z.object({}),
  async execute(_input, context) {
    const { db, job } = await jobScope(scopeId(context));
    const state = checked(await db.rpc("pal_group_state", { p_group_id: job.group_id }));
    state.members = state.members.map(({ avatar_path: _path, ...member }: Record<string, unknown>) => member);
    if (state.settings) { const { avatar_path, ...settings } = state.settings; state.settings = settings; }
    return state;
  },
});
