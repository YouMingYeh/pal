-- Dedicated test database only. Conversational votes and RSVP fixtures roll back.
begin;
insert into auth.users(id,email) values
 ('50000000-0000-4000-8000-000000000001','pal-response-a@example.invalid'),
 ('50000000-0000-4000-8000-000000000002','pal-response-b@example.invalid'),
 ('50000000-0000-4000-8000-000000000003','pal-response-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','50000000-0000-4000-8000-000000000001',true);
select set_config('pal.response.group',(public.create_group('Response group')).id::text,true);
select set_config('pal.response.invite',(select invite_code::text from public.groups where id=current_setting('pal.response.group')::uuid),true);
select set_config('pal.response.poll',(public.pal_action(current_setting('pal.response.group')::uuid,'poll.create',jsonb_build_object('kind','time','question','Which time?','options',jsonb_build_array(jsonb_build_object('id','fri','label','Friday','starts_at',now()+interval '2 days'),jsonb_build_object('id','sat','label','Saturday','starts_at',now()+interval '3 days')),'deadline_at',now()+interval '1 hour')))->>'id',true);
select set_config('pal.response.place_poll',(public.pal_action(current_setting('pal.response.group')::uuid,'poll.create',jsonb_build_object('kind','place','question','Which place?','options','[{"id":"cafe","label":"Cafe"},{"id":"park","label":"Park"}]'::jsonb,'deadline_at',now()+interval '1 hour')))->>'id',true);
select set_config('pal.response.plan',(public.pal_action(current_setting('pal.response.group')::uuid,'plan.create',jsonb_build_object('title','Confirmed meetup','starts_at',now()+interval '2 days')))->>'id',true);
select public.pal_action(current_setting('pal.response.group')::uuid,'plan.confirm',jsonb_build_object('id',current_setting('pal.response.plan')));
select set_config('pal.response.friday',(public.send_message(current_setting('pal.response.group')::uuid,'Friday works for me','51000000-0000-4000-8000-000000000001')).id::text,true);
select set_config('pal.response.either',(public.send_message(current_setting('pal.response.group')::uuid,'Either works for me','51000000-0000-4000-8000-000000000002')).id::text,true);
select set_config('pal.response.going',(public.send_message(current_setting('pal.response.group')::uuid,'I am in','51000000-0000-4000-8000-000000000003')).id::text,true);
select set_config('pal.response.maybe',(public.send_message(current_setting('pal.response.group')::uuid,'Maybe after all','51000000-0000-4000-8000-000000000004')).id::text,true);
select set_config('request.jwt.claim.sub','50000000-0000-4000-8000-000000000002',true);
select public.join_group(current_setting('pal.response.invite')::uuid);
select set_config('pal.response.none',(public.send_message(current_setting('pal.response.group')::uuid,'Neither works for me','51000000-0000-4000-8000-000000000005')).id::text,true);
select set_config('request.jwt.claim.sub','50000000-0000-4000-8000-000000000003',true);
select set_config('pal.response.other_group',(public.create_group('Other response group')).id::text,true);
select set_config('pal.response.other_poll',(public.pal_action(current_setting('pal.response.other_group')::uuid,'poll.create',jsonb_build_object('kind','place','question','Another group choice','options','[{"id":"a","label":"A"},{"id":"b","label":"B"}]'::jsonb,'deadline_at',now()+interval '1 hour')))->>'id',true);
select set_config('pal.response.other_source',(public.send_message(current_setting('pal.response.other_group')::uuid,'Friday works for me','51000000-0000-4000-8000-000000000007')).id::text,true);
reset role;
update public.polls set created_at=now()-interval '10 seconds' where group_id=current_setting('pal.response.group')::uuid;
update public.plans set created_at=now()-interval '10 seconds',updated_at=now()-interval '10 seconds' where group_id=current_setting('pal.response.group')::uuid;
update public.messages set created_at=now()-interval '6 seconds' where id=current_setting('pal.response.friday')::uuid;
update public.messages set created_at=now()-interval '5 seconds' where id=current_setting('pal.response.none')::uuid;
update public.messages set created_at=now()-interval '4 seconds' where id=current_setting('pal.response.either')::uuid;
update public.messages set created_at=now()-interval '3 seconds' where id=current_setting('pal.response.going')::uuid;
update public.messages set created_at=now()-interval '2 seconds' where id=current_setting('pal.response.maybe')::uuid;
update public.agent_jobs set run_after=now()-interval '1 second' where group_id=current_setting('pal.response.group')::uuid;
set local role service_role;
select set_config('pal.response.job',(select id::text from public.claim_agent_jobs(20) where group_id=current_setting('pal.response.group')::uuid),true);
create function pg_temp.capture(p_source uuid,p_body text,p_kind text,p_target uuid,p_response jsonb,p_attempt integer default 1) returns jsonb language sql as $$
  select public.pal_capture_member_response(current_setting('pal.response.job')::uuid,p_attempt,p_source,p_body,p_kind,p_target,p_response)
