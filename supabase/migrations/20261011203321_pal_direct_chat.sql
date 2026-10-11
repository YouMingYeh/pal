alter table public.groups add column is_direct boolean not null default false;
create unique index one_pal_direct_per_creator on public.groups(creator_id) where is_direct;

create function private.pal_direct_member_guard() returns trigger language plpgsql set search_path='' as $$
begin
  if exists(select 1 from public.groups where id=new.group_id and is_direct and creator_id<>new.user_id) then
    raise exception 'Direct chats have only their owner as a human member' using errcode='42501';
  end if;
  return new;
end $$;
revoke all on function private.pal_direct_member_guard() from public,anon,authenticated,service_role;
create trigger pal_direct_member_guard before insert or update on public.group_members for each row execute function private.pal_direct_member_guard();

create function private.ensure_pal_direct() returns public.groups language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); g public.groups;
begin
  if u is null then raise exception 'Authentication required' using errcode='42501'; end if;
  insert into public.groups(name,creator_id,is_direct,proactive_suggestions)
    values('Pal',u,true,false) on conflict(creator_id) where is_direct do nothing returning * into g;
  if not found then select * into g from public.groups where creator_id=u and is_direct; end if;
  insert into public.group_members(group_id,user_id) values(g.id,u) on conflict do nothing;
  return g;
end $$;
create function public.ensure_pal_direct() returns public.groups language sql set search_path='' as $$ select private.ensure_pal_direct() $$;
revoke all on function public.ensure_pal_direct(),private.ensure_pal_direct() from public,anon,authenticated,service_role;
grant execute on function public.ensure_pal_direct(),private.ensure_pal_direct() to authenticated;

create or replace function private.join_group(p_invite_code uuid) returns public.groups
language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); g public.groups;
begin
  if u is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select * into g from public.groups where invite_code=p_invite_code;
  if not found then raise exception 'Invalid invite code' using errcode='22023'; end if;
  if g.is_direct then raise exception 'Private Pal chats cannot be joined by invitation' using errcode='42501'; end if;
  insert into public.group_members(group_id,user_id) values(g.id,u) on conflict do nothing;
  return g;
end $$;

create function private.pal_direct_job_ready() returns trigger language plpgsql set search_path='' as $$
begin
  if new.job_kind='chat' and exists(select 1 from public.groups where id=new.group_id and is_direct) then
    new.run_after:=now(); new.explicit_mention:=true;
  end if;
  return new;
end $$;
revoke all on function private.pal_direct_job_ready() from public,anon,authenticated,service_role;
create trigger pal_direct_job_ready before insert on public.agent_jobs for each row execute function private.pal_direct_job_ready();

