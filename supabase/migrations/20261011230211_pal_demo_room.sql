-- The scripted cast is limited to explicitly registered rehearsal rooms.
alter table public.groups add column is_demo boolean not null default false;
create table private.pal_demo_rooms (
 group_id uuid primary key references public.groups(id) on delete cascade,
 next_step integer not null default 0 check(next_step between 0 and 6),
 active_run uuid, generation uuid not null default gen_random_uuid(), starts_at timestamptz not null,
 base_place_ids uuid[] not null default '{}'
);
create table private.pal_demo_actors (
 group_id uuid not null references private.pal_demo_rooms(group_id) on delete cascade,
 user_id uuid not null, position integer not null check(position between 0 and 2),
 primary key(group_id,user_id), unique(group_id,position),
 foreign key(group_id,user_id) references public.group_members(group_id,user_id) on delete cascade
);
create table private.pal_demo_runs (
 id uuid primary key, group_id uuid not null references private.pal_demo_rooms(group_id) on delete cascade,
 user_id uuid not null references auth.users(id), client_id uuid not null, step integer not null,
 body text not null, message_id uuid references public.messages(id) on delete cascade,
 unique(group_id,user_id,client_id)
);
create table private.pal_demo_lines (
 run_id uuid not null references private.pal_demo_runs(id) on delete cascade,
 position integer not null, user_id uuid not null references auth.users(id),
 body text not null check(length(body) between 1 and 1000), due_at timestamptz not null,
 emitted_at timestamptz, primary key(run_id,position)
);
-- No exposed table or user-editable metadata authorizes the simulated cast.
do $$ declare t text; begin
 foreach t in array array['pal_demo_rooms','pal_demo_actors','pal_demo_runs','pal_demo_lines'] loop
 execute format('alter table private.%I enable row level security',t);
 execute format('revoke all on private.%I from public,anon,authenticated',t);
 execute format('grant all on private.%I to service_role',t);
 end loop;
