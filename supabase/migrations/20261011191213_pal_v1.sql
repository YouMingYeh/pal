alter table public.groups add column timezone text not null default 'America/Los_Angeles',
  add column proactive_suggestions boolean not null default true,
  add column agent_paused boolean not null default false,
  add column last_weekly_at timestamptz;
alter table public.group_members add column last_read_at timestamptz,
  add column last_read_message_id uuid references public.messages(id) on delete set null;
alter table public.messages add column reply_to_id uuid references public.messages(id) on delete set null,
  add column card jsonb check (card is null or (jsonb_typeof(card)='object' and card ? 'type' and card ? 'entity_id'));
alter table public.agent_jobs drop constraint agent_jobs_status_check;
alter table public.agent_jobs add constraint agent_jobs_status_check check (status in ('queued','running','completed','failed','coalesced','cancelled')),
  add column run_after timestamptz not null default now(),
  add column explicit_mention boolean not null default true,
  add column batch_message_ids uuid[] not null default '{}',
  add column coalesced_into uuid references public.agent_jobs(id),
  add column job_kind text not null default 'chat' check (job_kind in ('chat','weekly'));

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (length(btrim(display_name)) between 1 and 60),
  avatar_url text check (avatar_url is null or (length(avatar_url)<=2000 and avatar_url ~ '^https://')),
  notification_preferences jsonb not null default '{"enabled":true}' check (jsonb_typeof(notification_preferences)='object'),
  notifications_enabled boolean generated always as (coalesce((notification_preferences->>'enabled')::boolean,true)) stored,
  updated_at timestamptz not null default now()
);
create table public.message_reactions (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  actor text not null default 'user' check (actor in ('user','pal')),
  emoji text not null check (length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  unique(message_id,user_id,emoji),
  check ((actor='user' and user_id is not null) or (actor='pal' and user_id is null))
);
create unique index message_reactions_pal_key on public.message_reactions(message_id,emoji) where actor='pal';
create table public.sources (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  source_message_id uuid references public.messages(id) on delete set null,
  url text,
  canonical_url text,
  title text,
  status text not null default 'pending' check (status in ('pending','resolving','resolved','needs_confirmation','failed')),
  candidates jsonb not null default '[]' check (jsonb_typeof(candidates)='array'),
  place_ids uuid[] not null default '{}',
  provider_job_id text,
  extraction jsonb not null default '{}',
  metadata jsonb not null default '{}',
  attempts integer not null default 0,
  next_attempt timestamptz not null default now(),
  lease_until timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(group_id,canonical_url)
);
create table public.places (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  name text not null check (length(btrim(name)) between 1 and 160),
  address text not null default '' check (length(address)<=500),
  latitude double precision check (latitude between -90 and 90),
  longitude double precision check (longitude between -180 and 180),
  provider text not null default 'apple' check (provider in ('apple','google','manual')),
  provider_id text not null check (length(provider_id) between 1 and 300),
  status text not null default 'resolved' check (status in ('resolved','needs_confirmation')),
  candidates jsonb not null default '[]' check (jsonb_typeof(candidates)='array'),
  website text,
  booking_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(group_id,provider,provider_id),
  check (status<>'resolved' or (latitude is not null and longitude is not null))
);
create table public.source_contributors (
  group_id uuid not null references public.groups(id) on delete cascade,
  source_id uuid not null references public.sources(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_message_id uuid references public.messages(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key(source_id,user_id)
);
create table public.place_contributors (
  group_id uuid not null references public.groups(id) on delete cascade,
  place_id uuid not null references public.places(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id uuid not null references public.sources(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(place_id,user_id,source_id)
);
create table public.polls (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  kind text not null check (kind in ('place','time')),
  question text not null check (length(btrim(question)) between 1 and 500),
  options jsonb not null check (jsonb_typeof(options)='array' and jsonb_array_length(options) between 2 and 8),
  status text not null default 'open' check (status in ('open','closed')),
  deadline_at timestamptz not null,
  created_at timestamptz not null default now()
);
create table public.poll_responses (
  group_id uuid not null references public.groups(id) on delete cascade,
  poll_id uuid not null references public.polls(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  option_ids text[] not null,
  updated_at timestamptz not null default now(),
  primary key(poll_id,user_id)
);
create table public.plans (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  title text not null check (length(btrim(title)) between 1 and 160),
  place_id uuid references public.places(id) on delete set null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  notes text not null default '' check (length(notes)<=4000),
  status text not null default 'draft' check (status in ('draft','confirmed','cancelled')),
  booking_status text not null default 'needed' check (booking_status in ('needed','requested','booked','failed')),
  booking_reference text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (isfinite(starts_at) and isfinite(ends_at) and ends_at>starts_at)
);
create table public.plan_rsvps (
  group_id uuid not null references public.groups(id) on delete cascade,
  plan_id uuid not null references public.plans(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null check (status in ('going','maybe','declined')),
  updated_at timestamptz not null default now(),
  primary key(plan_id,user_id)
);
create table public.member_memories (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('preference','availability')),
  key text not null check (length(btrim(key)) between 1 and 80),
  value text not null check (length(btrim(value)) between 1 and 2000),
  source_message_id uuid references public.messages(id) on delete set null,
  expires_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(group_id,user_id,kind,key),
  check (kind<>'availability' or expires_at is not null)
);
alter table public.reminders add column plan_id uuid references public.plans(id) on delete cascade,
  add column poll_id uuid references public.polls(id) on delete cascade,
  add column target_user_ids uuid[] not null default '{}',
  add column kind text not null default 'reminder' check (kind in ('reminder','poll_halfway','poll_deadline','plan_24h','plan_2h')),
  add column version integer not null default 1;

create table private.action_receipts (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null,
  source_key text not null,
  input jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key(group_id,user_id,action,source_key)
);
create table private.google_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  calendar_id text,
  calendar_lease_until timestamptz,
  calendar_attempts integer not null default 0,
  encrypted_refresh_token text not null,
  encrypted_access_token text,
  expires_at timestamptz,
  status text not null default 'connected' check (status in ('connected','revoked','error')),
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table private.google_sync_items (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.plans(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  event_id text,
  desired_version integer not null,
  state text not null default 'pending' check (state in ('pending','syncing','synced','remove','failed')),
  attempts integer not null default 0,
  next_attempt timestamptz not null default now(),
  lease_until timestamptz,
  error text,
  updated_at timestamptz not null default now(),
  unique(plan_id,user_id)
);
create table private.oauth_states (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  state_hash text not null unique,
  encrypted_code_verifier text not null,
  expires_at timestamptz not null default now()+interval '10 minutes',
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
create table private.push_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null check (token ~ '^[a-fA-F0-9]{64,200}$'),
  environment text not null check (environment in ('sandbox','production')),
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  unique(token,environment)
);
create table private.push_outbox (
  id uuid primary key default gen_random_uuid(),
  message_id uuid references public.messages(id) on delete cascade,
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  plan_id uuid references public.plans(id) on delete cascade,
  payload jsonb not null,
  status text not null default 'queued' check (status in ('queued','sending','sent','failed','cancelled')),
  attempts integer not null default 0,
  next_attempt timestamptz not null default now(),
  lease_until timestamptz,
  source_key text not null unique,
  error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

do $$
declare t text;
begin
  foreach t in array array['profiles','message_reactions','sources','source_contributors','places','place_contributors','polls','poll_responses','plans','plan_rsvps','member_memories'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant select on public.%I to authenticated',t);
    execute format('grant all on public.%I to service_role',t);
    if t<>'profiles' then
      execute format('create policy members_read on public.%I for select to authenticated using (group_id in (select private.my_group_ids()))',t);
      execute format('create index %I on public.%I(group_id)',t||'_group_idx',t);
    end if;
  end loop;
  foreach t in array array['action_receipts','google_connections','google_sync_items','oauth_states','push_devices','push_outbox'] loop
    execute format('alter table private.%I enable row level security',t);
    execute format('revoke all on private.%I from public,anon,authenticated',t);
    execute format('grant all on private.%I to service_role',t);
  end loop;
end $$;
create function private.pal_execute_action(p_group_id uuid,p_user_id uuid,p_action text,p_data jsonb,p_agent boolean) returns jsonb
language plpgsql set search_path='' as $$
declare
  g public.groups; rec private.action_receipts; result jsonb; entity uuid; sid uuid; v_key text:=p_data->>'source_key';
  s public.sources; place public.places; poll public.polls; plan public.plans; reminder public.reminders; memory public.member_memories;
  opts jsonb; opt jsonb; votes text[]; targets uuid[]; due timestamptz; tz text; pid text; n integer;
begin
  if p_data is null or jsonb_typeof(p_data)<>'object' or p_user_id is null then raise exception 'Action object and authenticated user required' using errcode='22023'; end if;
  select * into g from public.groups where id=p_group_id for update;
  if not found or not exists(select 1 from public.group_members where group_id=p_group_id and user_id=p_user_id) then raise exception 'Group membership required' using errcode='42501'; end if;
  if p_agent and p_action not in ('reaction.toggle','source.create','source.update','place.save','place.correct','poll.create','plan.create','plan.update','memory.save','memory.delete','reminder.create','reminder.update','reminder.cancel') then
    raise exception 'Agent action requires an explicit member decision' using errcode='42501';
  end if;
  if p_agent and (v_key is null or length(v_key) not between 1 and 200) then raise exception 'Agent source key required' using errcode='22023'; end if;
  if v_key is not null and length(v_key) not between 1 and 200 then raise exception 'Invalid source key' using errcode='22023'; end if;
  if p_agent and p_data ? 'job_id' and not exists(select 1 from public.agent_jobs where id=(p_data->>'job_id')::uuid and group_id=p_group_id and status='running') then raise exception 'Running group job required' using errcode='42501'; end if;
  if v_key is not null then
    select * into rec from private.action_receipts where group_id=p_group_id and user_id=p_user_id and action=p_action and source_key=v_key;
    if found then
      if rec.input<>p_data then raise exception 'Source key already used for another action input' using errcode='22023'; end if;
      return rec.result;
    end if;
  end if;
  entity:=nullif(p_data->>'id','')::uuid;
  sid:=nullif(p_data->>'source_message_id','')::uuid;
  if sid is not null and not exists(select 1 from public.messages where id=sid and group_id=p_group_id) then raise exception 'Source message belongs to another group' using errcode='42501'; end if;
  case p_action
    when 'group.settings' then
      tz:=coalesce(p_data->>'timezone',g.timezone);
      if not exists(select 1 from pg_catalog.pg_timezone_names where name=tz) then raise exception 'Valid IANA timezone required' using errcode='22023'; end if;
      update public.groups set name=coalesce(p_data->>'name',name),timezone=tz,
        proactive_suggestions=coalesce((p_data->>'proactive_suggestions')::boolean,proactive_suggestions),agent_paused=coalesce((p_data->>'agent_paused')::boolean,agent_paused)
      where id=p_group_id returning to_jsonb(groups) into result;
      if (result->>'agent_paused')::boolean then update public.agent_jobs set status='cancelled',lease_until=null where group_id=p_group_id and status in ('queued','running'); end if;
      if not (result->>'proactive_suggestions')::boolean then update public.agent_jobs set status='cancelled' where group_id=p_group_id and status='queued' and job_kind='weekly'; end if;
    when 'group.read' then
      entity:=(p_data->>'message_id')::uuid;
      if not exists(select 1 from public.messages where id=entity and group_id=p_group_id) then raise exception 'Group message required' using errcode='22023'; end if;
      due:=(select created_at from public.messages where id=entity);
      update public.group_members set last_read_at=due,last_read_message_id=entity where group_id=p_group_id and user_id=p_user_id and (last_read_at is null or last_read_at<=due);
      result:=jsonb_build_object('ok',true,'last_read_at',(select last_read_at from public.group_members where group_id=p_group_id and user_id=p_user_id));
    when 'message.reply' then
      result:=to_jsonb(private.send_message(p_group_id,p_data->>'body',(p_data->>'client_id')::uuid,(p_data->>'reply_to_id')::uuid));
    when 'reaction.toggle' then
      entity:=(p_data->>'message_id')::uuid;
      if not exists(select 1 from public.messages where id=entity and group_id=p_group_id) or coalesce(length(p_data->>'emoji'),0) not between 1 and 16 then raise exception 'Valid group message and emoji required' using errcode='22023'; end if;
      delete from public.message_reactions where message_id=entity and (case when p_agent then actor='pal' else user_id=p_user_id end) and emoji=p_data->>'emoji';
      if found then result:=jsonb_build_object('active',false);
      else
        insert into public.message_reactions(group_id,message_id,user_id,actor,emoji) values(p_group_id,entity,case when p_agent then null else p_user_id end,case when p_agent then 'pal' else 'user' end,p_data->>'emoji');
        result:=jsonb_build_object('active',true);
      end if;
    when 'memory.save' then
      if sid is not null and not exists(select 1 from public.messages where id=sid and group_id=p_group_id and sender_id=p_user_id and role='user') then raise exception 'Memory source must be the member speaking' using errcode='42501'; end if;
      if p_agent and sid is null then raise exception 'Explicit memory source required' using errcode='22023'; end if;
      if entity is not null and not exists(select 1 from public.member_memories where id=entity and group_id=p_group_id and user_id=p_user_id) then raise exception 'Only own memory can be edited' using errcode='42501'; end if;
      if p_data->>'kind'='availability' and (nullif(p_data->>'expires_at','')::timestamptz is null or (p_data->>'expires_at')::timestamptz<=now()) then raise exception 'Dated availability requires a future expiry' using errcode='22023'; end if;
      if entity is not null then
        update public.member_memories set kind=p_data->>'kind',key=btrim(p_data->>'key'),value=btrim(p_data->>'value'),source_message_id=sid,expires_at=nullif(p_data->>'expires_at','')::timestamptz,updated_at=now() where id=entity returning * into memory;
      else
        insert into public.member_memories(group_id,user_id,kind,key,value,source_message_id,expires_at)
        values(p_group_id,p_user_id,p_data->>'kind',btrim(p_data->>'key'),btrim(p_data->>'value'),sid,nullif(p_data->>'expires_at','')::timestamptz)
        on conflict(group_id,user_id,kind,key) do update set value=excluded.value,source_message_id=excluded.source_message_id,expires_at=excluded.expires_at,updated_at=now() returning * into memory;
      end if;
      result:=to_jsonb(memory);
    when 'memory.delete' then
      delete from public.member_memories where id=entity and group_id=p_group_id and user_id=p_user_id returning to_jsonb(member_memories) into result;
      if not found then raise exception 'Only own memory can be deleted' using errcode='42501'; end if;
    when 'source.create' then
      if p_data->>'url' is null then raise exception 'Source URL required' using errcode='22023'; end if;
      if sid is not null and not exists(select 1 from public.messages where id=sid and group_id=p_group_id and sender_id=p_user_id and role='user') then raise exception 'Source must be attributed to the member who shared it' using errcode='42501'; end if;
      insert into public.sources(group_id,created_by,source_message_id,url,canonical_url,title)
      values(p_group_id,p_user_id,sid,p_data->>'url',private.pal_canonical_url(p_data->>'url'),p_data->>'title')
      on conflict(group_id,canonical_url) do update set updated_at=now() returning * into s;
      insert into public.source_contributors(group_id,source_id,user_id,source_message_id) values(p_group_id,s.id,p_user_id,sid) on conflict(source_id,user_id) do nothing;
      perform private.pal_post_card(p_group_id,p_user_id,p_agent,'place',s.id,coalesce(s.title,'Finding places from this link'),v_key);
      result:=to_jsonb(s);
    when 'source.update' then
      select * into s from public.sources where id=entity and group_id=p_group_id for update;
      if not found then raise exception 'Group source required' using errcode='42501'; end if;
      if p_data ? 'place_ids' and exists(select 1 from jsonb_array_elements_text(p_data->'place_ids') x where not exists(select 1 from public.places where id=x::uuid and group_id=p_group_id)) then raise exception 'Group places required' using errcode='42501'; end if;
      update public.sources set title=coalesce(p_data->>'title',title),status=coalesce(p_data->>'status',status),
        candidates=coalesce(p_data->'candidates',candidates),place_ids=case when p_data ? 'place_ids' then array(select x::uuid from jsonb_array_elements_text(p_data->'place_ids') x) else place_ids end,updated_at=now()
      where id=entity returning * into s;
      result:=to_jsonb(s);
    when 'place.save','place.correct' then
      if p_data ? 'website' and p_data->>'website' is not null then perform private.pal_canonical_url(p_data->>'website'); end if;
      if p_data ? 'booking_url' and p_data->>'booking_url' is not null then perform private.pal_canonical_url(p_data->>'booking_url'); end if;
      if p_action='place.correct' then
        select * into place from public.places where id=entity and group_id=p_group_id for update;
        if not found then raise exception 'Group place required' using errcode='42501'; end if;
        update public.places set name=coalesce(p_data->>'name',name),address=coalesce(p_data->>'address',address),
          latitude=coalesce((p_data->>'latitude')::double precision,latitude),longitude=coalesce((p_data->>'longitude')::double precision,longitude),
          provider=coalesce(p_data->>'provider',provider),provider_id=coalesce(p_data->>'provider_id',provider_id),status=coalesce(p_data->>'status',status),
          candidates=coalesce(p_data->'candidates',candidates),website=coalesce(p_data->>'website',website),booking_url=coalesce(p_data->>'booking_url',booking_url),updated_at=now()
        where id=entity returning * into place;
        result:=to_jsonb(place);
      else
        pid:=coalesce(nullif(p_data->>'provider_id',''),'coordinates:'||round((p_data->>'latitude')::numeric,5)||':'||round((p_data->>'longitude')::numeric,5)||':'||lower(btrim(p_data->>'name')));
        insert into public.places(group_id,created_by,name,address,latitude,longitude,provider,provider_id,status,candidates,website,booking_url)
        values(p_group_id,p_user_id,btrim(p_data->>'name'),coalesce(p_data->>'address',''),(p_data->>'latitude')::double precision,(p_data->>'longitude')::double precision,coalesce(p_data->>'provider','apple'),pid,coalesce(p_data->>'status','resolved'),coalesce(p_data->'candidates','[]'),p_data->>'website',p_data->>'booking_url')
        on conflict(group_id,provider,provider_id) do update set updated_at=now() returning * into place;
        entity:=(p_data->>'source_id')::uuid;
        if entity is not null then
          select * into s from public.sources where id=entity and group_id=p_group_id for update;
          if not found then raise exception 'Group source required' using errcode='42501'; end if;
        else
          insert into public.sources(group_id,created_by,title,status,canonical_url) values(p_group_id,p_user_id,place.name,'resolved','pal://place/'||place.provider||'/'||place.provider_id)
          on conflict(group_id,canonical_url) do update set updated_at=now() returning * into s;
        end if;
        insert into public.source_contributors(group_id,source_id,user_id) values(p_group_id,s.id,p_user_id) on conflict(source_id,user_id) do nothing;
        insert into public.place_contributors(group_id,place_id,user_id,source_id) values(p_group_id,place.id,p_user_id,s.id) on conflict do nothing;
        update public.sources set place_ids=case when place.id=any(place_ids) then place_ids else array_append(place_ids,place.id) end,status='resolved',updated_at=now() where id=s.id;
        perform private.pal_post_card(p_group_id,p_user_id,p_agent,'place',s.id,place.name,v_key);
        result:=to_jsonb(place)||jsonb_build_object('source_id',s.id);
      end if;
    when 'place.delete' then
      if exists(select 1 from public.plans where place_id=entity and group_id=p_group_id and status='confirmed') then raise exception 'Remove place from confirmed plans first' using errcode='22023'; end if;
      delete from public.places where id=entity and group_id=p_group_id returning to_jsonb(places) into result;
      if not found then raise exception 'Group place required' using errcode='42501'; end if;
      update public.sources set place_ids=array_remove(place_ids,entity),updated_at=now() where group_id=p_group_id and entity=any(place_ids);
    when 'poll.create' then
      opts:=p_data->'options';
      if jsonb_typeof(opts)<>'array' or jsonb_array_length(opts) not between 2 and 8 then raise exception 'Poll requires 2-8 options' using errcode='22023'; end if;
      for opt in select value from jsonb_array_elements(opts) loop
        if coalesce(length(opt->>'id'),0) not between 1 and 64 or coalesce(length(opt->>'label'),0) not between 1 and 160 then raise exception 'Poll option ID and label required' using errcode='22023'; end if;
        if opt ? 'place_id' and not exists(select 1 from public.places where id=(opt->>'place_id')::uuid and group_id=p_group_id) then raise exception 'Group place required' using errcode='42501'; end if;
        if p_data->>'kind'='time' and (nullif(opt->>'starts_at','')::timestamptz is null or not isfinite((opt->>'starts_at')::timestamptz)) then raise exception 'Time option starts_at required' using errcode='22023'; end if;
      end loop;
      if (select count(distinct value->>'id') from jsonb_array_elements(opts))<>jsonb_array_length(opts) then raise exception 'Option IDs must be unique' using errcode='22023'; end if;
      due:=(p_data->>'deadline_at')::timestamptz;
      if due is null or not isfinite(due) or due<=now() then raise exception 'Future poll deadline required' using errcode='22023'; end if;
      insert into public.polls(group_id,created_by,kind,question,options,deadline_at) values(p_group_id,p_user_id,p_data->>'kind',p_data->>'question',opts,due) returning * into poll;
      insert into public.reminders(group_id,requester_id,body,due_at,timezone,source_key,poll_id,kind)
      values(p_group_id,p_user_id,poll.question,now()+(due-now())/2,g.timezone,'poll:'||poll.id||':halfway',poll.id,'poll_halfway'),
        (p_group_id,p_user_id,poll.question,due,g.timezone,'poll:'||poll.id||':deadline',poll.id,'poll_deadline');
      perform private.pal_post_card(p_group_id,p_user_id,p_agent,case when poll.kind='place' then 'choice' else 'availability' end,poll.id,poll.question,v_key);
      result:=to_jsonb(poll);
    when 'poll.vote' then
      select * into poll from public.polls where id=entity and group_id=p_group_id for update;
      if not found then raise exception 'Group poll required' using errcode='42501'; end if;
      if poll.status<>'open' or poll.deadline_at<=now() then raise exception 'Poll is closed' using errcode='22023'; end if;
      votes:=array(select distinct x from jsonb_array_elements_text(p_data->'option_ids') x);
      if cardinality(votes)=0 or exists(select 1 from unnest(votes) x where not exists(select 1 from jsonb_array_elements(poll.options) o where o->>'id'=x)) then raise exception 'Select valid poll options' using errcode='22023'; end if;
      insert into public.poll_responses(group_id,poll_id,user_id,option_ids) values(p_group_id,entity,p_user_id,votes)
      on conflict(poll_id,user_id) do update set option_ids=excluded.option_ids,updated_at=now();
      if not exists(select 1 from public.group_members m where m.group_id=p_group_id and not exists(select 1 from public.poll_responses r where r.poll_id=entity and r.user_id=m.user_id)) then
        update public.reminders set status='cancelled',version=version+1 where poll_id=entity and status='scheduled';
        update private.push_outbox set status='cancelled' where group_id=p_group_id and payload->>'poll_id'=entity::text and status in ('queued','sending');
      end if;
      result:=jsonb_build_object('id',entity,'user_id',p_user_id,'option_ids',votes);
    when 'plan.create' then
      if p_data ? 'place_id' and p_data->>'place_id' is not null and not exists(select 1 from public.places where id=(p_data->>'place_id')::uuid and group_id=p_group_id and status='resolved') then raise exception 'Resolved group place required' using errcode='42501'; end if;
      due:=(p_data->>'starts_at')::timestamptz;
      if due is null or due<=now() then raise exception 'Future plan time required' using errcode='22023'; end if;
      insert into public.plans(group_id,created_by,title,place_id,starts_at,ends_at,notes)
      values(p_group_id,p_user_id,p_data->>'title',(p_data->>'place_id')::uuid,due,coalesce((p_data->>'ends_at')::timestamptz,due+interval '1 hour'),coalesce(p_data->>'notes','')) returning * into plan;
      perform private.pal_post_card(p_group_id,p_user_id,p_agent,'plan',plan.id,plan.title,v_key);
      result:=to_jsonb(plan);
    when 'plan.update','plan.confirm','plan.cancel','plan.rsvp','plan.booking' then
      select * into plan from public.plans where id=entity and group_id=p_group_id for update;
      if not found then raise exception 'Group plan required' using errcode='42501'; end if;
      if p_agent and plan.status<>'draft' then raise exception 'Agent can only edit draft plans' using errcode='42501'; end if;
      if p_action='plan.update' then
        if plan.status='cancelled' then raise exception 'Cancelled plan cannot be edited' using errcode='22023'; end if;
        if p_data ? 'place_id' and p_data->>'place_id' is not null and not exists(select 1 from public.places where id=(p_data->>'place_id')::uuid and group_id=p_group_id and status='resolved') then raise exception 'Resolved group place required' using errcode='42501'; end if;
        if (p_data ? 'place_id' and (p_data->>'place_id')::uuid is distinct from plan.place_id) or (p_data ? 'starts_at' and (p_data->>'starts_at')::timestamptz is distinct from plan.starts_at)
          or (p_data ? 'ends_at' and (p_data->>'ends_at')::timestamptz is distinct from plan.ends_at) then
          delete from public.plan_rsvps where plan_id=entity;
        end if;
        update public.plans set title=coalesce(p_data->>'title',title),place_id=case when p_data ? 'place_id' then (p_data->>'place_id')::uuid else place_id end,
          starts_at=coalesce((p_data->>'starts_at')::timestamptz,starts_at),ends_at=coalesce((p_data->>'ends_at')::timestamptz,(p_data->>'starts_at')::timestamptz+(plan.ends_at-plan.starts_at),ends_at),notes=coalesce(p_data->>'notes',notes),version=version+1,updated_at=now()
        where id=entity returning * into plan;
        if plan.starts_at<=now() then raise exception 'Future plan time required' using errcode='22023'; end if;
      elsif p_action='plan.confirm' then
        if plan.status='cancelled' or plan.starts_at<=now() then raise exception 'Future active plan required' using errcode='22023'; end if;
        update public.plans set status='confirmed',version=version+1,updated_at=now() where id=entity returning * into plan;
      elsif p_action='plan.cancel' then
        update public.plans set status='cancelled',version=version+1,updated_at=now() where id=entity returning * into plan;
      elsif p_action='plan.rsvp' then
        if plan.status='cancelled' then raise exception 'Plan is cancelled' using errcode='22023'; end if;
        insert into public.plan_rsvps(group_id,plan_id,user_id,status) values(p_group_id,entity,p_user_id,p_data->>'status')
        on conflict(plan_id,user_id) do update set status=excluded.status,updated_at=now();
      else
        if plan.status<>'confirmed' then raise exception 'Confirm plan before booking' using errcode='22023'; end if;
        if length(coalesce(p_data->>'reference',''))>500 then raise exception 'Booking reference too long' using errcode='22023'; end if;
        update public.plans set booking_status=p_data->>'status',booking_reference=p_data->>'reference',updated_at=now() where id=entity returning * into plan;
      end if;
      if p_action<>'plan.booking' then perform private.pal_sync_plan(entity); end if;
      result:=to_jsonb(plan);
    when 'reminder.create' then
      reminder:=public.create_reminder(p_group_id,p_user_id,p_data->>'body',(p_data->>'due_at')::timestamptz,coalesce(p_data->>'timezone',g.timezone),coalesce(v_key,gen_random_uuid()::text));
      entity:=reminder.id;
      targets:=coalesce(array(select x::uuid from jsonb_array_elements_text(coalesce(p_data->'target_user_ids','[]')) x),'{}');
      if exists(select 1 from unnest(targets) x where not exists(select 1 from public.group_members where group_id=p_group_id and user_id=x)) then raise exception 'Reminder targets must be group members' using errcode='42501'; end if;
      if p_data->>'plan_id' is not null and not exists(select 1 from public.plans where id=(p_data->>'plan_id')::uuid and group_id=p_group_id) then raise exception 'Group plan required' using errcode='42501'; end if;
      if p_data->>'poll_id' is not null and not exists(select 1 from public.polls where id=(p_data->>'poll_id')::uuid and group_id=p_group_id) then raise exception 'Group poll required' using errcode='42501'; end if;
      update public.reminders set target_user_ids=targets,plan_id=(p_data->>'plan_id')::uuid,poll_id=(p_data->>'poll_id')::uuid where id=entity returning * into reminder;
      perform private.pal_post_card(p_group_id,p_user_id,p_agent,'reminder',entity,reminder.body,v_key);
      result:=to_jsonb(reminder);
    when 'reminder.update','reminder.cancel' then
      select * into reminder from public.reminders where id=entity and group_id=p_group_id and requester_id=p_user_id for update;
      if not found then raise exception 'Only own reminder can be changed' using errcode='42501'; end if;
      if reminder.kind<>'reminder' then raise exception 'Change the associated plan or poll instead' using errcode='22023'; end if;
      if reminder.status='completed' then raise exception 'Delivered reminder cannot be changed' using errcode='22023'; end if;
      if p_action='reminder.cancel' then update public.reminders set status='cancelled',version=version+1 where id=entity returning * into reminder;
      else
        due:=coalesce((p_data->>'due_at')::timestamptz,reminder.due_at);tz:=coalesce(p_data->>'timezone',reminder.timezone);
        if not isfinite(due) or due<=now() or not exists(select 1 from pg_catalog.pg_timezone_names where name=tz) then raise exception 'Future time and IANA timezone required' using errcode='22023'; end if;
        targets:=case when p_data ? 'target_user_ids' then array(select x::uuid from jsonb_array_elements_text(p_data->'target_user_ids') x) else reminder.target_user_ids end;
        if exists(select 1 from unnest(targets) x where not exists(select 1 from public.group_members where group_id=p_group_id and user_id=x)) then raise exception 'Group targets required' using errcode='42501'; end if;
        if p_data->>'plan_id' is not null and not exists(select 1 from public.plans where id=(p_data->>'plan_id')::uuid and group_id=p_group_id) then raise exception 'Group plan required' using errcode='42501'; end if;
        if p_data->>'poll_id' is not null and not exists(select 1 from public.polls where id=(p_data->>'poll_id')::uuid and group_id=p_group_id) then raise exception 'Group poll required' using errcode='42501'; end if;
        update public.reminders set body=coalesce(p_data->>'body',body),due_at=due,timezone=tz,target_user_ids=targets,
          plan_id=case when p_data ? 'plan_id' then (p_data->>'plan_id')::uuid else plan_id end,poll_id=case when p_data ? 'poll_id' then (p_data->>'poll_id')::uuid else poll_id end,status='scheduled',version=version+1 where id=entity returning * into reminder;
      end if;
      update private.push_outbox set status='cancelled',lease_until=null where group_id=p_group_id and payload->>'reminder_id'=entity::text and status in ('queued','sending');
      result:=to_jsonb(reminder);
    else raise exception 'Unsupported action %',p_action using errcode='22023';
  end case;
  if v_key is not null then insert into private.action_receipts(group_id,user_id,action,source_key,input,result) values(p_group_id,p_user_id,p_action,v_key,p_data,result); end if;
  return result;
end $$;

create function private.pal_action(p_group_id uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
begin return private.pal_execute_action(p_group_id,auth.uid(),p_action,p_data,false); end $$;
create function public.pal_action(p_group_id uuid,p_action text,p_data jsonb) returns jsonb language sql set search_path='' as $$ select private.pal_action(p_group_id,p_action,p_data) $$;
create function private.pal_agent_action(p_group_id uuid,p_requester_id uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
begin return private.pal_execute_action(p_group_id,p_requester_id,p_action,p_data,true); end $$;
create function public.pal_agent_action(p_group_id uuid,p_requester_id uuid,p_action text,p_data jsonb) returns jsonb language sql set search_path='' as $$ select private.pal_agent_action(p_group_id,p_requester_id,p_action,p_data) $$;
create policy members_read_profiles on public.profiles for select to authenticated using (
  user_id=(select auth.uid()) or user_id in (select user_id from public.group_members where group_id in (select private.my_group_ids()))
);
create index sources_claim_idx on public.sources(status,next_attempt,lease_until);
create index push_outbox_claim_idx on private.push_outbox(status,next_attempt,lease_until);
create index google_sync_claim_idx on private.google_sync_items(state,next_attempt,lease_until);

create function private.pal_canonical_url(p_url text) returns text
language plpgsql immutable set search_path='' as $$
declare u text; parts text[];
begin
  if p_url is null then return null; end if;
  if length(p_url)>2000 or p_url !~ '^https?://[^[:space:]/?#]+' then raise exception 'Valid HTTP URL required' using errcode='22023'; end if;
  u:=split_part(p_url,'#',1);
  parts:=regexp_match(u,'^(https?://)([^/?#]+)(.*)$');
  u:=lower(parts[1]||parts[2])||parts[3];
  u:=regexp_replace(u,'([?&])(utm_[^=&]*|igsh|igshid|fbclid|gclid|si)=[^&]*','\1','gi');
  u:=replace(regexp_replace(u,'&+','&','g'),'?&','?');
  return regexp_replace(u,'[?&/]+$','');
end $$;

create function private.pal_profile_save(p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); r public.profiles; prefs jsonb;
begin
  if u is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_data is null or jsonb_typeof(p_data)<>'object' then raise exception 'Profile object required' using errcode='22023'; end if;
  select * into r from public.profiles where user_id=u for update;
  prefs:=coalesce(p_data->'notification_preferences',r.notification_preferences,'{"enabled":true}');
  if p_data ? 'notifications_enabled' then prefs:=prefs||jsonb_build_object('enabled',p_data->'notifications_enabled'); end if;
  if jsonb_typeof(prefs)<>'object' or (prefs ? 'enabled' and jsonb_typeof(prefs->'enabled')<>'boolean') then raise exception 'Notification enabled must be boolean' using errcode='22023'; end if;
  insert into public.profiles(user_id,display_name,avatar_url,notification_preferences)
  values(u,coalesce(p_data->>'display_name',r.display_name,'Member'),case when p_data ? 'avatar_url' then p_data->>'avatar_url' else r.avatar_url end,prefs)
  on conflict(user_id) do update set display_name=excluded.display_name,avatar_url=excluded.avatar_url,notification_preferences=excluded.notification_preferences,updated_at=now()
  returning * into r;
  return to_jsonb(r);
end $$;
create function public.pal_profile_save(p_data jsonb) returns jsonb language sql set search_path='' as $$ select private.pal_profile_save(p_data) $$;

create function private.pal_group_state(p_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if current_setting('role',true)<>'service_role' and not exists(select 1 from public.group_members where group_id=p_group_id and user_id=auth.uid()) then
    raise exception 'Group membership required' using errcode='42501';
  end if;
  if not exists(select 1 from public.groups where id=p_group_id) then raise exception 'Group not found' using errcode='22023'; end if;
  return jsonb_build_object(
    'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'display_name',coalesce(p.display_name,'Member'),'avatar_url',p.avatar_url,'last_read_at',m.last_read_at,'last_read_message_id',m.last_read_message_id) order by m.joined_at) from public.group_members m left join public.profiles p on p.user_id=m.user_id where m.group_id=p_group_id),'[]'),
    'places',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('contributors',coalesce((select jsonb_agg(jsonb_build_object('user_id',c.user_id,'source_id',c.source_id)) from public.place_contributors c where c.place_id=p.id),'[]')) order by p.created_at) from public.places p where p.group_id=p_group_id),'[]'),
    'sources',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('contributors',coalesce((select jsonb_agg(to_jsonb(c)) from public.source_contributors c where c.source_id=s.id),'[]')) order by s.created_at) from public.sources s where s.group_id=p_group_id),'[]'),
    'polls',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('votes',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'option_id',o)) from public.poll_responses r cross join lateral unnest(r.option_ids) o where r.poll_id=p.id),'[]')) order by p.created_at) from public.polls p where p.group_id=p_group_id),'[]'),
    'plans',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('attendees',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'status',r.status)) from public.plan_rsvps r where r.plan_id=p.id),'[]')) order by p.starts_at) from public.plans p where p.group_id=p_group_id),'[]'),
    'memories',coalesce((select jsonb_agg(to_jsonb(m)||jsonb_build_object('body',m.key||': '||m.value) order by m.updated_at) from public.member_memories m where m.group_id=p_group_id and (m.expires_at is null or m.expires_at>now())),'[]'),
    'reminders',coalesce((select jsonb_agg(to_jsonb(r) order by r.due_at) from public.reminders r where r.group_id=p_group_id),'[]'),
    'reactions',coalesce((select jsonb_agg(to_jsonb(r)) from public.message_reactions r where r.group_id=p_group_id),'[]'),
    'settings',(select jsonb_build_object('name',g.name,'timezone',g.timezone,'proactive_suggestions',g.proactive_suggestions,'agent_paused',g.agent_paused) from public.groups g where id=p_group_id)
  );