create function private.pal_read_across_groups(p_job_id uuid,p_attempt integer,p_offset integer default 0,p_query text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.agent_jobs; r record; q text:=nullif(btrim(p_query),''); item jsonb; items jsonb:='[]'; count_groups integer:=0; next_page integer; cut boolean; any_cut boolean:=false;
begin
  if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
  if p_offset is null or p_offset not between 0 and 1000 or length(p_query)>100 then raise exception 'Valid bounded page and query required' using errcode='22023'; end if;
  select * into j from public.agent_jobs where id=p_job_id;
  if not found then raise exception 'Active private chat job required' using errcode='42501'; end if;
  perform 1 from public.groups where id=j.group_id and is_direct and creator_id=j.requester_id and not agent_paused for share;
  if not found then raise exception 'Owner private chat required' using errcode='42501'; end if;
  select * into j from public.agent_jobs where id=p_job_id and attempts=p_attempt and status='running' and job_kind='chat' and lease_until>now() for share;
  if not found then raise exception 'Active job lease and attempt required' using errcode='42501'; end if;
  perform 1 from public.group_members where group_id=j.group_id and user_id=j.requester_id for share;
  if not found then raise exception 'Current private chat membership required' using errcode='42501'; end if;
  for r in select g.* from public.groups g join public.group_members m on m.group_id=g.id and m.user_id=j.requester_id
    where not g.is_direct and (q is null or position(lower(q) in lower(g.name))>0 or exists(
      select 1 from (select body from public.messages where group_id=g.id and (source_key is null or (source_key not like 'weekly:%' and source_key not like 'pal:weekly:%')) order by created_at desc,id desc limit 20) recent where position(lower(q) in lower(recent.body))>0))
    order by g.id limit 6 offset p_offset for share of m
  loop
    count_groups:=count_groups+1;
    if count_groups=6 then next_page:=p_offset+5; any_cut:=true; exit; end if;
    item:=jsonb_build_object('id',r.id,'name',r.name,'timezone',r.timezone,
      'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',mm.user_id,'display_name',coalesce(p.display_name,'Member')) order by mm.joined_at,mm.user_id)
        from (select * from public.group_members where group_id=r.id order by joined_at,user_id limit 100) mm left join public.profiles p on p.user_id=mm.user_id),'[]'),
      'messages',coalesce((select jsonb_agg(jsonb_build_object('id',mm.id,'sender_id',mm.sender_id,'role',mm.role,'body',left(mm.body,500),'body_truncated',length(mm.body)>500,'created_at',mm.created_at,'reply_to_id',mm.reply_to_id,'card',mm.card,'emotion',mm.emotion) order by mm.created_at,mm.id)
        from (select * from public.messages where group_id=r.id and (source_key is null or (source_key not like 'weekly:%' and source_key not like 'pal:weekly:%')) order by created_at desc,id desc limit 20) mm),'[]'),
      'plans',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'title',p.title,'starts_at',p.starts_at,'ends_at',p.ends_at,'status',p.status,'place_id',p.place_id,'booking_status',p.booking_status,'updated_at',p.updated_at) order by p.updated_at desc,p.id)
        from (select * from public.plans where group_id=r.id order by updated_at desc,id limit 10) p),'[]'),
      'places',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'address',left(p.address,500),'status',p.status,'latitude',p.latitude,'longitude',p.longitude,'created_at',p.created_at) order by p.created_at desc,p.id)
        from (select * from public.places where group_id=r.id order by created_at desc,id limit 10) p),'[]'),
      'sources',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'url',case when length(s.url)<=2000 then s.url else null end,'title',left(s.title,200),'status',s.status,'source_message_id',s.source_message_id,'created_at',s.created_at) order by s.created_at desc,s.id)
        from (select * from public.sources where group_id=r.id order by created_at desc,id limit 10) s),'[]'),
      'memories',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'user_id',m.user_id,'kind',m.kind,'key',m.key,'value',left(m.value,200),'value_truncated',length(m.value)>200,'source_message_id',m.source_message_id,'expires_at',m.expires_at,'updated_at',m.updated_at) order by m.updated_at desc,m.id)
        from (select * from public.member_memories where group_id=r.id and user_id=j.requester_id and (expires_at is null or expires_at>now()) order by updated_at desc,id limit 10) m),'[]')
    );
    cut:=exists(select 1 from jsonb_array_elements(item->'messages') x where (x->>'body_truncated')::boolean)
      or exists(select 1 from jsonb_array_elements(item->'memories') x where (x->>'value_truncated')::boolean)
      or exists(select 1 from public.group_members where group_id=r.id offset 100 limit 1)
      or exists(select 1 from public.messages where group_id=r.id and (source_key is null or (source_key not like 'weekly:%' and source_key not like 'pal:weekly:%')) offset 20 limit 1)
      or exists(select 1 from public.plans where group_id=r.id offset 10 limit 1)
      or exists(select 1 from public.places where group_id=r.id offset 10 limit 1)
      or exists(select 1 from public.sources where group_id=r.id and (length(title)>200 or length(url)>2000))
      or exists(select 1 from public.sources where group_id=r.id offset 10 limit 1)
      or exists(select 1 from public.member_memories where group_id=r.id and user_id=j.requester_id and (expires_at is null or expires_at>now()) offset 10 limit 1);
    items:=items||jsonb_build_array(item||jsonb_build_object('truncated',cut)); any_cut:=any_cut or cut;
  end loop;
  return jsonb_build_object('groups',items,'next_offset',next_page,'truncated',any_cut);