end $$;
create function private.pal_demo_state(p_group_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('generation',d.generation,'step',d.next_step,'total',6,'run_id',d.active_run,'starts_at',d.starts_at,
 'status',case when exists(select 1 from private.pal_demo_lines l where l.run_id=d.active_run and l.emitted_at is null) then 'actors'
 when j.status in ('queued','running') then 'pal' when j.status='failed' then 'failed' else 'ready' end)
 from private.pal_demo_rooms d left join private.pal_demo_runs r on r.id=d.active_run
 left join lateral (
 select work.status from public.agent_jobs work join public.messages msg on msg.id=r.message_id
 where work.group_id=d.group_id and work.created_at>=msg.created_at and work.status not in ('coalesced','cancelled')
 order by work.created_at desc,work.id desc limit 1
 ) j on true where d.group_id=p_group_id
$$;
revoke all on function private.pal_demo_state(uuid) from public,anon,authenticated;
alter function private.pal_group_state(uuid) rename to pal_group_state_before_demo;
create function private.pal_group_state(p_group_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
 declare state jsonb; begin
 state:=private.pal_group_state_before_demo(p_group_id);
 return state||jsonb_build_object('demo',private.pal_demo_state(p_group_id))
   ||jsonb_build_object('settings',(state->'settings')||jsonb_build_object('is_demo',(select is_demo from public.groups where id=p_group_id)));
 end $$;
revoke all on function private.pal_group_state(uuid) from public,anon;
grant execute on function private.pal_group_state(uuid) to authenticated,service_role;
do $$ declare definition text:=pg_get_functiondef('private.pal_inbox()'::regprocedure); needle text:=$n$'is_direct',g.is_direct,$n$; begin
 if position(needle in definition)=0 then raise exception 'Expected current inbox shape'; end if;
 execute replace(definition,needle,$n$'is_direct',g.is_direct,'is_demo',g.is_demo,$n$);
end $$;
-- Group locks already serialize claiming/completion/reset. Never claim a partly spoken scene.
do $$ declare definition text:=pg_get_functiondef('public.claim_agent_jobs(integer)'::regprocedure); needle text:='where not groups.agent_paused and exists'; begin
 if position(needle in definition)=0 then raise exception 'Expected current worker scope'; end if;
 execute replace(definition,needle,'where not groups.agent_paused and not exists(select 1 from private.pal_demo_rooms d join private.pal_demo_lines l on l.run_id=d.active_run where d.group_id=groups.id and l.emitted_at is null) and exists');
end $$;
-- Rehearsals never send push notifications or create Google calendar copies.
do $$ declare definition text; begin
 definition:=pg_get_functiondef('private.pal_queue_push()'::regprocedure);
 execute replace(definition,E'begin\n',E'begin\n  if exists(select 1 from public.groups where id=new.group_id and is_demo) then return new; end if;\n');
 definition:=pg_get_functiondef('private.pal_sync_plan(uuid)'::regprocedure);
 execute replace(definition,'select * into p from public.plans where id=p_plan_id;',
 'select * into p from public.plans where id=p_plan_id; if exists(select 1 from public.groups where id=p.group_id and is_demo) then return; end if;');
 definition:=pg_get_functiondef('public.pal_integration_update(text,uuid,jsonb)'::regprocedure);
 -- Connecting Calendar after a rehearsal also must not backfill its plans.
 execute replace(definition,$n$where p.status='confirmed' and r.user_id=conn.user_id$n$,
 $n$where p.status='confirmed' and not exists(select 1 from public.groups where id=p.group_id and is_demo) and r.user_id=conn.user_id$n$);
end $$;
create function public.pal_demo_begin(p_group_id uuid,p_user_id uuid,p_step integer,p_generation uuid,p_client_id uuid,p_body text,p_lines jsonb)
returns public.messages language plpgsql security definer set search_path='' as $$
 declare d private.pal_demo_rooms; r private.pal_demo_runs; m public.messages; target uuid; line jsonb; pos integer:=0;
 begin
 if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
 perform 1 from public.groups where id=p_group_id and is_demo and not agent_paused for update;
 if not found or not exists(select 1 from public.group_members where group_id=p_group_id and user_id=p_user_id)
 or exists(select 1 from private.pal_demo_actors where group_id=p_group_id and user_id=p_user_id) then raise exception 'Rehearsal member required' using errcode='42501'; end if;
 select * into d from private.pal_demo_rooms where group_id=p_group_id for update;
 if not found then raise exception 'Registered rehearsal required' using errcode='42501'; end if;
 select * into r from private.pal_demo_runs where group_id=p_group_id and user_id=p_user_id and client_id=p_client_id;
 if found then
 if r.step<>p_step or r.body<>btrim(p_body) then raise exception 'Retry must preserve the scene' using errcode='22023'; end if;
 select * into m from public.messages where id=r.message_id; return m;
 end if;
 if d.generation<>p_generation or d.next_step<>p_step or p_step not between 0 and 5 or d.starts_at<=now() then raise exception 'Refresh the current scene or restart rehearsal' using errcode='22023'; end if;
 if private.pal_demo_state(p_group_id)->>'status'<>'ready' or exists(select 1 from public.agent_jobs where group_id=p_group_id and (status='queued' or (status='running' and lease_until>now()))) then raise exception 'Wait for this conversation to finish' using errcode='22023'; end if;
 if length(btrim(p_body)) not between 1 and 4000 or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)>4 then raise exception 'Bounded scene required' using errcode='22023'; end if;
 for line in select value from jsonb_array_elements(p_lines) loop
 if not exists(select 1 from private.pal_demo_actors a join public.group_members m using(group_id,user_id) where a.group_id=p_group_id and a.user_id=(line->>'user_id')::uuid)
 or jsonb_typeof(line->'body') is distinct from 'string' or length(btrim(line->>'body')) not between 1 and 1000 then raise exception 'Registered cast only' using errcode='42501'; end if;
 end loop;
 -- Reuse actual sending/ingestion, under the already verified human's identity in this transaction.
 perform set_config('request.jwt.claim.sub',p_user_id::text,true);
 m:=private.send_message(p_group_id,p_body,p_client_id,null);
 if p_step=3 then
 select id into target from public.plans where group_id=p_group_id and status='draft' and starts_at=d.starts_at and place_id in(select id from public.places where group_id=p_group_id and name ilike '%delfina%') order by created_at desc limit 1;
 if target is null then raise exception 'Ask Pal to finish the draft before changing its time' using errcode='22023'; end if;
 perform private.pal_action(p_group_id,'plan.update',jsonb_build_object('id',target,'starts_at',d.starts_at+interval '30 minutes','ends_at',d.starts_at+interval '150 minutes','source_key','demo:move:'||p_client_id));
 end if;
 r.id:=gen_random_uuid();
 insert into private.pal_demo_runs(id,group_id,user_id,client_id,step,body,message_id) values(r.id,p_group_id,p_user_id,p_client_id,p_step,btrim(p_body),m.id);
 for line in select value from jsonb_array_elements(p_lines) loop
 insert into private.pal_demo_lines(run_id,position,user_id,body,due_at) values(r.id,pos,(line->>'user_id')::uuid,btrim(line->>'body'),clock_timestamp()+pos*interval '1 second'); pos:=pos+1;
 end loop;
 update private.pal_demo_rooms set next_step=next_step+1,active_run=r.id where group_id=p_group_id;
 return m;
 end $$;
revoke all on function public.pal_demo_begin(uuid,uuid,integer,uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.pal_demo_begin(uuid,uuid,integer,uuid,uuid,text,jsonb) to service_role;
create function public.pal_demo_tick(p_group_id uuid default null) returns integer language plpgsql security definer set search_path='' as $$
 declare d private.pal_demo_rooms; l private.pal_demo_lines; m public.messages; total integer:=0; r private.pal_demo_runs;
 begin
 if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
 for d in select * from private.pal_demo_rooms where (p_group_id is null or group_id=p_group_id) and active_run is not null order by group_id loop
 perform 1 from public.groups where id=d.group_id and is_demo and not agent_paused for update skip locked;
 if not found then continue; end if;
 select * into r from private.pal_demo_runs where id=d.active_run;
 if not found then continue; end if;
 if not exists(select 1 from public.group_members where group_id=d.group_id and user_id=r.user_id) then
 delete from private.pal_demo_lines where run_id=r.id; update public.agent_jobs set status='cancelled',lease_until=null where group_id=d.group_id and status in ('queued','running'); continue;
 end if;
 select * into l from private.pal_demo_lines where run_id=r.id and emitted_at is null order by position limit 1 for update;
 if not found or l.due_at>clock_timestamp() then continue; end if;
 if not exists(select 1 from private.pal_demo_actors a join public.group_members m using(group_id,user_id) where a.group_id=d.group_id and a.user_id=l.user_id) then raise exception 'Rehearsal actor no longer present' using errcode='42501'; end if;
 insert into public.messages(group_id,sender_id,role,body,source_key) values(d.group_id,l.user_id,'user',l.body,'demo:run:'||r.id||':'||l.position) returning * into m;
 insert into public.agent_jobs(group_id,message_id,requester_id,run_after) values(d.group_id,m.id,l.user_id,now());
 update private.pal_demo_lines set emitted_at=clock_timestamp() where run_id=l.run_id and position=l.position;
 total:=total+1;
 if not exists(select 1 from private.pal_demo_lines where run_id=r.id and emitted_at is null) then
 update public.agent_jobs set run_after=now() where group_id=d.group_id and status='queued';
 end if;
 end loop;
 return total;
 end $$;
revoke all on function public.pal_demo_tick(uuid) from public,anon,authenticated;
grant execute on function public.pal_demo_tick(uuid) to service_role;
create function public.pal_demo_reset(p_group_id uuid,p_user_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
 declare d private.pal_demo_rooms; tz text; today date; days integer;
 begin
 if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
 select timezone into tz from public.groups where id=p_group_id and is_demo for update;
 if not found or not exists(select 1 from public.group_members where group_id=p_group_id and user_id=p_user_id)
 or exists(select 1 from private.pal_demo_actors where group_id=p_group_id and user_id=p_user_id) then raise exception 'Rehearsal member required' using errcode='42501'; end if;
 select * into d from private.pal_demo_rooms where group_id=p_group_id for update;
 if not found then raise exception 'Registered rehearsal required' using errcode='42501'; end if;
 if exists(select 1 from private.google_sync_items s join public.plans p on p.id=s.plan_id where p.group_id=p_group_id and s.event_id is not null) then raise exception 'Rehearsal has a calendar copy; remove it before reset' using errcode='22023'; end if;
 update public.agent_jobs set status='cancelled',lease_until=null where group_id=p_group_id and status in ('queued','running');
 delete from public.reminders where group_id=p_group_id;
 delete from public.plans where group_id=p_group_id;
 delete from public.polls where group_id=p_group_id;
 delete from public.member_memories where group_id=p_group_id;
 delete from private.push_outbox where group_id=p_group_id;
 delete from public.sources where group_id=p_group_id and (source_message_id is null or source_message_id not in(select id from public.messages where group_id=p_group_id and source_key like 'demo:seed:%'));
 delete from public.places where group_id=p_group_id and not(id=any(d.base_place_ids));
 delete from public.messages where group_id=p_group_id and (source_key is null or source_key not like 'demo:seed:%');
 delete from private.pal_demo_runs where group_id=p_group_id;
 today:=(now() at time zone tz)::date; days:=(5-extract(isodow from today)::integer+7)%7; if days=0 then days:=7; end if;
 update private.pal_demo_rooms set next_step=0,active_run=null,generation=gen_random_uuid(),starts_at=(today+days+time '19:30') at time zone tz where group_id=p_group_id;
 return private.pal_demo_state(p_group_id);
 end $$;
revoke all on function public.pal_demo_reset(uuid,uuid) from public,anon,authenticated;
grant execute on function public.pal_demo_reset(uuid,uuid) to service_role;

create function public.pal_demo_cast(p_group_id uuid,p_user_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
 begin
 if current_setting('role',true)<>'service_role' or not exists(select 1 from private.pal_demo_rooms d join public.groups g on g.id=d.group_id and g.is_demo join public.group_members m on m.group_id=g.id where d.group_id=p_group_id and m.user_id=p_user_id) then raise exception 'Rehearsal member required' using errcode='42501'; end if;
 return (select jsonb_agg(user_id order by position) from private.pal_demo_actors where group_id=p_group_id);
 end $$;
revoke all on function public.pal_demo_cast(uuid,uuid) from public,anon,authenticated;
grant execute on function public.pal_demo_cast(uuid,uuid) to service_role;
create function public.pal_demo_register(p_group_id uuid,p_actor_ids uuid[],p_place_ids uuid[]) returns void
language plpgsql security definer set search_path='' as $$
 declare actor uuid; pos integer:=0;
 begin
 if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
 perform 1 from public.groups where id=p_group_id and is_demo and not is_direct for update;
 if not found or cardinality(p_actor_ids)<>3 or (select count(distinct v) from unnest(p_actor_ids) v)<>3 then raise exception 'Three registered actors in a rehearsal group required' using errcode='22023'; end if;
 if exists(select 1 from unnest(p_actor_ids) candidate where not exists(select 1 from public.group_members where group_id=p_group_id and user_id=candidate))
 or exists(select 1 from unnest(p_place_ids) candidate where not exists(select 1 from public.places where group_id=p_group_id and id=candidate)) then raise exception 'Same-group cast and places required' using errcode='42501'; end if;
 insert into private.pal_demo_rooms(group_id,starts_at,base_place_ids) values(p_group_id,now()+interval '7 days',p_place_ids);
 foreach actor in array p_actor_ids loop
 insert into private.pal_demo_actors(group_id,user_id,position) values(p_group_id,actor,pos); pos:=pos+1;
 end loop;
 end $$;
revoke all on function public.pal_demo_register(uuid,uuid[],uuid[]) from public,anon,authenticated;
grant execute on function public.pal_demo_register(uuid,uuid[],uuid[]) to service_role;
-- Private catch-up distinguishes rehearsal plans from real group plans.
do $$ declare definition text:=pg_get_functiondef('private.pal_read_across_groups(uuid,integer,integer,text)'::regprocedure);
 needle text:=$n$'id',r.id,'name',r.name,'timezone',r.timezone,$n$;
 begin
 if position(needle in definition)=0 then raise exception 'Expected current cross-group read shape'; end if;
 execute replace(definition,needle,$n$'id',r.id,'name',r.name,'timezone',r.timezone,'is_demo',(select is_demo from public.groups where id=r.id),$n$);
 end $$;
