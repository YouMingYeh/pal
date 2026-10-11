import { authenticated, route } from "../../../lib/http";
import { checked } from "../../../lib/db";
import { groupInput } from "../../../lib/validation";

export function GET(request: Request) {
  return route(async () => {
    const { db, user } = await authenticated(request);
    const groups = checked(await db.from("groups").select("id,name,invite_code").order("created_at"));
    if (!groups?.length) return Response.json({ groups: [] });
    const memberships = checked(await db.from("group_members").select("group_id,last_read_at")
      .eq("user_id", user.id).in("group_id", groups.map(group => group.id)));
    // shortcut: two queries per group; replace with a SQL inbox summary when groups grow beyond a small inbox.
    const summaries = await Promise.all(groups.map(async group => {
      const lastReadAt = memberships?.find(member => member.group_id === group.id)?.last_read_at ?? null;
      let unreadQuery = db.from("messages").select("id", { count: "exact", head: true })
        .eq("group_id", group.id).or(`sender_id.neq.${user.id},sender_id.is.null`)
        .or("source_key.is.null,source_key.not.like.weekly:%");
      if (lastReadAt) unreadQuery = unreadQuery.gt("created_at", lastReadAt);
      const [latest, unread] = await Promise.all([
        db.from("messages").select("id,body,created_at,role,sender_id,card").eq("group_id", group.id)
          .or("source_key.is.null,source_key.not.like.weekly:%")
          .order("created_at", { ascending: false }).order("id", { ascending: false }).limit(1).maybeSingle(), unreadQuery,
      ]);
      checked(latest); checked(unread);
      return { ...group, last_read_at: lastReadAt, last_message: latest.data, unread_count: unread.count ?? 0 };
    }));
    return Response.json({ groups: summaries });
  });
}

export function POST(request: Request) {
  return route(async () => {
    const { db } = await authenticated(request);
    const { name } = groupInput.parse(await request.json());
    return Response.json({ group: checked(await db.rpc("create_group", { p_name: name })) }, { status: 201 });
  });
}
