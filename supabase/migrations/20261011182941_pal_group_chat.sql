create schema if not exists private;

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 80),
  invite_code uuid not null unique default gen_random_uuid(),
  creator_id uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index group_members_user_id_idx on public.group_members(user_id);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  sender_id uuid references auth.users(id) on delete set null,
  role text not null check (role in ('user','pal','system')),
  body text not null check (length(btrim(body)) between 1 and 8000),
  client_id uuid,
  source_key text,
  created_at timestamptz not null default now(),
  unique (group_id, sender_id, client_id),
  unique (group_id, source_key)
);
create index messages_group_created_idx on public.messages(group_id,created_at,id);
create index messages_sender_id_idx on public.messages(sender_id);

create table public.agent_jobs (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null unique references public.messages(id) on delete cascade,
  group_id uuid not null references public.groups(id) on delete cascade,
  requester_id uuid not null references auth.users(id),
  status text not null default 'queued' check (status in ('queued','running','completed','failed')),
  attempts integer not null default 0 check (attempts >= 0),
  lease_until timestamptz,
  result text,
  last_error text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index agent_jobs_claim_idx on public.agent_jobs(status,lease_until,created_at);
create index agent_jobs_group_idx on public.agent_jobs(group_id);
create index agent_jobs_requester_idx on public.agent_jobs(requester_id);

create table public.reminders (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  requester_id uuid not null references auth.users(id),
  body text not null check (length(btrim(body)) between 1 and 2000),
  due_at timestamptz not null,
  timezone text not null default 'UTC',
  status text not null default 'scheduled' check (status in ('scheduled','completed','cancelled')),
  source_key text not null check (length(source_key) between 1 and 200),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (group_id, source_key)
);
create index reminders_due_idx on public.reminders(due_at) where status = 'scheduled';
create index reminders_requester_idx on public.reminders(requester_id);

alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.messages enable row level security;
alter table public.agent_jobs enable row level security;
alter table public.reminders enable row level security;
revoke all on public.groups, public.group_members, public.messages, public.agent_jobs, public.reminders from anon, authenticated;
grant select on public.groups, public.group_members, public.messages, public.agent_jobs, public.reminders to authenticated;
grant all on public.groups, public.group_members, public.messages, public.agent_jobs, public.reminders to service_role;

create function private.my_group_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select group_id from public.group_members where user_id = (select auth.uid())
$$;
revoke all on function private.my_group_ids() from public;
grant usage on schema private to authenticated, service_role;
grant execute on function private.my_group_ids() to authenticated;

create policy members_read_groups on public.groups for select to authenticated using (id in (select private.my_group_ids()));
create policy members_read_members on public.group_members for select to authenticated using (group_id in (select private.my_group_ids()));
create policy members_read_messages on public.messages for select to authenticated using (group_id in (select private.my_group_ids()));
create policy members_read_jobs on public.agent_jobs for select to authenticated using (group_id in (select private.my_group_ids()));
create policy members_read_reminders on public.reminders for select to authenticated using (group_id in (select private.my_group_ids()));

create function private.create_group(p_name text) returns public.groups
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_group public.groups;
begin
  if v_user is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 80 then raise exception 'Group name must be 1-80 characters' using errcode = '22023'; end if;
  insert into public.groups(name,creator_id) values (btrim(p_name),v_user) returning * into v_group;
  insert into public.group_members(group_id,user_id) values (v_group.id,v_user);
  return v_group;
end $$;
create function public.create_group(p_name text) returns public.groups
language sql set search_path = '' as $$ select private.create_group(p_name) $$;

create function private.join_group(p_invite_code uuid) returns public.groups
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_group public.groups;
begin
  if v_user is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  select * into v_group from public.groups where invite_code = p_invite_code;
  if not found then raise exception 'Invalid invite code' using errcode = '22023'; end if;
  insert into public.group_members(group_id,user_id) values (v_group.id,v_user) on conflict do nothing;
  return v_group;
end $$;
create function public.join_group(p_invite_code uuid) returns public.groups
language sql set search_path = '' as $$ select private.join_group(p_invite_code) $$;

create function private.send_message(p_group_id uuid,p_body text,p_client_id uuid) returns public.messages
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_message public.messages;
begin
  if v_user is null or not exists (select 1 from public.group_members where group_id=p_group_id and user_id=v_user) then
    raise exception 'Group membership required' using errcode='42501';
  end if;
  if p_client_id is null or p_body is null or length(btrim(p_body)) not between 1 and 8000 then
    raise exception 'Valid message and client ID required' using errcode='22023';
  end if;
  insert into public.messages(group_id,sender_id,role,body,client_id)
  values(p_group_id,v_user,'user',btrim(p_body),p_client_id)
  on conflict (group_id,sender_id,client_id) do nothing returning * into v_message;
  if not found then
    select * into v_message from public.messages where group_id=p_group_id and sender_id=v_user and client_id=p_client_id;
    if v_message.body <> btrim(p_body) then raise exception 'Client ID already used for another message' using errcode='22023'; end if;
  end if;
  if v_message.body ~* '(^|[[:space:]])@pal([[:space:][:punct:]]|$)' then
    insert into public.agent_jobs(message_id,group_id,requester_id) values(v_message.id,p_group_id,v_user)
    on conflict (message_id) do nothing;
  end if;
  return v_message;
end $$;
create function public.send_message(p_group_id uuid,p_body text,p_client_id uuid) returns public.messages
language sql set search_path = '' as $$ select private.send_message(p_group_id,p_body,p_client_id) $$;

revoke all on function private.create_group(text), public.create_group(text), private.join_group(uuid), public.join_group(uuid), private.send_message(uuid,text,uuid), public.send_message(uuid,text,uuid) from public;
grant execute on function private.create_group(text), public.create_group(text), private.join_group(uuid), public.join_group(uuid), private.send_message(uuid,text,uuid), public.send_message(uuid,text,uuid) to authenticated;

create function public.claim_agent_jobs(p_limit integer default 5) returns setof public.agent_jobs
language plpgsql set search_path = '' as $$
begin
  if p_limit is null or p_limit not between 1 and 20 then raise exception 'Limit must be 1-20' using errcode='22023'; end if;
  update public.agent_jobs set status='failed',last_error='Worker lease expired after maximum attempts',lease_until=null
    where status='running' and lease_until < now() and attempts >= 3;
  return query
  with candidates as (
    select id from public.agent_jobs
    where attempts < 3 and (status='queued' or (status='running' and lease_until < now()))
    order by created_at,id for update skip locked limit p_limit
  )
  update public.agent_jobs j set status='running',attempts=j.attempts+1,lease_until=now()+interval '5 minutes'
  from candidates c where j.id=c.id returning j.*;
end $$;

create function public.complete_agent_job(p_job_id uuid,p_attempt integer,p_body text,p_result text default null) returns boolean
language plpgsql set search_path = '' as $$
declare v_job public.agent_jobs;
begin
  if p_body is null or length(btrim(p_body)) not between 1 and 8000 then raise exception 'Valid Pal response required' using errcode='22023'; end if;
  select * into v_job from public.agent_jobs where id=p_job_id and attempts=p_attempt and status='running' for update;
  if not found then return false; end if;
  insert into public.messages(group_id,role,body,source_key) values(v_job.group_id,'pal',btrim(p_body),'job:'||v_job.id)
    on conflict (group_id,source_key) do nothing;
  update public.agent_jobs set status='completed',result=p_result,lease_until=null,completed_at=now() where id=v_job.id;
  return true;
end $$;

create function public.fail_agent_job(p_job_id uuid,p_attempt integer,p_error text) returns boolean
language plpgsql set search_path = '' as $$
begin
  update public.agent_jobs set status=case when attempts < 3 then 'queued' else 'failed' end,last_error=left(p_error,2000),lease_until=null
  where id=p_job_id and attempts=p_attempt and status='running';
  return found;
end $$;

create function public.create_reminder(p_group_id uuid,p_requester_id uuid,p_body text,p_due_at timestamptz,p_timezone text,p_source_key text) returns public.reminders
language plpgsql set search_path = '' as $$
declare v_reminder public.reminders;
begin
  if not exists (select 1 from public.group_members where group_id=p_group_id and user_id=p_requester_id) then
    raise exception 'Group membership required' using errcode='42501';
  end if;
  if p_due_at is null or not isfinite(p_due_at) or p_due_at <= now() then raise exception 'Reminder time must be in the future' using errcode='22023'; end if;
  if p_timezone is null or not exists (select 1 from pg_catalog.pg_timezone_names where name=p_timezone) then raise exception 'Valid IANA timezone required' using errcode='22023'; end if;
  if p_body is null or length(btrim(p_body)) not between 1 and 2000 or p_source_key is null or length(p_source_key) not between 1 and 200 then raise exception 'Valid reminder and source key required' using errcode='22023'; end if;
  insert into public.reminders(group_id,requester_id,body,due_at,timezone,source_key)
  values(p_group_id,p_requester_id,btrim(p_body),p_due_at,p_timezone,p_source_key)
  on conflict (group_id,source_key) do nothing returning * into v_reminder;
  if not found then
    select * into v_reminder from public.reminders where group_id=p_group_id and source_key=p_source_key;
    if v_reminder.requester_id <> p_requester_id or v_reminder.body <> btrim(p_body) or v_reminder.due_at <> p_due_at or v_reminder.timezone <> p_timezone then
      raise exception 'Source key already used for another reminder' using errcode='22023';
    end if;
  end if;
  return v_reminder;
end $$;
revoke all on function public.claim_agent_jobs(integer),public.complete_agent_job(uuid,integer,text,text),public.fail_agent_job(uuid,integer,text),public.create_reminder(uuid,uuid,text,timestamptz,text,text) from public;
grant execute on function public.claim_agent_jobs(integer),public.complete_agent_job(uuid,integer,text,text),public.fail_agent_job(uuid,integer,text),public.create_reminder(uuid,uuid,text,timestamptz,text,text) to service_role;

create function private.deliver_due_reminders() returns integer
language plpgsql security definer set search_path = '' as $$
declare v_reminder public.reminders; v_count integer := 0;
begin
  for v_reminder in
    select * from public.reminders where status='scheduled' and due_at <= now()
    order by due_at,id for update skip locked limit 100
  loop
    insert into public.messages(group_id,role,body,source_key)
    values(v_reminder.group_id,'pal','Reminder: '||v_reminder.body,'reminder:'||v_reminder.id)
    on conflict (group_id,source_key) do nothing;
    update public.reminders set status='completed',completed_at=now() where id=v_reminder.id;
    v_count := v_count+1;
  end loop;
  return v_count;
end $$;
revoke all on function private.deliver_due_reminders() from public;

do $$
begin
  if exists (select 1 from pg_publication where pubname='supabase_realtime') then
    alter publication supabase_realtime add table public.messages, public.reminders, public.agent_jobs;
  end if;
end $$;
