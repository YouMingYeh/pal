-- Dedicated test database only. Question chips are suggested chat text, never votes.
begin;
insert into auth.users(id,email) values
 ('b3000000-0000-4000-8000-000000000001','pal-question-owner@example.invalid'),
 ('b3000000-0000-4000-8000-000000000002','pal-question-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','b3000000-0000-4000-8000-000000000001',true);
select set_config('pal.question.group',(public.create_group('Dinner questions')).id::text,true);
select public.send_message(current_setting('pal.question.group')::uuid,'What should we do Friday?',gen_random_uuid());
select set_config('request.jwt.claim.sub','b3000000-0000-4000-8000-000000000002',true);
select set_config('pal.question.other',(public.create_group('Other questions')).id::text,true);
reset role;
update public.agent_jobs set run_after=now()-interval '1 second' where group_id=current_setting('pal.question.group')::uuid;
set local role service_role;
select set_config('pal.question.job',(select id::text from public.claim_agent_jobs(20) where group_id=current_setting('pal.question.group')::uuid),true);
create function pg_temp.question_output(p_card jsonb,p_attempt integer default 1) returns boolean language sql as $$
  select public.complete_agent_job_with_outputs(current_setting('pal.question.job')::uuid,p_attempt,
    jsonb_build_array(jsonb_build_object('body','Dinner or coffee?','emotion','curieux','card',p_card)))
$$;
create function pg_temp.reject_question(p_card jsonb,p_code text default '22023') returns void language plpgsql as $$
begin
  begin perform pg_temp.question_output(p_card);
  exception when others then if sqlstate=p_code then return; end if; raise;
  end;
  raise exception 'Expected invalid question card %',p_code;
end $$;
do $$
declare gid uuid:=current_setting('pal.question.group')::uuid; j uuid:=current_setting('pal.question.job')::uuid;
  card jsonb:=jsonb_build_object('type','question','entity_id',gid,'question',' Dinner or coffee? ','suggestions','[" Dinner ","Coffee"]'::jsonb);
begin
  assert not has_function_privilege('authenticated','public.complete_agent_job_with_outputs(uuid,integer,jsonb,text)','execute'),'Question publishing is service-only';
  perform pg_temp.reject_question(card||jsonb_build_object('entity_id',current_setting('pal.question.other')),'42501');
  perform pg_temp.reject_question(card||'{"user_id":"b3000000-0000-4000-8000-000000000002"}'::jsonb);
  perform pg_temp.reject_question(card||'{"question":" "}'::jsonb);
  perform pg_temp.reject_question(card||jsonb_build_object('question',repeat('x',201)));
  perform pg_temp.reject_question(card||'{"suggestions":["Only one"]}'::jsonb);
  perform pg_temp.reject_question(card||'{"suggestions":["One","Two","Three","Four","Five"]}'::jsonb);
  perform pg_temp.reject_question(card||'{"suggestions":["Dinner"," dinner "]}'::jsonb);
  perform pg_temp.reject_question(card||'{"suggestions":["Dinner",""]}'::jsonb);
  perform pg_temp.reject_question(card||jsonb_build_object('suggestions',jsonb_build_array('Dinner',repeat('x',61))));
  perform pg_temp.reject_question(card||'{"suggestions":["Dinner",{"action":"plan.rsvp"}]}'::jsonb);
  perform pg_temp.reject_question(card||'{"suggestions":"Dinner"}'::jsonb);
  update public.agent_jobs set lease_until=now()-interval '1 second' where id=j;
  assert not pg_temp.question_output(card),'An expired lease cannot publish a question';
  update public.agent_jobs set lease_until=now()+interval '5 minutes' where id=j;
  assert not pg_temp.question_output(card,2),'A stale attempt cannot publish a question';
  assert pg_temp.question_output(card),'A valid current question is persisted';
  assert (select count(*)=1 from public.messages where group_id=gid and source_key='job:'||j),'Exactly one message owns the question';
  assert (select msg.card=jsonb_build_object('type','question','entity_id',gid,'question','Dinner or coffee?','suggestions','["Dinner","Coffee"]'::jsonb)
    from public.messages msg where group_id=gid and source_key='job:'||j),'Question and suggestions survive completion and are normalized';
  assert not pg_temp.question_output(card),'Completed-job retry does not create a second question';
  assert not exists(select 1 from public.polls where group_id=gid),'Questions create no hidden polls';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','b3000000-0000-4000-8000-000000000001',true);
select set_config('pal.question.message',(select id::text from public.messages where group_id=current_setting('pal.question.group')::uuid and source_key='job:'||current_setting('pal.question.job')),true);
select public.send_message(current_setting('pal.question.group')::uuid,'Coffee',gen_random_uuid(),current_setting('pal.question.message')::uuid);
select public.send_message(current_setting('pal.question.group')::uuid,'Actually a picnic after seven works better.',gen_random_uuid(),current_setting('pal.question.message')::uuid);
do $$ begin
  assert (select count(*)=2 from public.messages where group_id=current_setting('pal.question.group')::uuid and role='user' and reply_to_id=current_setting('pal.question.message')::uuid),'Suggested and free-text answers both quote the delivered question';
  assert not exists(select 1 from public.poll_responses where group_id=current_setting('pal.question.group')::uuid),'Answers are ordinary chat, not automatic votes';
  assert not exists(select 1 from public.plan_rsvps where group_id=current_setting('pal.question.group')::uuid),'Answers do not directly assign attendance';
end $$;
reset role;
update public.agent_jobs set status='running',lease_until=now()+interval '5 minutes' where id=current_setting('pal.question.job')::uuid;
delete from public.group_members where group_id=current_setting('pal.question.group')::uuid and user_id='b3000000-0000-4000-8000-000000000001';
set local role service_role;
do $$ begin
  assert not pg_temp.question_output(jsonb_build_object('type','question','entity_id',current_setting('pal.question.group'),'question','Dinner or coffee?','suggestions','["Dinner","Coffee"]'::jsonb)),'Removed requesters cannot publish questions';
end $$;
rollback;