end $$;
create function public.pal_group_state(p_group_id uuid) returns jsonb language sql stable set search_path='' as $$ select private.pal_group_state(p_group_id) $$;

create function private.pal_post_card(p_group_id uuid,p_user_id uuid,p_agent boolean,p_type text,p_entity_id uuid,p_body text,p_source_key text) returns void
language sql set search_path='' as $$
  insert into public.messages(group_id,sender_id,role,body,card,source_key)
  values(p_group_id,case when p_agent then null else p_user_id end,case when p_agent then 'pal' else 'system' end,p_body,jsonb_build_object('type',p_type,'entity_id',p_entity_id),
    'card:'||p_type||':'||p_entity_id||case when p_type='place' then '' else ':'||coalesce(p_source_key,gen_random_uuid()::text) end)
  on conflict(group_id,source_key) do nothing
$$;

create function private.pal_sync_plan(p_plan_id uuid) returns void language plpgsql set search_path='' as $$
declare p public.plans;
begin
  select * into p from public.plans where id=p_plan_id;
  update public.reminders set status='cancelled',version=version+1 where plan_id=p.id and kind in ('plan_24h','plan_2h') and status='scheduled';
  update private.push_outbox set status='cancelled',lease_until=null where plan_id=p.id and status in ('queued','sending');
  update private.google_sync_items s set state='remove',desired_version=greatest(s.desired_version+1,p.version),attempts=0,next_attempt=now(),lease_until=null,updated_at=now()
    where s.plan_id=p.id and (p.status<>'confirmed' or not exists(select 1 from public.plan_rsvps r join public.group_members m on m.group_id=p.group_id and m.user_id=r.user_id where r.plan_id=p.id and r.user_id=s.user_id and r.status='going'));
  if p.status='confirmed' then
    insert into private.google_sync_items(plan_id,user_id,desired_version)
    select p.id,r.user_id,p.version from public.plan_rsvps r
    join public.group_members m on m.group_id=p.group_id and m.user_id=r.user_id
    join private.google_connections c on c.user_id=r.user_id and c.status='connected'
    where r.plan_id=p.id and r.status='going'
    on conflict(plan_id,user_id) do update set desired_version=greatest(google_sync_items.desired_version+1,excluded.desired_version),attempts=0,state='pending',next_attempt=now(),lease_until=null,updated_at=now();
    insert into public.reminders(group_id,requester_id,body,due_at,timezone,source_key,plan_id,kind)
    select p.group_id,p.created_by,p.title,p.starts_at-v.gap,g.timezone,'plan:'||p.id||':'||p.version||':'||v.kind,p.id,v.kind
    from public.groups g cross join (values('plan_24h',interval '24 hours'),('plan_2h',interval '2 hours')) v(kind,gap)
    where g.id=p.group_id and p.starts_at-v.gap>now()
    on conflict(group_id,source_key) do update set status='scheduled',due_at=excluded.due_at;
  end if;
