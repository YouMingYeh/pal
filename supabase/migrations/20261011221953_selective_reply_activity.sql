-- A claimed turn may stay silent. Only an explicit, current-attempt reply intent shows group typing.
alter table public.agent_jobs add column reply_started_at timestamptz;
alter table public.agent_jobs add column reply_started_attempt integer;

create function public.pal_begin_reply(p_job_id uuid,p_job_attempt integer) returns boolean
language plpgsql security definer set search_path='' as $$
declare j public.agent_jobs;
begin
  if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
  select * into j from public.agent_jobs where id=p_job_id;
  if not found then return false; end if;
  -- Use the same group-before-job lock order as pause and completion.
  perform 1 from public.groups where id=j.group_id and not agent_paused for update;
  if not found then return false; end if;
  select * into j from public.agent_jobs where id=p_job_id and attempts=p_job_attempt and status='running' and lease_until>now() for update;
  if not found then return false; end if;
  if not exists(select 1 from public.group_members where group_id=j.group_id and user_id=j.requester_id) then return false; end if;
  if j.job_kind='weekly' then
    if not exists(select 1 from public.groups where id=j.group_id and proactive_suggestions) then return false; end if;
  elsif not exists(select 1 from public.messages where id=j.message_id and group_id=j.group_id and role='user' and sender_id=j.requester_id) then return false;
  end if;
  update public.agent_jobs set
    reply_started_at=case when reply_started_attempt=p_job_attempt then coalesce(reply_started_at,now()) else now() end,
    reply_started_attempt=p_job_attempt where id=j.id;
  return true;
end $$;
revoke all on function public.pal_begin_reply(uuid,integer) from public,anon,authenticated;
grant execute on function public.pal_begin_reply(uuid,integer) to service_role;

-- Preserve every existing state field, including independently added location data.
alter function private.pal_group_state(uuid) rename to pal_group_state_before_reply_activity;
create function private.pal_group_state(p_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare state jsonb; activity jsonb;
begin
  state:=private.pal_group_state_before_reply_activity(p_group_id);
  select jsonb_build_object(
    'activity','typing','job_id',j.id,'status','running',
    'expires_at',least(j.lease_until,j.reply_started_at+interval '20 seconds'))
  into activity from public.agent_jobs j join public.groups g on g.id=j.group_id
  where j.group_id=p_group_id and not g.agent_paused
    and exists(select 1 from public.group_members m where m.group_id=j.group_id and m.user_id=j.requester_id)
    and (j.job_kind='chat' or (j.job_kind='weekly' and g.proactive_suggestions))
    and j.status='running' and j.lease_until>now()
    and j.reply_started_attempt=j.attempts and j.reply_started_at>now()-interval '20 seconds'
  order by (j.status='running') desc,j.explicit_mention desc,j.created_at,j.id limit 1;
  return jsonb_set(state,'{pal_activity}',coalesce(activity,jsonb_build_object('activity','idle','job_id',null,'status',null,'expires_at',null)));
end $$;
revoke all on function private.pal_group_state(uuid) from public,anon;
grant execute on function private.pal_group_state(uuid) to authenticated,service_role;
