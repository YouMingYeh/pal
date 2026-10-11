-- One authenticated round trip for the inbox; every row uses the current membership.
create function private.pal_inbox() returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); result jsonb;
begin
  if u is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if not exists(select 1 from public.groups g join public.group_members m on m.group_id=g.id
      where g.is_direct and g.creator_id=u and m.user_id=u) then
    perform private.ensure_pal_direct();
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id',g.id,'name',g.name,'invite_code',case when g.is_direct then null else g.invite_code end,
      'creator_id',g.creator_id,'avatar_path',g.avatar_path,'is_direct',g.is_direct,
      'last_read_at',m.last_read_at,'last_message',latest.message,'unread_count',unread.total
    ) order by g.is_direct desc,g.created_at,g.id),'[]'::jsonb) into result
    from public.group_members m join public.groups g on g.id=m.group_id
    left join lateral (
      select jsonb_build_object('id',msg.id,'body',msg.body,'created_at',msg.created_at,
        'role',msg.role,'sender_id',msg.sender_id,'card',msg.card) as message
      from public.messages msg where msg.group_id=g.id
        and (msg.source_key is null or (msg.source_key not like 'weekly:%' and msg.source_key not like 'pal:weekly:%'))
      order by msg.created_at desc,msg.id desc limit 1
    ) latest on true
    cross join lateral (
      select count(*) as total from public.messages msg where msg.group_id=g.id
        and msg.sender_id is distinct from u
        and (m.last_read_at is null or msg.created_at>m.last_read_at)
        and (msg.source_key is null or (msg.source_key not like 'weekly:%' and msg.source_key not like 'pal:weekly:%'))
    ) unread
    where m.user_id=u and (not g.is_direct or g.creator_id=u);
  return result;
end $$;
create function public.pal_inbox() returns jsonb language sql set search_path='' as $$
  select private.pal_inbox()
$$;
revoke all on function public.pal_inbox(),private.pal_inbox() from public,anon,authenticated,service_role;
grant execute on function public.pal_inbox(),private.pal_inbox() to authenticated;
