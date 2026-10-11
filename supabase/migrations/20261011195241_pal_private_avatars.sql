-- Avatar bytes stay in a private bucket; only the authenticated backend signs them.
alter table public.profiles add column avatar_path text check (
  avatar_path is null or avatar_path ~ ('^'||user_id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$')
);
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('avatars','avatars',false,5242880,array['image/jpeg'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
-- Restrictive policies prevent any unrelated permissive policy granting direct access.
create policy pal_avatars_service_only on storage.objects as restrictive for all to anon,authenticated
  using(bucket_id<>'avatars') with check(bucket_id<>'avatars');
create policy pal_avatar_bucket_service_only on storage.buckets as restrictive for all to anon,authenticated
  using(id<>'avatars') with check(id<>'avatars');

create or replace function private.pal_profile_save(p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); r public.profiles; prefs jsonb; previous text;
begin
  if u is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_data is null or jsonb_typeof(p_data)<>'object' then raise exception 'Profile object required' using errcode='22023'; end if;
  select * into r from public.profiles where user_id=u for update;
  previous:=r.avatar_path;
  prefs:=coalesce(p_data->'notification_preferences',r.notification_preferences,'{"enabled":true}');
  if p_data ? 'notifications_enabled' then prefs:=prefs||jsonb_build_object('enabled',p_data->'notifications_enabled'); end if;
  if jsonb_typeof(prefs)<>'object' or (prefs ? 'enabled' and jsonb_typeof(prefs->'enabled')<>'boolean') then raise exception 'Notification enabled must be boolean' using errcode='22023'; end if;
  insert into public.profiles(user_id,display_name,avatar_url,notification_preferences)
  values(u,coalesce(p_data->>'display_name',r.display_name,'Member'),case when p_data ? 'avatar_url' then p_data->>'avatar_url' else r.avatar_url end,prefs)
  on conflict(user_id) do update set display_name=excluded.display_name,avatar_url=excluded.avatar_url,notification_preferences=excluded.notification_preferences,updated_at=now()
  returning * into r;
  if p_data ? 'avatar_url' and p_data->>'avatar_url' is null then
    update public.profiles set avatar_path=null where user_id=u returning * into r;
    return to_jsonb(r)||jsonb_build_object('_previous_avatar_path',previous);
  end if;
  return to_jsonb(r);
end $$;

create or replace function private.pal_group_state(p_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if current_setting('role',true)<>'service_role' and not exists(select 1 from public.group_members where group_id=p_group_id and user_id=auth.uid()) then
    raise exception 'Group membership required' using errcode='42501';
  end if;
  if not exists(select 1 from public.groups where id=p_group_id) then raise exception 'Group not found' using errcode='22023'; end if;
  return jsonb_build_object(
    'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'display_name',coalesce(p.display_name,'Member'),'avatar_url',p.avatar_url,'avatar_path',p.avatar_path,'last_read_at',m.last_read_at,'last_read_message_id',m.last_read_message_id) order by m.joined_at) from public.group_members m left join public.profiles p on p.user_id=m.user_id where m.group_id=p_group_id),'[]'),
    'places',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('contributors',coalesce((select jsonb_agg(jsonb_build_object('user_id',c.user_id,'source_id',c.source_id)) from public.place_contributors c where c.place_id=p.id),'[]')) order by p.created_at) from public.places p where p.group_id=p_group_id),'[]'),
    'sources',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('contributors',coalesce((select jsonb_agg(to_jsonb(c)) from public.source_contributors c where c.source_id=s.id),'[]')) order by s.created_at) from public.sources s where s.group_id=p_group_id),'[]'),
    'polls',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('responses',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'option_ids',r.option_ids) order by r.user_id) from public.poll_responses r where r.poll_id=p.id),'[]'),'votes',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'option_id',o)) from public.poll_responses r cross join lateral unnest(r.option_ids) o where r.poll_id=p.id),'[]')) order by p.created_at) from public.polls p where p.group_id=p_group_id),'[]'),
    'plans',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('attendees',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'status',r.status)) from public.plan_rsvps r where r.plan_id=p.id),'[]')) order by p.starts_at) from public.plans p where p.group_id=p_group_id),'[]'),
    'memories',coalesce((select jsonb_agg(to_jsonb(m)||jsonb_build_object('body',m.key||': '||m.value) order by m.updated_at) from public.member_memories m where m.group_id=p_group_id and (m.expires_at is null or m.expires_at>now())),'[]'),
    'reminders',coalesce((select jsonb_agg(to_jsonb(r) order by r.due_at) from public.reminders r where r.group_id=p_group_id),'[]'),
    'reactions',coalesce((select jsonb_agg(to_jsonb(r)) from public.message_reactions r where r.group_id=p_group_id),'[]'),
    'settings',(select jsonb_build_object('name',g.name,'timezone',g.timezone,'proactive_suggestions',g.proactive_suggestions,'agent_paused',g.agent_paused) from public.groups g where id=p_group_id)
  );
end $$;

create function private.pal_avatar_replace(p_user_id uuid,p_avatar_path text,p_display_name text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.profiles; previous text;
begin
  if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
  if p_user_id is null then raise exception 'User required' using errcode='22023'; end if;
  if p_display_name is not null and length(btrim(p_display_name)) not between 1 and 60 then raise exception 'Display name must contain 1-60 characters' using errcode='22023'; end if;
  if p_avatar_path is not null and p_avatar_path !~ ('^'||p_user_id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$') then
    raise exception 'Owner-scoped UUID JPEG path required' using errcode='22023';
  end if;
  insert into public.profiles(user_id,display_name) values(p_user_id,'Member') on conflict(user_id) do nothing;
  select * into r from public.profiles where user_id=p_user_id for update;
  previous:=r.avatar_path;
  update public.profiles set avatar_path=p_avatar_path,avatar_url=null,display_name=coalesce(btrim(p_display_name),display_name),updated_at=now() where user_id=p_user_id returning * into r;
  return jsonb_build_object('profile',to_jsonb(r),'previous_path',previous);
end $$;
create function public.pal_avatar_replace(p_user_id uuid,p_avatar_path text,p_display_name text default null) returns jsonb
language sql set search_path='' as $$ select private.pal_avatar_replace(p_user_id,p_avatar_path,p_display_name) $$;
revoke all on function public.pal_avatar_replace(uuid,text,text),private.pal_avatar_replace(uuid,text,text) from public,anon,authenticated;
grant execute on function public.pal_avatar_replace(uuid,text,text),private.pal_avatar_replace(uuid,text,text) to service_role;
