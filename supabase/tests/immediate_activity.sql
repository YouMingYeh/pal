-- Dedicated test database only. Shared queue work stays quiet until reply intent; fixtures roll back.
begin;
insert into auth.users(id,email) values
 ('70000000-0000-4000-8000-000000000001','pal-immediate-member@example.invalid'),
 ('70000000-0000-4000-8000-000000000002','pal-immediate-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','70000000-0000-4000-8000-000000000001',true);
select set_config('pal.immediate.group',(public.create_group('Immediate activity')).id::text,true);
select public.send_message(current_setting('pal.immediate.group')::uuid,'Just chatting without a mention',gen_random_uuid());
do $$
declare a jsonb;
begin
  a:=public.pal_group_state(current_setting('pal.immediate.group')::uuid)->'pal_activity';
  assert a->>'activity'='idle','A shared human message does not immediately claim typing';
  assert a->>'expires_at' is null,'Queued shared work has no typing deadline';
  assert (select run_after=now()+interval '3 seconds' and not explicit_mention from public.agent_jobs where group_id=current_setting('pal.immediate.group')::uuid),'Quiet observation preserves the short group-burst debounce';
end $$;
set local role service_role;
do $$
declare j public.agent_jobs; a jsonb; n bigint;
begin
  select * into j from public.agent_jobs where group_id=current_setting('pal.immediate.group')::uuid;
  update public.agent_jobs set run_after=now()+interval '1 day' where id=j.id;
  a:=public.pal_group_state(j.group_id)->'pal_activity';
  assert a->>'activity'='idle','Distant shared queues do not animate';
  update public.agent_jobs set created_at=now()-interval '6 minutes' where id=j.id;
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Old future queues expire despite distant run_after';
  update public.agent_jobs set created_at=now(),run_after=now() where id=j.id;
  a:=public.pal_group_state(j.group_id)->'pal_activity';
  assert a->>'activity'='idle','Due shared queues wait for the reply decision';
  update public.groups set agent_paused=true where id=j.group_id;
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Paused accepted work stays idle';
  update public.groups set agent_paused=false where id=j.group_id;
  select * into j from public.claim_agent_jobs(1);
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','A real worker may read the group without typing';
  n:=(select count(*) from public.messages where group_id=j.group_id);
  assert public.complete_agent_job(j.id,j.attempts,''),'Selective agent may complete silently';
  assert (select count(*)=n from public.messages where group_id=j.group_id),'Immediate animation does not force a Pal reply';
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Silent completion immediately stops animation';
  assert (select count(*)=1 from public.agent_jobs where group_id=j.group_id),'Activity does not enqueue any self-loop';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','70000000-0000-4000-8000-000000000002',true);
do $$
begin
  begin
    perform public.pal_group_state(current_setting('pal.immediate.group')::uuid);
    raise exception 'Expected activity privacy denial';
  exception when insufficient_privilege then null;
  end;
end $$;
rollback;
