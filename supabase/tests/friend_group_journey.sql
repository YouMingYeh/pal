-- Dedicated empty test database only. This exercises persisted behavior, not model/provider quality.
begin;
insert into auth.users(id,email) values
 ('de010000-0000-4000-8000-000000000001','journey-amy@example.invalid'),
 ('de010000-0000-4000-8000-000000000002','journey-ben@example.invalid'),
 ('de010000-0000-4000-8000-000000000003','journey-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','de010000-0000-4000-8000-000000000001',true);
select public.pal_profile_save('{"display_name":"Amy"}');
select set_config('journey.group',(public.create_group('Dinner with friends')).id::text,true);
select set_config('journey.invite',(select invite_code::text from public.groups where id=current_setting('journey.group')::uuid),true);
select set_config('journey.dm',(public.ensure_pal_direct()).id::text,true);
select set_config('journey.private',(public.send_message(current_setting('journey.dm')::uuid,'I am overwhelmed. Keep this between us.',gen_random_uuid())).id::text,true);
select set_config('request.jwt.claim.sub','de010000-0000-4000-8000-000000000002',true);
select public.join_group(current_setting('journey.invite')::uuid);
select public.pal_profile_save('{"display_name":"Ben"}');
select set_config('journey.ben',(public.send_message(current_setting('journey.group')::uuid,'Under forty before drinks. I can do after seven.',gen_random_uuid())).id::text,true);
select set_config('request.jwt.claim.sub','de010000-0000-4000-8000-000000000001',true);
select set_config('journey.amy',(public.send_message(current_setting('journey.group')::uuid,'Dinner? Vegetarian options for me, please.',gen_random_uuid())).id::text,true);
reset role;
-- Freeze the real burst; scripted output here only replaces model text generation.
update public.agent_jobs set run_after=now()-interval '1 second' where group_id=current_setting('journey.group')::uuid;
set local role service_role;
select set_config('journey.job',(select id::text from public.claim_agent_jobs(20) where group_id=current_setting('journey.group')::uuid),true);
select public.pal_agent_action(current_setting('journey.group')::uuid,'de010000-0000-4000-8000-000000000001','memory.save',
 jsonb_build_object('kind','preference','key','diet','value','Vegetarian','source_message_id',current_setting('journey.amy'),'job_id',current_setting('journey.job'),'source_key','journey:diet'));
select public.pal_agent_action(current_setting('journey.group')::uuid,'de010000-0000-4000-8000-000000000002','memory.save',
 jsonb_build_object('kind','preference','key','budget','value','Under forty before drinks','source_message_id',current_setting('journey.ben'),'job_id',current_setting('journey.job'),'source_key','journey:budget'));
select set_config('journey.place',(public.pal_agent_action(current_setting('journey.group')::uuid,'de010000-0000-4000-8000-000000000001','place.save',
 jsonb_build_object('name','Cafe fixture','address','1 Test Street','latitude',37.77,'longitude',-122.42,'provider','apple','provider_id','journey:fixture','job_id',current_setting('journey.job'),'source_key','journey:place')))->>'id',true);
do $$ declare gid uuid:=current_setting('journey.group')::uuid; job uuid:=current_setting('journey.job')::uuid; begin
 assert (select cardinality(batch_message_ids)=2 from public.agent_jobs where id=job),'Human burst is processed together without requiring a tag';
 assert public.pal_group_state(gid)->'pal_activity'->>'activity'='idle','Reading and deciding do not display typing';
 assert public.pal_begin_reply(job,1),'Typing begins only after a reply is selected';
 assert public.pal_group_state(gid)->'pal_activity'->>'activity'='typing','A current reply marker is visible';
 assert public.complete_agent_job_with_outputs(job,1,jsonb_build_array(
   jsonb_build_object('body','An actual dinner? Historic.','emotion','hilare','reply_to_id',current_setting('journey.amy')),
   jsonb_build_object('body','Seven thirty or eight?','emotion','curieux','card',jsonb_build_object('type','question','entity_id',gid,'question','Seven thirty or eight?','suggestions','["7:30","8:00"]'::jsonb)))),
   'Short separate replies and a suggested-answer question publish atomically';
 assert public.pal_group_state(gid)->'pal_activity'->>'activity'='idle','Completion clears typing';
 assert not public.complete_agent_job_with_outputs(job,1,'[{"body":"Duplicate"}]'),'Retry adds no extra message';
 assert (select count(*)=2 from public.agent_jobs where group_id=gid),'Pal messages never trigger response loops';
 assert (select count(*)=2 from public.member_memories where group_id=gid),'Diet and budget retain their own speakers';
end $$;
select set_config('journey.question',(select id::text from public.messages where group_id=current_setting('journey.group')::uuid and card->>'type'='question'),true);
set local role authenticated;
select set_config('request.jwt.claim.sub','de010000-0000-4000-8000-000000000002',true);
select public.send_message(current_setting('journey.group')::uuid,'8:00',gen_random_uuid(),current_setting('journey.question')::uuid);
do $$ begin
 assert not exists(select 1 from public.plan_rsvps where group_id=current_setting('journey.group')::uuid),'Choosing a time is not agreeing to attend';
 begin perform public.pal_group_state(current_setting('journey.dm')::uuid); raise exception 'DM was exposed'; exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub','de010000-0000-4000-8000-000000000001',true);
