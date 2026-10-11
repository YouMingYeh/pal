-- Dedicated test database only. Mascot messages and job fixtures roll back.
begin;
insert into auth.users(id,email) values
 ('40000000-0000-4000-8000-000000000001','pal-mascot-member@example.invalid'),
 ('40000000-0000-4000-8000-000000000002','pal-mascot-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','40000000-0000-4000-8000-000000000001',true);
select set_config('pal.mascot.group',(public.create_group('Mascot group')).id::text,true);
select public.send_message(current_setting('pal.mascot.group')::uuid,'First task','41000000-0000-4000-8000-000000000001');
select public.send_message(current_setting('pal.mascot.group')::uuid,'Old caller task','41000000-0000-4000-8000-000000000002');
select public.send_message(current_setting('pal.mascot.group')::uuid,'Silent task','41000000-0000-4000-8000-000000000003');
select public.send_message(current_setting('pal.mascot.group')::uuid,'Preserved task','41000000-0000-4000-8000-000000000004');
select set_config('pal.mascot.job',(select j.id::text from public.agent_jobs j join public.messages m on m.id=j.message_id where m.client_id='41000000-0000-4000-8000-000000000001'),true);
set local role service_role;
do $$
declare activity jsonb; j public.agent_jobs; n bigint;
begin
  activity:=public.pal_group_state(current_setting('pal.mascot.group')::uuid)->'pal_activity';
  assert activity->>'activity'='idle','Queued group work does not claim typing before a reply decision';
  assert activity->>'expires_at' is null,'Unchosen group work has no typing timer';
  update public.agent_jobs set status='cancelled' where group_id=current_setting('pal.mascot.group')::uuid and id<>current_setting('pal.mascot.job')::uuid;
  update public.agent_jobs set run_after=now() where id=current_setting('pal.mascot.job')::uuid;
  activity:=public.pal_group_state(current_setting('pal.mascot.group')::uuid)->'pal_activity';
  assert activity->>'activity'='idle','Due group work still awaits an actual reply decision';
  assert activity->>'expires_at' is null,'Queued shared work exposes no typing deadline';
  select * into j from public.claim_agent_jobs(1);
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Running decision work is not typing';
  assert public.pal_begin_reply(j.id,j.attempts),'A current worker may choose to reply';
  activity:=public.pal_group_state(j.group_id)->'pal_activity';
  assert activity->>'activity'='typing' and activity->>'status'='running' and activity->>'job_id'=j.id::text,'Claim preserves stable job ID and exposes real running state';
  assert (activity->>'expires_at')::timestamptz=(select least(lease_until,reply_started_at+interval '20 seconds') from public.agent_jobs where id=j.id),'Typing is capped by its short reply window and actual lease';
  assert not public.complete_agent_job_with_emotion(j.id,j.attempts+1,'Wrong attempt',null,'heureux'),'Stale worker cannot publish';
  begin
    perform public.complete_agent_job_with_emotion(j.id,j.attempts,'Unknown emotion',null,'invented');
    raise exception 'Expected invalid emotion rejection';
  exception when invalid_parameter_value then null;
  end;
  update public.agent_jobs set lease_until=now()-interval '1 second' where id=j.id;
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Expired lease stops thinking';
  assert not public.complete_agent_job_with_emotion(j.id,j.attempts,'Expired response',null,'heureux'),'Expired lease cannot publish';
  update public.agent_jobs set status='queued',lease_until=null,run_after=now()-interval '6 minutes' where id=j.id;
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Old queued failure cannot keep thinking indefinitely';
  update public.agent_jobs set status='queued',attempts=3,run_after=now() where id=j.id;
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Exhausted queued work cannot animate';
  update public.agent_jobs set status='running',attempts=1,lease_until=now()+interval '5 minutes' where id=j.id;
  assert public.complete_agent_job_with_emotion(j.id,1,'Done',null,'heureux'),'Valid live completion succeeds';
  assert (select emotion='heureux' from public.messages where source_key='job:'||j.id),'Pal reply persists the selected expression';
  assert not public.complete_agent_job_with_emotion(j.id,1,'Different reply',null,'confus'),'Completed retry never overwrites a reply';
  assert (select emotion='heureux' and body='Done' from public.messages where source_key='job:'||j.id),'Completed retry preserves original body and emotion';
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Completion clears real activity';
  assert (select count(*)=4 from public.agent_jobs where group_id=j.group_id),'Pal reply does not loop into another job';
  update public.agent_jobs set status='queued',run_after=now() where message_id in(select id from public.messages where client_id='41000000-0000-4000-8000-000000000002');
  select * into j from public.claim_agent_jobs(1);
  assert public.complete_agent_job(j.id,j.attempts,'Legacy response'),'Old three-argument caller remains compatible';
  assert (select emotion='fier' from public.messages where source_key='job:'||j.id),'Old caller defaults to fier';
  update public.agent_jobs set status='queued',run_after=now() where message_id in(select id from public.messages where client_id='41000000-0000-4000-8000-000000000003');
  select * into j from public.claim_agent_jobs(1);
  n:=(select count(*) from public.messages where group_id=j.group_id);
  assert public.complete_agent_job_with_emotion(j.id,j.attempts,'',null,'confus'),'Silent passive completion remains valid';
  assert (select count(*)=n from public.messages where group_id=j.group_id),'Silent completion invents no message or emotion';
  update public.agent_jobs set status='queued',run_after=now() where message_id in(select id from public.messages where client_id='41000000-0000-4000-8000-000000000004');
  select * into j from public.claim_agent_jobs(1);
  insert into public.messages(group_id,role,body,source_key,emotion) values(j.group_id,'pal','Original reply','job:'||j.id,'curieux');
  assert public.complete_agent_job_with_emotion(j.id,j.attempts,'Replayed reply',null,'triste'),'Existing unique job source may finish safely';
  assert (select body='Original reply' and emotion='curieux' from public.messages where source_key='job:'||j.id),'Unique source retains its first emotion';
  begin
    insert into public.messages(group_id,sender_id,role,body,emotion) values(j.group_id,'40000000-0000-4000-8000-000000000001','user','Human mood spoof','fier');
    raise exception 'Expected human emotion rejection';
  exception when check_violation then null;
  end;
  assert not has_function_privilege('authenticated','public.complete_agent_job_with_emotion(uuid,integer,text,text,text)','execute'),'Client cannot impersonate mascot completion';