end $$;

create function private.send_message(p_group_id uuid,p_body text,p_client_id uuid,p_reply_to_id uuid) returns public.messages
language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); m public.messages; g public.groups; fresh boolean; explicit boolean; link text; s public.sources;
begin
  select * into g from public.groups where id=p_group_id for update;
  if u is null or not found or not exists(select 1 from public.group_members where group_id=p_group_id and user_id=u) then raise exception 'Group membership required' using errcode='42501'; end if;
  if p_client_id is null or p_body is null or length(btrim(p_body)) not between 1 and 8000 then raise exception 'Valid message and client ID required' using errcode='22023'; end if;
  if p_reply_to_id is not null and not exists(select 1 from public.messages where id=p_reply_to_id and group_id=p_group_id) then raise exception 'Reply must reference the same group' using errcode='42501'; end if;
  insert into public.messages(group_id,sender_id,role,body,client_id,reply_to_id) values(p_group_id,u,'user',btrim(p_body),p_client_id,p_reply_to_id)
  on conflict(group_id,sender_id,client_id) do nothing returning * into m;
  fresh:=found;
  if not fresh then
    select * into m from public.messages where group_id=p_group_id and sender_id=u and client_id=p_client_id;
    if m.body<>btrim(p_body) or m.reply_to_id is distinct from p_reply_to_id then raise exception 'Client ID already used for another message' using errcode='22023'; end if;
    return m;
  end if;
  explicit:=m.body ~* '(^|[[:space:]])@pal([[:space:][:punct:]]|$)';
  if not g.agent_paused then
    if not explicit then update public.agent_jobs set run_after=now()+interval '10 seconds' where group_id=p_group_id and status='queued' and not explicit_mention; end if;
    insert into public.agent_jobs(message_id,group_id,requester_id,run_after,explicit_mention)
    values(m.id,p_group_id,u,case when explicit then now() else now()+interval '10 seconds' end,explicit);
  end if;
  for link in select rtrim(x[1],'.!,;:)') from regexp_matches(m.body,'https?://[^[:space:]<>]+','g') x loop
    begin
    insert into public.sources(group_id,created_by,source_message_id,url,canonical_url)
    values(p_group_id,u,m.id,link,private.pal_canonical_url(link))
    on conflict(group_id,canonical_url) do update set updated_at=now() returning * into s;
    insert into public.source_contributors(group_id,source_id,user_id,source_message_id) values(p_group_id,s.id,u,m.id) on conflict(source_id,user_id) do nothing;
    perform private.pal_post_card(p_group_id,u,true,'place',s.id,'Finding places from this link','source:'||s.id);
    exception when invalid_parameter_value then continue;
    end;
  end loop;
  return m;