$$;
do $$
declare r jsonb; v_poll uuid:=current_setting('pal.response.poll')::uuid; v_plan uuid:=current_setting('pal.response.plan')::uuid; v integer;
begin
  r:=pg_temp.capture(current_setting('pal.response.friday')::uuid,'Friday works for me','poll',v_poll,'{"kind":"options","option_ids":["fri"]}');
  assert r->>'captured'='true' and r->>'user_id'='50000000-0000-4000-8000-000000000001','Captures the actual source speaker';
  r:=pg_temp.capture(current_setting('pal.response.none')::uuid,'Neither works for me','poll',v_poll,'{"kind":"none","option_ids":[]}');
  assert (select cardinality(option_ids)=0 and source_message_id=current_setting('pal.response.none')::uuid from public.poll_responses where poll_id=v_poll and user_id='50000000-0000-4000-8000-000000000002'),'Different batch speaker can explicitly decline all times';
  r:=pg_temp.capture(current_setting('pal.response.either')::uuid,'Either works for me','poll',v_poll,'{"kind":"either"}');
  assert (select cardinality(option_ids)=2 and source_message_id=current_setting('pal.response.either')::uuid from public.poll_responses where poll_responses.poll_id=v_poll and user_id='50000000-0000-4000-8000-000000000001'),'Newer captured sentence supersedes older captured sentence';
  r:=pg_temp.capture(current_setting('pal.response.either')::uuid,'Either works for me','poll',v_poll,'{"kind":"either"}');
  assert r->>'replayed'='true','Same source retry is idempotent';
  r:=pg_temp.capture(current_setting('pal.response.friday')::uuid,'Friday works for me','poll',v_poll,'{"kind":"options","option_ids":["fri"]}');
  assert r->>'captured'='false' and r->>'reason'='newer_response','Older sentence never rewinds a newer response';
  begin
    perform pg_temp.capture(current_setting('pal.response.friday')::uuid,'Friday','poll',v_poll,'{"kind":"options","option_ids":["fri"]}');
    raise exception 'Expected snippet evidence rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform pg_temp.capture(current_setting('pal.response.none')::uuid,'Neither works for me','poll',current_setting('pal.response.place_poll')::uuid,'{"kind":"none"}');
    raise exception 'Expected empty place response rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform pg_temp.capture(current_setting('pal.response.none')::uuid,'Neither works for me','poll',v_poll,'{"kind":"none","user_id":"50000000-0000-4000-8000-000000000001"}');
    raise exception 'Expected actor injection rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform pg_temp.capture(current_setting('pal.response.none')::uuid,'Neither works for me','poll',v_poll,'{"kind":"none"}',2);
    raise exception 'Expected stale job attempt rejection';
  exception when insufficient_privilege then null;
  end;
  begin
    perform pg_temp.capture(current_setting('pal.response.none')::uuid,'Neither works for me','poll',v_poll,'{"kind":"options","option_ids":["invalid"]}');
    raise exception 'Expected unknown target option rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform pg_temp.capture(current_setting('pal.response.none')::uuid,'Neither works for me','poll',current_setting('pal.response.other_poll')::uuid,'{"kind":"either"}');
    raise exception 'Expected cross-group target rejection';
  exception when insufficient_privilege then null;
  end;
  begin
    perform pg_temp.capture(current_setting('pal.response.other_source')::uuid,'Friday works for me','poll',v_poll,'{"kind":"options","option_ids":["fri"]}');
    raise exception 'Expected cross-group speaker rejection';
  exception when insufficient_privilege then null;
  end;
  select version into v from public.plans where id=v_plan;
  begin
    perform pg_temp.capture(current_setting('pal.response.going')::uuid,'I am in','plan',v_plan,jsonb_build_object('status','going','plan_version',v+1));
    raise exception 'Expected incorrect plan version rejection';
  exception when invalid_parameter_value then null;
  end;
  r:=pg_temp.capture(current_setting('pal.response.going')::uuid,'I am in','plan',v_plan,jsonb_build_object('status','going','plan_version',v));
  assert (select status='going' and source_message_id=current_setting('pal.response.going')::uuid from public.plan_rsvps where plan_rsvps.plan_id=v_plan),'Explicit own conversation accepts an RSVP';
  r:=pg_temp.capture(current_setting('pal.response.maybe')::uuid,'Maybe after all','plan',v_plan,jsonb_build_object('status','maybe','plan_version',v));
  assert (select status='maybe' from public.plan_rsvps where plan_rsvps.plan_id=v_plan),'Newer own sentence updates the RSVP';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','50000000-0000-4000-8000-000000000001',true);