end $$;
do $$
declare source_id uuid; job_id uuid; g uuid:=current_setting('pal.mascot.group')::uuid;
begin
  insert into public.messages(group_id,role,body,source_key) values(g,'system','Internal weekly trigger','weekly:mascot-test') returning id into source_id;
  insert into public.agent_jobs(group_id,message_id,requester_id,job_kind,status,attempts,lease_until)
    values(g,source_id,'40000000-0000-4000-8000-000000000001','weekly','running',1,now()+interval '5 minutes');
  assert public.pal_group_state(g)->'pal_activity'->>'activity'='idle','Quiet weekly work never shows chat thinking';
  insert into public.messages(group_id,sender_id,role,body) values(g,'40000000-0000-4000-8000-000000000001','user','Paused task') returning id into source_id;
  insert into public.agent_jobs(group_id,message_id,requester_id,status,attempts,lease_until)
    values(g,source_id,'40000000-0000-4000-8000-000000000001','running',1,now()+interval '5 minutes') returning id into job_id;
  update public.groups set agent_paused=true where id=g;
  assert public.pal_group_state(g)->'pal_activity'->>'activity'='idle','Paused groups never animate queued or running work';
  assert not public.complete_agent_job_with_emotion(job_id,1,'Paused reply'),'Pause prevents completion publication';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','40000000-0000-4000-8000-000000000002',true);
do $$
begin
  begin
    perform public.pal_group_state(current_setting('pal.mascot.group')::uuid);
    raise exception 'Expected nonmember activity denial';
  exception when insufficient_privilege then null;
  end;
end $$;
rollback;
