-- Keep historical expressions optional; hosts fall back to fier.
alter table public.messages add column emotion text check (
  emotion is null or (role='pal' and emotion in ('fier','heureux','hilare','curieux','confus','surpris','timide','triste','colere','somnolent','attentif','neutre'))
);
create function public.complete_agent_job_with_emotion(p_job_id uuid,p_attempt integer,p_body text,p_result text default null,p_emotion text default 'fier') returns boolean
language plpgsql set search_path='' as $$
declare j public.agent_jobs; tone text:=coalesce(p_emotion,'fier');
begin
  if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
  if tone not in ('fier','heureux','hilare','curieux','confus','surpris','timide','triste','colere','somnolent','attentif','neutre') then raise exception 'Valid mascot emotion required' using errcode='22023'; end if;
  if length(coalesce(p_body,''))>8000 then raise exception 'Pal response too long' using errcode='22023'; end if;
  select * into j from public.agent_jobs where id=p_job_id;
  if not found then return false; end if;
  -- Match the dispatcher and pause action's group-before-job lock ordering.
  perform 1 from public.groups where id=j.group_id and not agent_paused for update;
  if not found then return false; end if;
  select * into j from public.agent_jobs where id=p_job_id and attempts=p_attempt and status='running' and lease_until>now() for update;
  if not found then return false; end if;
  if j.job_kind='weekly' and not exists(select 1 from public.groups where id=j.group_id and proactive_suggestions) then return false; end if;
  if length(btrim(coalesce(p_body,'')))>0 then
    insert into public.messages(group_id,role,body,source_key,emotion)
    values(j.group_id,'pal',btrim(p_body),'job:'||j.id,tone) on conflict(group_id,source_key) do nothing;
  end if;
  update public.agent_jobs set status='completed',result=p_result,lease_until=null,completed_at=now() where id=j.id;
  return true;
end $$;
revoke all on function public.complete_agent_job_with_emotion(uuid,integer,text,text,text) from public,anon,authenticated;
grant execute on function public.complete_agent_job_with_emotion(uuid,integer,text,text,text) to service_role;
create or replace function public.complete_agent_job(p_job_id uuid,p_attempt integer,p_body text,p_result text default null) returns boolean
language sql set search_path='' as $$ select public.complete_agent_job_with_emotion(p_job_id,p_attempt,p_body,p_result,'fier') $$;

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
    'settings',(select jsonb_build_object('name',g.name,'creator_id',g.creator_id,'avatar_path',g.avatar_path,'timezone',g.timezone,'proactive_suggestions',g.proactive_suggestions,'agent_paused',g.agent_paused) from public.groups g where id=p_group_id)
  );
end $$;