select set_config('journey.plan',(public.pal_action(current_setting('journey.group')::uuid,'plan.create',
 jsonb_build_object('title','Friday dinner','place_id',current_setting('journey.place'),'starts_at',now()+interval '3 days','ends_at',now()+interval '3 days 1 hour','source_key','journey:draft')))->>'id',true);
do $$ begin
 assert not exists(select 1 from public.reminders where plan_id=current_setting('journey.plan')::uuid),'Drafts do not schedule attendance reminders';
end $$;
select public.pal_action(current_setting('journey.group')::uuid,'plan.confirm',jsonb_build_object('id',current_setting('journey.plan'),'source_key','journey:confirm'));
select public.pal_action(current_setting('journey.group')::uuid,'plan.confirm',jsonb_build_object('id',current_setting('journey.plan'),'source_key','journey:confirm'));
select public.pal_action(current_setting('journey.group')::uuid,'plan.rsvp',jsonb_build_object('id',current_setting('journey.plan'),'status','going'));
do $$ declare pid uuid:=current_setting('journey.plan')::uuid; begin
 assert (select count(*)=1 from public.messages where source_key like 'plan-rsvp:'||pid||':%'),'Confirmation retry posts one invitation';
 assert (select jsonb_array_length(mentions)=2 from public.messages where source_key like 'plan-rsvp:'||pid||':%'),'Invitation tags both current members';
 assert (select count(*)=1 from public.plan_rsvps where plan_id=pid),'Ben remains unanswered until he responds';
 assert (select booking_status='needed' from public.plans where id=pid),'Confirming a plan never invents a booking';
 assert (select count(*)=2 from public.reminders where plan_id=pid and status='scheduled'),'Confirmed plan schedules its future reminders';
end $$;
select set_config('request.jwt.claim.sub','de010000-0000-4000-8000-000000000002',true);
select public.pal_action(current_setting('journey.group')::uuid,'plan.rsvp',jsonb_build_object('id',current_setting('journey.plan'),'status','maybe'));
select set_config('request.jwt.claim.sub','de010000-0000-4000-8000-000000000001',true);
select public.pal_action(current_setting('journey.group')::uuid,'plan.update',jsonb_build_object('id',current_setting('journey.plan'),'starts_at',now()+interval '3 days 30 minutes','ends_at',now()+interval '3 days 90 minutes','source_key','journey:late'));
select public.pal_action(current_setting('journey.group')::uuid,'plan.update',jsonb_build_object('id',current_setting('journey.plan'),'starts_at',now()+interval '3 days 30 minutes','ends_at',now()+interval '3 days 90 minutes','source_key','journey:late'));
do $$ declare pid uuid:=current_setting('journey.plan')::uuid; begin
 assert not exists(select 1 from public.plan_rsvps where plan_id=pid),'Moving dinner requires renewed RSVPs from both members';
 assert (select count(*)=2 from public.messages where source_key like 'plan-rsvp:'||pid||':%'),'Changed plan invites once, despite transport retry';
 assert (select count(*)=2 from public.reminders where plan_id=pid and status='cancelled'),'Old times cannot deliver obsolete reminders';
 assert (select count(*)=2 from public.reminders where plan_id=pid and status='scheduled'),'Only the replacement pair remains active';
end $$;
select public.pal_action(current_setting('journey.group')::uuid,'plan.rsvp',jsonb_build_object('id',current_setting('journey.plan'),'status','going'));
select set_config('journey.reminder',(public.pal_action(current_setting('journey.group')::uuid,'reminder.create',
 jsonb_build_object('body','Bring yourselves and an appetite.','due_at',now()+interval '1 minute','timezone','America/Los_Angeles','target_user_ids',jsonb_build_array(auth.uid()),'source_key','journey:reminder')))->>'id',true);
reset role;
update public.reminders set due_at=now()-interval '1 second' where id=current_setting('journey.reminder')::uuid;
set local role service_role;
select public.pal_maintenance();
select public.pal_maintenance();
do $$ declare rid uuid:=current_setting('journey.reminder')::uuid; begin
 assert (select count(*)=1 from public.messages where source_key like 'reminder:'||rid||':%'),'Offline delivery persists exactly once';
 assert (select count(*)=1 from private.push_outbox where payload->>'reminder_id'=rid::text),'Repeated delivery queues one push for the chosen recipient';
end $$;
set local role authenticated;
select public.pal_action(current_setting('journey.group')::uuid,'plan.cancel',jsonb_build_object('id',current_setting('journey.plan')));
do $$ begin
 assert not exists(select 1 from public.reminders where plan_id=current_setting('journey.plan')::uuid and status='scheduled'),'Cancelling dinner cancels future attendance reminders';
end $$;
select set_config('request.jwt.claim.sub','de010000-0000-4000-8000-000000000003',true);
do $$ begin
 assert not exists(select 1 from public.messages where group_id=current_setting('journey.group')::uuid),'Outsiders cannot read the story';
 begin perform public.pal_action(current_setting('journey.group')::uuid,'plan.rsvp',jsonb_build_object('id',current_setting('journey.plan'),'status','going')); raise exception 'Outsider RSVP was accepted'; exception when insufficient_privilege then null; end;
end $$;
rollback;
