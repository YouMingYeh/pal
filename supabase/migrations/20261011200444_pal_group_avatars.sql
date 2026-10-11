-- Reuse the private JPEG avatar bucket and existing action receipts.
alter table public.groups add column avatar_path text check(
  avatar_path is null or avatar_path ~ ('^groups/'||creator_id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$')
);
create unique index group_create_receipt_user_key on private.action_receipts(user_id,source_key) where action='group.create';

create function private.pal_group_create(p_user_id uuid,p_client_id uuid,p_name text,p_avatar_path text default null,p_sha256 text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.groups; receipt private.action_receipts; input jsonb; prior_sub text;
begin
  if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
  if p_user_id is null or not exists(select 1 from auth.users where id=p_user_id) then raise exception 'Authenticated user required' using errcode='42501'; end if;
  if p_client_id is null or p_name is null or length(btrim(p_name)) not between 1 and 80 then raise exception 'Valid client ID and group name required' using errcode='22023'; end if;
  if p_avatar_path is null then
    if p_sha256 is not null then raise exception 'Avatar hash requires a file' using errcode='22023'; end if;
  elsif p_avatar_path !~ ('^groups/'||p_user_id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$') or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'Owner-scoped group avatar JPEG and source hash required' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('pal-group-create:'||p_user_id||':'||p_client_id,0));
  input:=jsonb_build_object('name',btrim(p_name),'avatar_sha256',p_sha256);
  select * into receipt from private.action_receipts where user_id=p_user_id and action='group.create' and source_key=p_client_id::text;
  if found then
    if receipt.input<>input then raise exception 'Client ID already used for another group creation' using errcode='22023'; end if;
    select * into g from public.groups where id=receipt.group_id for update;
    if not found or not exists(select 1 from public.group_members where group_id=g.id and user_id=p_user_id) then raise exception 'Group membership required' using errcode='42501'; end if;
    return jsonb_build_object('group',to_jsonb(g),'uploaded_path_used',g.avatar_path is not distinct from p_avatar_path);
  end if;
  prior_sub:=current_setting('request.jwt.claim.sub',true);
  perform set_config('request.jwt.claim.sub',p_user_id::text,true);
  begin
    g:=private.create_group(p_name);
  exception when others then
    perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
    raise;
  end;
  perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
  if p_avatar_path is not null then update public.groups set avatar_path=p_avatar_path where id=g.id returning * into g; end if;
  insert into private.action_receipts(group_id,user_id,action,source_key,input,result)
  values(g.id,p_user_id,'group.create',p_client_id::text,input,to_jsonb(g));
  return jsonb_build_object('group',to_jsonb(g),'uploaded_path_used',true);
end $$;
create function public.pal_group_create(p_user_id uuid,p_client_id uuid,p_name text,p_avatar_path text default null,p_sha256 text default null)
returns jsonb language sql set search_path='' as $$ select private.pal_group_create(p_user_id,p_client_id,p_name,p_avatar_path,p_sha256) $$;
revoke all on function public.pal_group_create(uuid,uuid,text,text,text),private.pal_group_create(uuid,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.pal_group_create(uuid,uuid,text,text,text),private.pal_group_create(uuid,uuid,text,text,text) to service_role;

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
    'settings',(select jsonb_build_object('name',g.name,'creator_id',g.creator_id,'avatar_path',g.avatar_path,'timezone',g.timezone,'proactive_suggestions',g.proactive_suggestions,'agent_paused',g.agent_paused) from public.groups g where id=p_group_id)
  );
end $$;