select public.pal_action(current_setting('pal.response.group')::uuid,'poll.vote',jsonb_build_object('id',current_setting('pal.response.poll'),'option_ids','["sat"]'::jsonb));
select public.pal_action(current_setting('pal.response.group')::uuid,'plan.rsvp',jsonb_build_object('id',current_setting('pal.response.plan'),'status','declined'));
select set_config('pal.response.late',(public.send_message(current_setting('pal.response.group')::uuid,'Friday works for me','51000000-0000-4000-8000-000000000006')).id::text,true);
set local role service_role;
do $$
declare r jsonb; v integer;
begin
  assert (select source_message_id is null from public.poll_responses where poll_id=current_setting('pal.response.poll')::uuid and user_id='50000000-0000-4000-8000-000000000001'),'Manual vote clears automatic provenance';
  r:=pg_temp.capture(current_setting('pal.response.either')::uuid,'Either works for me','poll',current_setting('pal.response.poll')::uuid,'{"kind":"either"}');
  assert r->>'reason'='newer_response','Delayed agent preserves a later manual vote';
  select version into v from public.plans where id=current_setting('pal.response.plan')::uuid;
  r:=pg_temp.capture(current_setting('pal.response.maybe')::uuid,'Maybe after all','plan',current_setting('pal.response.plan')::uuid,jsonb_build_object('status','maybe','plan_version',v));
  assert r->>'reason'='newer_response','Delayed agent preserves a later manual RSVP';
  begin
    perform pg_temp.capture(current_setting('pal.response.late')::uuid,'Friday works for me','poll',current_setting('pal.response.poll')::uuid,'{"kind":"options","option_ids":["fri"]}');
    raise exception 'Expected outside frozen batch rejection';
  exception when insufficient_privilege then null;
  end;
  update public.agent_jobs set lease_until=now()-interval '1 second' where id=current_setting('pal.response.job')::uuid;
  begin
    perform pg_temp.capture(current_setting('pal.response.none')::uuid,'Neither works for me','poll',current_setting('pal.response.poll')::uuid,'{"kind":"none"}');
    raise exception 'Expected expired lease rejection';
  exception when insufficient_privilege then null;
  end;
  update public.agent_jobs set lease_until=now()+interval '5 minutes' where id=current_setting('pal.response.job')::uuid;
  update public.plans set version=version+1,updated_at=now() where id=current_setting('pal.response.plan')::uuid;
  begin
    perform pg_temp.capture(current_setting('pal.response.going')::uuid,'I am in','plan',current_setting('pal.response.plan')::uuid,jsonb_build_object('status','going','plan_version',v));
    raise exception 'Expected source preceding plan change rejection';
  exception when invalid_parameter_value then null;
  end;
  assert (select status='declined' from public.plan_rsvps where plan_id=current_setting('pal.response.plan')::uuid),'Stale capture preserves current decision';
  assert not has_function_privilege('authenticated','public.pal_capture_member_response(uuid,integer,uuid,text,text,uuid,jsonb)','execute'),'Clients cannot invoke speaker-capture service';
end $$;
rollback;