end $$;
create function public.pal_read_across_groups(p_job_id uuid,p_attempt integer,p_offset integer default 0,p_query text default null)
returns jsonb language sql set search_path='' as $$ select private.pal_read_across_groups(p_job_id,p_attempt,p_offset,p_query) $$;
revoke all on function public.pal_read_across_groups(uuid,integer,integer,text),private.pal_read_across_groups(uuid,integer,integer,text) from public,anon,authenticated;
grant execute on function public.pal_read_across_groups(uuid,integer,integer,text),private.pal_read_across_groups(uuid,integer,integer,text) to service_role;

create or replace function private.pal_group_state(p_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if current_setting('role',true)<>'service_role' and not exists(select 1 from public.group_members where group_id=p_group_id and user_id=auth.uid()) then
    raise exception 'Group membership required' using errcode='42501';
  end if;
  if not exists(select 1 from public.groups where id=p_group_id) then raise exception 'Group not found' using errcode='22023'; end if;
  return jsonb_build_object(
    'pal_activity',coalesce((select jsonb_build_object(
      'activity','thinking','job_id',j.id,'status',case when j.status='running' then 'running' else 'accepted' end,
      'expires_at',case when j.status='running' then j.lease_until else j.run_after+interval '5 minutes' end)
      from public.agent_jobs j join public.groups g on g.id=j.group_id
      where j.group_id=p_group_id and j.job_kind='chat' and not g.agent_paused
        and ((j.status='running' and j.lease_until>now()) or (j.status='queued' and j.attempts<3 and j.run_after<=now() and j.run_after>now()-interval '5 minutes'))
      order by (j.status='running') desc,j.explicit_mention desc,j.created_at,j.id limit 1),
      jsonb_build_object('activity','idle','job_id',null,'status',null,'expires_at',null)),
    'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'display_name',coalesce(p.display_name,'Member'),'avatar_url',p.avatar_url,'avatar_path',p.avatar_path,'last_read_at',m.last_read_at,'last_read_message_id',m.last_read_message_id) order by m.joined_at) from public.group_members m left join public.profiles p on p.user_id=m.user_id where m.group_id=p_group_id),'[]'),
    'places',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('contributors',coalesce((select jsonb_agg(jsonb_build_object('user_id',c.user_id,'source_id',c.source_id)) from public.place_contributors c where c.place_id=p.id),'[]')) order by p.created_at) from public.places p where p.group_id=p_group_id),'[]'),
    'sources',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('contributors',coalesce((select jsonb_agg(to_jsonb(c)) from public.source_contributors c where c.source_id=s.id),'[]')) order by s.created_at) from public.sources s where s.group_id=p_group_id),'[]'),
    'polls',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('responses',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'option_ids',r.option_ids) order by r.user_id) from public.poll_responses r where r.poll_id=p.id),'[]'),'votes',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'option_id',o)) from public.poll_responses r cross join lateral unnest(r.option_ids) o where r.poll_id=p.id),'[]')) order by p.created_at) from public.polls p where p.group_id=p_group_id),'[]'),
    'plans',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('attendees',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'status',r.status)) from public.plan_rsvps r where r.plan_id=p.id),'[]')) order by p.starts_at) from public.plans p where p.group_id=p_group_id),'[]'),
    'memories',coalesce((select jsonb_agg(to_jsonb(m)||jsonb_build_object('body',m.key||': '||m.value) order by m.updated_at) from public.member_memories m where m.group_id=p_group_id and (m.expires_at is null or m.expires_at>now())),'[]'),
    'reminders',coalesce((select jsonb_agg(to_jsonb(r) order by r.due_at) from public.reminders r where r.group_id=p_group_id),'[]'),
    'reactions',coalesce((select jsonb_agg(to_jsonb(r)) from public.message_reactions r where r.group_id=p_group_id),'[]'),
    'settings',(select jsonb_build_object('is_direct',g.is_direct,'name',g.name,'creator_id',g.creator_id,'avatar_path',g.avatar_path,'timezone',g.timezone,'proactive_suggestions',g.proactive_suggestions,'agent_paused',g.agent_paused) from public.groups g where id=p_group_id)
  );
end $$;