end $$;
create or replace function private.send_message(p_group_id uuid,p_body text,p_client_id uuid) returns public.messages
language sql security definer set search_path='' as $$ select private.send_message(p_group_id,p_body,p_client_id,null) $$;
create function public.send_message(p_group_id uuid,p_body text,p_client_id uuid,p_reply_to_id uuid) returns public.messages
language sql set search_path='' as $$ select private.send_message(p_group_id,p_body,p_client_id,p_reply_to_id) $$;

create or replace function public.claim_agent_jobs(p_limit integer default 5) returns setof public.agent_jobs
language plpgsql set search_path='' as $$
declare g uuid; j public.agent_jobs; mids uuid[];
begin
  if p_limit is null or p_limit not between 1 and 20 then raise exception 'Limit must be 1-20' using errcode='22023'; end if;
  update public.agent_jobs set status='failed',last_error='Worker lease expired after maximum attempts',lease_until=null where status='running' and lease_until<now() and attempts>=3;
  for g in select groups.id from public.groups
    where not groups.agent_paused and exists(select 1 from public.agent_jobs q where q.group_id=groups.id and q.attempts<3 and (q.job_kind<>'weekly' or groups.proactive_suggestions) and ((q.status='queued' and q.run_after<=now()) or (q.status='running' and q.lease_until<now())))
      and not exists(select 1 from public.agent_jobs active where active.group_id=groups.id and active.status='running' and active.lease_until>=now())
    order by groups.created_at for update skip locked limit p_limit
  loop
    select * into j from public.agent_jobs where group_id=g and attempts<3 and ((status='queued' and run_after<=now()) or (status='running' and lease_until<now()))
      order by (status='running') desc,explicit_mention desc,created_at,id for update skip locked limit 1;
    if not found then continue; end if;
    if cardinality(j.batch_message_ids)=0 then
      select array_agg(q.message_id order by q.created_at,q.id) into mids from public.agent_jobs q where q.group_id=g and q.status='queued' and q.run_after<=now();
      mids:=coalesce(mids,array[j.message_id]);
      update public.agent_jobs set status='coalesced',coalesced_into=j.id,completed_at=now() where group_id=g and id<>j.id and status='queued' and message_id=any(mids);
    else mids:=j.batch_message_ids;
    end if;
    update public.agent_jobs set status='running',attempts=attempts+1,lease_until=now()+interval '5 minutes',batch_message_ids=mids where id=j.id returning * into j;
    return next j;
  end loop;
