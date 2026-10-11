-- Dedicated test database only. Earlier source collection and board provenance roll back.
begin;
insert into auth.users(id,email) values
 ('a0000000-0000-4000-8000-000000000001','pal-collected-owner@example.invalid'),
 ('a0000000-0000-4000-8000-000000000002','pal-collected-member@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
select set_config('pal.collect.group',(public.create_group('Collected availability')).id::text,true);
select set_config('pal.collect.invite',(select invite_code::text from public.groups where id=current_setting('pal.collect.group')::uuid),true);
select set_config('pal.collect.source',(public.send_message(current_setting('pal.collect.group')::uuid,'@Pal Friday works for me',gen_random_uuid())).id::text,true);
select set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
select public.join_group(current_setting('pal.collect.invite')::uuid);
select set_config('pal.collect.other_source',(public.send_message(current_setting('pal.collect.group')::uuid,'Saturday works for me',gen_random_uuid())).id::text,true);
reset role;
update public.messages set created_at=now()-interval '5 seconds' where id in(current_setting('pal.collect.source')::uuid,current_setting('pal.collect.other_source')::uuid);
update public.agent_jobs set run_after=now() where group_id=current_setting('pal.collect.group')::uuid;
set local role service_role;
select set_config('pal.collect.job',(select id::text from public.claim_agent_jobs(20) where group_id=current_setting('pal.collect.group')::uuid),true);
create function pg_temp.collect_board(p_kind text,p_presentation text,p_suffix text,p_job uuid default null) returns jsonb language sql as $$
  select public.pal_agent_action(current_setting('pal.collect.group')::uuid,'a0000000-0000-4000-8000-000000000001','poll.create',
    jsonb_build_object('kind',p_kind,'question','Our board','presentation',p_presentation,'options',case when p_kind='time' then
      jsonb_build_array(jsonb_build_object('id','fri','label','Friday','starts_at',now()+interval '2 days'),jsonb_build_object('id','sat','label','Saturday','starts_at',now()+interval '3 days'))
      else '[{"id":"walk","label":"Walk"},{"id":"museum","label":"Museum"}]'::jsonb end,
      'deadline_at',now()+interval '1 day','job_id',coalesce(p_job,current_setting('pal.collect.job')::uuid),'source_key','job:'||coalesce(p_job,current_setting('pal.collect.job')::uuid)||':poll.create:'||p_suffix))
$$;
select set_config('pal.collect.board',(pg_temp.collect_board('time','availability','current'))->>'id',true);
select set_config('pal.collect.place',(pg_temp.collect_board('place','options','place'))->>'id',true);
create function pg_temp.collect_capture(p_target uuid,p_response jsonb,p_source uuid default null,p_body text default '@Pal Friday works for me') returns jsonb language sql as $$
  select public.pal_capture_member_response(current_setting('pal.collect.job')::uuid,1,coalesce(p_source,current_setting('pal.collect.source')::uuid),p_body,'poll',p_target,p_response)
$$;
create function pg_temp.reject_collect(p_target uuid,p_response jsonb) returns void language plpgsql as $$
begin
  begin perform pg_temp.collect_capture(p_target,p_response);
  exception when invalid_parameter_value then return; end;
  raise exception 'Expected collected response chronology rejection';
end $$;
do $$
declare r jsonb; board uuid:=current_setting('pal.collect.board')::uuid;
begin
  assert (select is_agent and input->>'job_id'=current_setting('pal.collect.job') from private.action_receipts where result->>'id'=board::text),'Board source proof is trusted agent receipt provenance';
  assert not exists(select 1 from public.reminders where poll_id in(board,current_setting('pal.collect.place')::uuid)),'Rich availability/options boards create no legacy automatic nudges';
  perform pg_temp.reject_collect(board,'{"kind":"either"}');
  perform pg_temp.reject_collect(board,'{"kind":"none"}');
  perform pg_temp.reject_collect(current_setting('pal.collect.place')::uuid,'{"kind":"options","option_ids":["walk"]}');
  r:=pg_temp.collect_capture(board,'{"kind":"options","option_ids":["fri"]}');
  assert r->>'captured'='true' and r->>'user_id'='a0000000-0000-4000-8000-000000000001','Same-job board collects the actual earlier source speaker';
  r:=pg_temp.collect_capture(board,'{"kind":"options","option_ids":["sat"]}',current_setting('pal.collect.other_source')::uuid,'Saturday works for me');
  assert r->>'captured'='true' and r->>'user_id'='a0000000-0000-4000-8000-000000000002','Frozen batch can collect each actual speaker without impersonation';
  assert (select count(*)=2 from public.poll_responses where poll_id=board),'Only stated own schedules become responses';
  update public.poll_responses set option_ids=array['sat'],updated_at=now() where poll_id=board and user_id='a0000000-0000-4000-8000-000000000001';
  r:=pg_temp.collect_capture(board,'{"kind":"options","option_ids":["fri"]}');
  assert r->>'reason'='newer_response' and (select option_ids=array['sat'] from public.poll_responses where poll_id=board and user_id='a0000000-0000-4000-8000-000000000001'),'Earlier collection never rewinds a newer manual response';
  begin perform pg_temp.collect_board('place','availability','mismatch'); raise exception 'Expected mismatched rich presentation';
  exception when invalid_parameter_value then null; end;
end $$;
-- A human can supply a job-looking key, but cannot create trusted agent provenance.
set local role authenticated;
select set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
select set_config('pal.collect.forged',(public.pal_action(current_setting('pal.collect.group')::uuid,'poll.create',jsonb_build_object('kind','time','question','Human board','options',jsonb_build_array(jsonb_build_object('id','fri','label','Friday','starts_at',now()+interval '2 days'),jsonb_build_object('id','sat','label','Saturday','starts_at',now()+interval '3 days')),'deadline_at',now()+interval '1 day','job_id',current_setting('pal.collect.job'),'source_key','job:'||current_setting('pal.collect.job')||':poll.create:human')))->>'id',true);
set local role service_role;
do $$
declare board uuid:=current_setting('pal.collect.forged')::uuid; other_job uuid; source_id uuid; other_board uuid;
begin
  assert (select not is_agent from private.action_receipts where result->>'id'=board::text),'Human source-key spoof cannot forge agent provenance';
  assert (select count(*)=2 from public.reminders where poll_id=board),'Legacy human polls preserve halfway and deadline nudges';
  perform pg_temp.reject_collect(board,'{"kind":"options","option_ids":["fri"]}');
  insert into public.messages(group_id,sender_id,role,body) values(current_setting('pal.collect.group')::uuid,'a0000000-0000-4000-8000-000000000001','user','Other task') returning id into source_id;
  insert into public.agent_jobs(group_id,message_id,requester_id,status,attempts,lease_until,batch_message_ids)
    values(current_setting('pal.collect.group')::uuid,source_id,'a0000000-0000-4000-8000-000000000001','running',1,now()+interval '5 minutes',array[source_id]) returning id into other_job;
  other_board:=(pg_temp.collect_board('time','availability','other',other_job)->>'id')::uuid;
  perform pg_temp.reject_collect(other_board,'{"kind":"options","option_ids":["fri"]}');
  update public.polls set status='closed' where id=current_setting('pal.collect.board')::uuid;
  perform pg_temp.reject_collect(current_setting('pal.collect.board')::uuid,'{"kind":"options","option_ids":["fri"]}');
end $$;
rollback;