end $$;

create or replace function public.complete_agent_job(p_job_id uuid,p_attempt integer,p_body text,p_result text default null) returns boolean
language plpgsql set search_path='' as $$
declare j public.agent_jobs;
begin
  if length(coalesce(p_body,''))>8000 then raise exception 'Pal response too long' using errcode='22023'; end if;
  select * into j from public.agent_jobs where id=p_job_id and attempts=p_attempt and status='running' for update;
  if not found then return false; end if;
  if length(btrim(coalesce(p_body,'')))>0 then
    insert into public.messages(group_id,role,body,source_key) values(j.group_id,'pal',btrim(p_body),'job:'||j.id) on conflict(group_id,source_key) do nothing;
  end if;
  update public.agent_jobs set status='completed',result=p_result,lease_until=null,completed_at=now() where id=j.id;
  return true;
end $$;

create function public.pal_claim_sources(p_limit integer default 5) returns setof public.sources
language plpgsql set search_path='' as $$
begin
  if p_limit is null or p_limit not between 1 and 20 then raise exception 'Limit must be 1-20' using errcode='22023'; end if;
  update public.sources set status='failed',last_error='Extraction retry limit reached' where status in ('pending','resolving') and attempts>=60 and coalesce(lease_until,now())<=now();
  return query with picked as (
    select id from public.sources where status in ('pending','resolving') and next_attempt<=now() and (lease_until is null or lease_until<now()) and attempts<60
    order by created_at for update skip locked limit p_limit
  ) update public.sources s set status='resolving',attempts=attempts+1,lease_until=now()+interval '5 minutes',updated_at=now()
    from picked p where s.id=p.id returning s.*;
end $$;

create function public.pal_complete_source(p_id uuid,p_result jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare s public.sources; ids uuid[]; v_status text; item jsonb; place public.places;
begin
  select * into s from public.sources where id=p_id for update;
  if not found then raise exception 'Source not found' using errcode='22023'; end if;
  if p_result ? 'expected_attempt' and s.attempts<>(p_result->>'expected_attempt')::integer then return jsonb_build_object('ok',false); end if;
  if s.status<>'resolving' then return jsonb_build_object('ok',false); end if;
  ids:=case when p_result ? 'place_ids' then array(select x::uuid from jsonb_array_elements_text(p_result->'place_ids') x) else s.place_ids end;
  if exists(select 1 from unnest(ids) x where not exists(select 1 from public.places where id=x and group_id=s.group_id)) then raise exception 'Source places must belong to the group' using errcode='42501'; end if;
  for item in select value from jsonb_array_elements(coalesce(p_result->'places','[]')) loop
    if item->>'provider_id' is null or item->>'latitude' is null or item->>'longitude' is null then raise exception 'Resolved place needs provider identity and coordinates' using errcode='22023'; end if;
    insert into public.places(group_id,created_by,name,address,latitude,longitude,provider,provider_id,status,website,booking_url)
    values(s.group_id,s.created_by,item->>'name',coalesce(item->>'address',''),(item->>'latitude')::double precision,(item->>'longitude')::double precision,coalesce(item->>'provider','google'),item->>'provider_id','resolved',item->>'website',item->>'booking_url')
    on conflict(group_id,provider,provider_id) do update set updated_at=now() returning * into place;
    if not place.id=any(ids) then ids:=array_append(ids,place.id); end if;
  end loop;
  v_status:=coalesce(p_result->>'status',case when cardinality(ids)>0 then 'resolved' else 'needs_confirmation' end);
  if v_status not in ('resolving','resolved','needs_confirmation','failed') then raise exception 'Invalid extraction state' using errcode='22023'; end if;
  update public.sources set title=coalesce(p_result->>'title',title),status=v_status,candidates=coalesce(p_result->'candidates',candidates),place_ids=ids,
    provider_job_id=coalesce(p_result->>'provider_job_id',provider_job_id),extraction=coalesce(p_result->'extraction',extraction),metadata=coalesce(p_result->'metadata',metadata),lease_until=null,next_attempt=now()+interval '30 seconds',last_error=p_result->>'error',updated_at=now()
  where id=p_id returning * into s;
  insert into public.place_contributors(group_id,place_id,user_id,source_id)
  select s.group_id,place_id,c.user_id,s.id from unnest(ids) place_id cross join public.source_contributors c where c.source_id=s.id
  on conflict do nothing;
  return to_jsonb(s);
end $$;
create function public.pal_fail_source(p_id uuid,p_error text) returns jsonb
language plpgsql set search_path='' as $$
declare s public.sources;
begin update public.sources set status='failed',last_error=left(p_error,2000),lease_until=null,updated_at=now() where id=p_id and status='resolving' returning * into s; return to_jsonb(s); end $$;

create function private.pal_next_awake(p_time timestamptz,p_timezone text) returns timestamptz
language sql stable set search_path='' as $$
  select case when extract(hour from p_time at time zone p_timezone) between 9 and 21 then p_time
    else (date_trunc('day',p_time at time zone p_timezone)+interval '9 hours'+case when extract(hour from p_time at time zone p_timezone)>=22 then interval '1 day' else interval '0 days' end) at time zone p_timezone end
$$;

create function private.pal_queue_push() returns trigger
language plpgsql security definer set search_path='' as $$
declare r public.reminders; tz text; due timestamptz;
begin
  select timezone into tz from public.groups where id=new.group_id;
  if new.source_key like 'reminder:%' then select * into r from public.reminders where id=split_part(new.source_key,':',2)::uuid; end if;
  due:=private.pal_next_awake(now(),tz);
  insert into private.push_outbox(message_id,group_id,user_id,plan_id,payload,next_attempt,source_key)
  select new.id,new.group_id,m.user_id,r.plan_id,
    jsonb_build_object('aps',jsonb_build_object('alert',jsonb_build_object('title','Pal','body',left(new.body,120)),'sound','default'),
      'group_id',new.group_id,'message_id',new.id,'reminder_id',r.id,'plan_id',r.plan_id,'poll_id',r.poll_id),
    due,'message:'||new.id||':user:'||m.user_id
  from public.group_members m left join public.profiles p on p.user_id=m.user_id
  where m.group_id=new.group_id and m.user_id is distinct from new.sender_id and coalesce(p.notifications_enabled,true)
    and (r.id is null or cardinality(r.target_user_ids)=0 or m.user_id=any(r.target_user_ids))
    and (r.poll_id is null or not exists(select 1 from public.poll_responses v where v.poll_id=r.poll_id and v.user_id=m.user_id))
    and (r.id is null or r.kind not in ('plan_24h','plan_2h') or exists(select 1 from public.plan_rsvps v where v.plan_id=r.plan_id and v.user_id=m.user_id and v.status='going'))
  on conflict(source_key) do nothing;
  return new;
end $$;
create trigger pal_push_message after insert on public.messages for each row execute function private.pal_queue_push();

create or replace function private.deliver_due_reminders() returns integer
language plpgsql security definer set search_path='' as $$
declare r public.reminders; g public.groups; p public.plans; targets uuid[]; delivered integer:=0; awake timestamptz;
begin
  for r in select * from public.reminders where status='scheduled' and due_at<=now() order by due_at,id for update skip locked limit 100 loop
    select * into g from public.groups where id=r.group_id;
    if r.kind<>'reminder' then
      awake:=private.pal_next_awake(now(),g.timezone);
      if awake>now() then
        if r.plan_id is not null and exists(select 1 from public.plans where id=r.plan_id and starts_at<=awake) then update public.reminders set status='cancelled' where id=r.id;
        else update public.reminders set due_at=awake where id=r.id;
        end if;
        continue;
      end if;
    end if;
    select array_agg(m.user_id) into targets from public.group_members m
    where m.group_id=r.group_id and (cardinality(r.target_user_ids)=0 or m.user_id=any(r.target_user_ids))
      and (r.poll_id is null or (exists(select 1 from public.polls where id=r.poll_id and status='open') and not exists(select 1 from public.poll_responses v where v.poll_id=r.poll_id and v.user_id=m.user_id)))
      and (r.kind not in ('plan_24h','plan_2h') or (exists(select 1 from public.plans where id=r.plan_id and status='confirmed' and starts_at>now()) and exists(select 1 from public.plan_rsvps v where v.plan_id=r.plan_id and v.user_id=m.user_id and v.status='going')));
    if cardinality(targets) is null or cardinality(targets)=0 then update public.reminders set status='cancelled' where id=r.id; continue; end if;
    insert into public.messages(group_id,role,body,card,source_key)
    values(r.group_id,'pal',case when r.kind in ('poll_halfway','poll_deadline') then 'Still waiting for a few responses: ' else 'Reminder: ' end||r.body,
      jsonb_build_object('type',case when r.poll_id is not null then (select case when kind='place' then 'choice' else 'availability' end from public.polls where id=r.poll_id) when r.plan_id is not null then 'plan' else 'reminder' end,'entity_id',coalesce(r.poll_id,r.plan_id,r.id)),
      'reminder:'||r.id||':'||r.version) on conflict(group_id,source_key) do nothing;
    update public.reminders set status='completed',completed_at=now() where id=r.id;
    if r.kind='poll_deadline' then update public.polls set status='closed' where id=r.poll_id; end if;
    delivered:=delivered+1;
  end loop;
  for g in select * from public.groups where proactive_suggestions and not agent_paused and (last_weekly_at is null or last_weekly_at<=now()-interval '7 days')
    and extract(isodow from now() at time zone timezone)=1 and extract(hour from now() at time zone timezone)=10 for update skip locked loop
    if exists(select 1 from public.group_members where group_id=g.id and user_id=g.creator_id) and exists(select 1 from public.places where group_id=g.id) then
      insert into public.messages(group_id,role,body,source_key) values(g.id,'system','Suggest one optional hangout using our saved places and current preferences.','weekly:'||g.id||':'||to_char(now() at time zone g.timezone,'IYYY-IW'))
      on conflict(group_id,source_key) do nothing returning id into r.id;
      if found then insert into public.agent_jobs(message_id,group_id,requester_id,run_after,explicit_mention,job_kind) values(r.id,g.id,g.creator_id,now(),false,'weekly'); end if;
      update public.groups set last_weekly_at=now() where id=g.id;
    end if;
  end loop;
  return delivered;
end $$;

create function private.pal_integration_row(p_kind text,p_id uuid) returns jsonb language plpgsql stable set search_path='' as $$
declare r jsonb;
begin
  if p_kind not in ('oauth_states','google_connections','google_sync_items','push_devices','push_outbox') then raise exception 'Invalid integration kind' using errcode='22023'; end if;
  execute format('select to_jsonb(t) from private.%I t where id=$1',p_kind) into r using p_id;
  if p_kind='google_sync_items' and r is not null then
    r:=r||jsonb_build_object(
      'plan',(select to_jsonb(p) from public.plans p where p.id=(r->>'plan_id')::uuid),
      'place',(select to_jsonb(s) from public.places s join public.plans p on p.place_id=s.id where p.id=(r->>'plan_id')::uuid),
      'group',(select to_jsonb(g) from public.groups g join public.plans p on p.group_id=g.id where p.id=(r->>'plan_id')::uuid),
      'connection',(select to_jsonb(c) from private.google_connections c where c.user_id=(r->>'user_id')::uuid),
      'sync_required',exists(select 1 from public.plans p join public.plan_rsvps a on a.plan_id=p.id join public.group_members m on m.group_id=p.group_id and m.user_id=a.user_id
        where p.id=(r->>'plan_id')::uuid and a.user_id=(r->>'user_id')::uuid and a.status='going' and p.status='confirmed')
    );
  elsif p_kind='push_outbox' and r is not null then
    r:=r||jsonb_build_object('devices',coalesce((select jsonb_agg(to_jsonb(d)) from private.push_devices d where d.user_id=(r->>'user_id')::uuid and d.enabled),'[]'));
  end if;
  return r;
end $$;
create function private.pal_maintenance() returns integer language sql security definer set search_path='' as $$ select private.deliver_due_reminders() $$;
create function public.pal_maintenance() returns integer language sql set search_path='' as $$ select private.pal_maintenance() $$;

create function public.pal_integration_state(p_kind text,p_limit integer default 100) returns jsonb
language plpgsql set search_path='' as $$
declare r jsonb;
begin
  if p_kind not in ('oauth_states','google_connections','google_sync_items','push_devices','push_outbox') or p_limit is null or p_limit not between 1 and 200 then raise exception 'Invalid integration kind or limit' using errcode='22023'; end if;
  execute format('select coalesce(jsonb_agg(private.pal_integration_row($1,id)),''[]''::jsonb) from (select id from private.%I order by id limit $2) t',p_kind) into r using p_kind,p_limit;
  return r;
end $$;

create function public.pal_integration_update(p_kind text,p_id uuid,p_data jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare op text:=coalesce(p_data->>'op','put'); result jsonb; item jsonb; rowid uuid; lim integer:=coalesce((p_data->>'limit')::integer,10); prev text; done boolean; resync boolean; conn private.google_connections; sync private.google_sync_items; push private.push_outbox;
begin
  if p_kind is null or p_kind not in ('oauth_states','google_connections','google_sync_items','push_devices','push_outbox') or p_data is null or jsonb_typeof(p_data)<>'object' then raise exception 'Invalid integration operation' using errcode='22023'; end if;
  if op='get' then
    if p_kind='google_connections' and p_id is null then select id into p_id from private.google_connections where user_id=(p_data->>'user_id')::uuid; end if;
    return private.pal_integration_row(p_kind,p_id);
  elsif op='delete' then
    if p_kind='google_connections' then
      select * into conn from private.google_connections where id=p_id for update;
      update private.google_sync_items set state='remove',next_attempt=now(),lease_until=null where user_id=conn.user_id;
    end if;
    execute format('delete from private.%I where id=$1',p_kind) using p_id;
    return jsonb_build_object('ok',true);
  elsif op='claim' then
    if p_kind='oauth_states' then
      update private.oauth_states set consumed_at=now() where (id=p_id or (p_id is null and state_hash=p_data->>'state_hash')) and consumed_at is null and expires_at>now() returning to_jsonb(oauth_states) into result;
      return result;
    elsif p_kind='google_connections' then
      update private.google_connections set calendar_lease_until=now()+interval '5 minutes',calendar_attempts=calendar_attempts+1
      where id=p_id and calendar_id is null and status='connected' and (calendar_lease_until is null or calendar_lease_until<now()) returning to_jsonb(google_connections) into result;
      return result;
    elsif p_kind in ('google_sync_items','push_outbox') then
      if lim not between 1 and 20 then raise exception 'Claim limit must be 1-20' using errcode='22023'; end if;
      result:='[]';
      if p_kind='google_sync_items' then
        for sync in select * from private.google_sync_items where (p_id is null or id=p_id) and next_attempt<=now() and ((state in ('pending','remove','failed') and (lease_until is null or lease_until<now())) or (state='syncing' and lease_until<now())) and attempts<10
          and exists(select 1 from private.google_connections c where c.user_id=google_sync_items.user_id and c.status='connected') order by next_attempt,id for update skip locked limit lim loop
          prev:=sync.state;
          update private.google_sync_items set state='syncing',attempts=attempts+1,lease_until=now()+interval '5 minutes' where id=sync.id;
          result:=result||jsonb_build_array(private.pal_integration_row(p_kind,sync.id)||jsonb_build_object('previous_state',prev));
        end loop;
      else
        for push in select * from private.push_outbox where (p_id is null or id=p_id) and next_attempt<=now() and ((status='queued' and (lease_until is null or lease_until<now())) or (status='sending' and lease_until<now())) and attempts<5 order by next_attempt,id for update skip locked limit lim loop
          if not exists(select 1 from public.group_members m left join public.profiles p on p.user_id=m.user_id where m.group_id=push.group_id and m.user_id=push.user_id and coalesce(p.notifications_enabled,true))
            or (push.payload->>'reminder_id' is not null and not exists(select 1 from public.reminders where id=(push.payload->>'reminder_id')::uuid and status='completed'))
            or (push.plan_id is not null and not exists(select 1 from public.plans p join public.plan_rsvps a on a.plan_id=p.id where p.id=push.plan_id and p.status='confirmed' and a.user_id=push.user_id and a.status='going')) then
            update private.push_outbox set status='cancelled',lease_until=null where id=push.id;continue;
          end if;
          update private.push_outbox set status='sending',attempts=attempts+1,lease_until=now()+interval '5 minutes' where id=push.id;
          result:=result||jsonb_build_array(private.pal_integration_row(p_kind,push.id));
        end loop;
      end if;
      return result;
    else raise exception 'This integration cannot be claimed' using errcode='22023';
    end if;
  elsif op='finish' then
    if p_kind='google_connections' then
      update private.google_connections set calendar_id=p_data->>'calendar_id',calendar_lease_until=null,error=p_data->>'error',updated_at=now()
      where id=p_id and calendar_attempts=(p_data->>'expected_attempt')::integer and calendar_lease_until>now() and status='connected';
      return jsonb_build_object('ok',found);
    elsif p_kind='google_sync_items' then
      select * into sync from private.google_sync_items where id=p_id for update;
      if not found then return jsonb_build_object('ok',false); end if;
      if not p_data ? 'expected_attempt' or not p_data ? 'expected_version' then raise exception 'Sync attempt and version required' using errcode='22023'; end if;
      if sync.attempts<>(p_data->>'expected_attempt')::integer or sync.desired_version<>(p_data->>'expected_version')::integer or sync.state<>'syncing' then
        if sync.state='synced' then update private.google_sync_items set state='pending',next_attempt=now(),updated_at=now() where id=p_id; end if;
        return jsonb_build_object('ok',false);
      end if;
      update private.google_sync_items set state=coalesce(p_data->>'state','synced'),event_id=case when p_data ? 'event_id' then p_data->>'event_id' else event_id end,error=p_data->>'error',
        next_attempt=coalesce((p_data->>'next_attempt')::timestamptz,now()+interval '1 minute'),lease_until=null,updated_at=now() where id=p_id;
      return jsonb_build_object('ok',true);
    elsif p_kind='push_outbox' then
      update private.push_outbox set status=coalesce(p_data->>'status','sent'),error=p_data->>'error',next_attempt=coalesce((p_data->>'next_attempt')::timestamptz,now()+interval '1 minute'),lease_until=null,
        sent_at=case when coalesce(p_data->>'status','sent')='sent' then now() else null end
      where id=p_id and attempts=(p_data->>'expected_attempt')::integer and status='sending';
      return jsonb_build_object('ok',found);
    else raise exception 'This integration cannot be finished' using errcode='22023'; end if;
  elsif op<>'put' then raise exception 'Unsupported integration operation' using errcode='22023';
  end if;
  if p_kind='oauth_states' then
    insert into private.oauth_states(id,user_id,state_hash,encrypted_code_verifier,expires_at)
    values(coalesce(p_id,gen_random_uuid()),(p_data->>'user_id')::uuid,p_data->>'state_hash',p_data->>'encrypted_code_verifier',coalesce((p_data->>'expires_at')::timestamptz,now()+interval '10 minutes')) returning to_jsonb(oauth_states) into result;
  elsif p_kind='google_connections' then
    perform pg_advisory_xact_lock(hashtextextended('google-connection:'||coalesce(p_data->>'user_id',p_id::text),0));
    select * into conn from private.google_connections where (p_id is not null and id=p_id) or (p_id is null and user_id=(p_data->>'user_id')::uuid) for update;
    resync:=not found or coalesce((p_data->>'resync')::boolean,false) or (conn.status<>'connected' and p_data->>'status'='connected');
    if conn.id is not null then
      if (p_data ? 'expected_status' and conn.status<>p_data->>'expected_status') or (p_data ? 'expected_encrypted_refresh_token' and conn.encrypted_refresh_token<>p_data->>'expected_encrypted_refresh_token') then return null; end if;
      update private.google_connections set encrypted_refresh_token=coalesce(p_data->>'encrypted_refresh_token',encrypted_refresh_token),
        encrypted_access_token=case when p_data ? 'encrypted_access_token' then p_data->>'encrypted_access_token' else encrypted_access_token end,
        calendar_id=case when p_data ? 'calendar_id' then p_data->>'calendar_id' else calendar_id end,
        expires_at=case when p_data ? 'expires_at' then (p_data->>'expires_at')::timestamptz else expires_at end,
        status=coalesce(p_data->>'status',status),error=case when p_data ? 'error' then p_data->>'error' else error end,updated_at=now()
      where id=conn.id returning * into conn;
    else
      insert into private.google_connections(id,user_id,calendar_id,encrypted_refresh_token,encrypted_access_token,expires_at,status,error)
      values(coalesce(p_id,gen_random_uuid()),(p_data->>'user_id')::uuid,p_data->>'calendar_id',p_data->>'encrypted_refresh_token',p_data->>'encrypted_access_token',(p_data->>'expires_at')::timestamptz,coalesce(p_data->>'status','connected'),p_data->>'error') returning * into conn;
    end if;
    if conn.status='connected' and resync then
      insert into private.google_sync_items(plan_id,user_id,desired_version)
      select p.id,conn.user_id,p.version from public.plans p join public.plan_rsvps r on r.plan_id=p.id join public.group_members m on m.group_id=p.group_id and m.user_id=r.user_id
      where p.status='confirmed' and r.user_id=conn.user_id and r.status='going'
      on conflict(plan_id,user_id) do update set state='pending',desired_version=greatest(google_sync_items.desired_version+1,excluded.desired_version),attempts=0,next_attempt=now(),lease_until=null,updated_at=now();
    end if;
    result:=to_jsonb(conn);
  elsif p_kind='push_devices' then
    update private.push_devices set enabled=coalesce((p_data->>'enabled')::boolean,enabled),updated_at=now()
      where id=p_id and (not p_data ? 'expected_updated_at' or updated_at=(p_data->>'expected_updated_at')::timestamptz) returning to_jsonb(push_devices) into result;
  elsif p_kind='google_sync_items' then
    update private.google_sync_items set state=coalesce(p_data->>'state',state),event_id=case when p_data ? 'event_id' then p_data->>'event_id' else event_id end,
      error=p_data->>'error',next_attempt=coalesce((p_data->>'next_attempt')::timestamptz,next_attempt),updated_at=now() where id=p_id returning to_jsonb(google_sync_items) into result;
  else raise exception 'Push outbox is populated by message delivery' using errcode='22023';
  end if;
  return result;
end $$;

create function private.pal_device_register(p_token text,p_environment text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); d uuid;
begin
  if u is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_token !~ '^[a-fA-F0-9]{64,200}$' or p_token is null or p_environment not in ('sandbox','production') or p_environment is null then raise exception 'Valid device token and environment required' using errcode='22023'; end if;
  insert into private.push_devices(user_id,token,environment) values(u,lower(p_token),p_environment)
  on conflict(token,environment) do update set user_id=u,enabled=true,updated_at=now() returning id into d;
  return jsonb_build_object('ok',true,'id',d);
end $$;
create function public.pal_device_register(p_token text,p_environment text) returns jsonb language sql set search_path='' as $$ select private.pal_device_register(p_token,p_environment) $$;
create function private.pal_device_delete(p_token text,p_environment text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  update private.push_devices set enabled=false,updated_at=now() where user_id=auth.uid() and token=lower(p_token) and environment=p_environment;
  return jsonb_build_object('ok',true);
end $$;
create function public.pal_device_delete(p_token text,p_environment text) returns jsonb language sql set search_path='' as $$ select private.pal_device_delete(p_token,p_environment) $$;

-- Explicit grants also override Supabase's direct default privileges.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure::text signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.proname like 'pal\_%' escape '\' loop
    execute 'revoke all on function '||f.signature||' from public,anon,authenticated,service_role';
  end loop;
end $$;
grant execute on function public.pal_action(uuid,text,jsonb),private.pal_action(uuid,text,jsonb),public.pal_profile_save(jsonb),private.pal_profile_save(jsonb),
  public.pal_device_register(text,text),private.pal_device_register(text,text),public.pal_device_delete(text,text),private.pal_device_delete(text,text) to authenticated;
grant execute on function public.pal_group_state(uuid),private.pal_group_state(uuid) to authenticated,service_role;
grant execute on function public.pal_agent_action(uuid,uuid,text,jsonb),private.pal_agent_action(uuid,uuid,text,jsonb),
  public.pal_maintenance(),private.pal_maintenance(),
  public.pal_claim_sources(integer),public.pal_complete_source(uuid,jsonb),public.pal_fail_source(uuid,text),
  public.pal_integration_state(text,integer),public.pal_integration_update(text,uuid,jsonb),private.pal_integration_row(text,uuid) to service_role;
revoke all on function public.send_message(uuid,text,uuid,uuid),private.send_message(uuid,text,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.send_message(uuid,text,uuid,uuid),private.send_message(uuid,text,uuid,uuid) to authenticated;
revoke all on function private.deliver_due_reminders() from public,anon,authenticated,service_role;

do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    alter publication supabase_realtime add table public.profiles,public.message_reactions,public.sources,public.places,public.place_contributors,public.polls,public.poll_responses,public.plans,public.plan_rsvps,public.member_memories;
  end if;
end $$;
