-- Dedicated test database only. Fixtures, side effects, OAuth tokens and jobs roll back.
begin;
insert into auth.users(id,email) values
 ('10000000-0000-4000-8000-000000000001','pal-v1-a@example.invalid'),
 ('10000000-0000-4000-8000-000000000002','pal-v1-b@example.invalid'),
 ('10000000-0000-4000-8000-000000000003','pal-v1-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
select set_config('pal.test.group',(public.create_group('V1 group')).id::text,true);
select set_config('pal.test.invite',(select invite_code::text from public.groups where id=current_setting('pal.test.group')::uuid),true);
select public.pal_profile_save('{"display_name":"Alex","notification_preferences":{"enabled":true}}');
select set_config('pal.test.message',(public.send_message(current_setting('pal.test.group')::uuid,'I prefer vegetarian food','10000000-0000-4000-8000-000000000010')).id::text,true);
select public.pal_action(current_setting('pal.test.group')::uuid,'memory.save','{"kind":"preference","key":"food","value":"vegetarian","source_key":"food"}');
select set_config('pal.test.memory',(select id::text from public.member_memories where key='food'),true);
select set_config('pal.test.place',(public.pal_action(current_setting('pal.test.group')::uuid,'place.save','{"name":"Cafe","address":"1 Main St","latitude":37.77,"longitude":-122.42,"provider":"google","provider_id":"stable-map-id","source_key":"cafe"}'))->>'id',true);
select public.pal_action(current_setting('pal.test.group')::uuid,'place.save','{"name":"Cafe","address":"1 Main St","latitude":37.77,"longitude":-122.42,"provider":"google","provider_id":"stable-map-id","source_key":"cafe"}');
select set_config('pal.test.poll',(public.pal_action(current_setting('pal.test.group')::uuid,'poll.create',jsonb_build_object('kind','place','question','Where should we meet?','options','[{"id":"cafe","label":"Cafe"},{"id":"park","label":"Park"}]'::jsonb,'deadline_at',now()+interval '1 hour','source_key','poll')))->>'id',true);
select set_config('pal.test.plan',(public.pal_action(current_setting('pal.test.group')::uuid,'plan.create',jsonb_build_object('title','Cafe meetup','place_id',current_setting('pal.test.place'),'starts_at',now()+interval '3 days','source_key','plan')))->>'id',true);
select public.pal_action(current_setting('pal.test.group')::uuid,'plan.confirm',jsonb_build_object('id',current_setting('pal.test.plan')));
select public.pal_action(current_setting('pal.test.group')::uuid,'plan.rsvp',jsonb_build_object('id',current_setting('pal.test.plan'),'status','going'));
do $$
begin
  assert (select count(*)=1 from public.places), 'Map identity and action retry deduplicate places';
  assert (select count(*)=1 from public.place_contributors), 'Contributors deduplicate';
  assert (select count(*)=2 from public.reminders where poll_id=current_setting('pal.test.poll')::uuid and status='scheduled'), 'Poll halfway and deadline nudges scheduled';
  assert (select count(*)=2 from public.reminders where plan_id=current_setting('pal.test.plan')::uuid and status='scheduled'), 'Confirmed plan schedules 24h and 2h reminders';
  assert public.pal_group_state(current_setting('pal.test.group')::uuid)->'members'->0->>'display_name'='Alex','State hydrates profile';
end $$;

select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
select public.join_group(current_setting('pal.test.invite')::uuid);
select public.pal_profile_save('{"display_name":"Blair","notifications_enabled":true}');
select public.pal_action(current_setting('pal.test.group')::uuid,'place.save','{"name":"Cafe","address":"1 Main St","latitude":37.77,"longitude":-122.42,"provider":"google","provider_id":"stable-map-id","source_key":"cafe-b"}');
select set_config('pal.test.message_b',(public.send_message(current_setting('pal.test.group')::uuid,'Friday works for me','10000000-0000-4000-8000-000000000011',current_setting('pal.test.message')::uuid)).id::text,true);
select public.pal_action(current_setting('pal.test.group')::uuid,'poll.vote',jsonb_build_object('id',current_setting('pal.test.poll'),'option_ids','["park"]'::jsonb,'user_id','10000000-0000-4000-8000-000000000001'));
select public.pal_action(current_setting('pal.test.group')::uuid,'group.read',jsonb_build_object('message_id',current_setting('pal.test.message_b')));
select public.pal_action(current_setting('pal.test.group')::uuid,'group.read',jsonb_build_object('message_id',current_setting('pal.test.message')));
do $$
begin
  assert (select count(*)=1 from public.poll_responses where user_id=auth.uid()), 'Vote belongs to actual authenticated user';
  assert (select count(*)=1 from public.places),'Two members saving same map place reuse the place';
  assert (select count(*)=1 from public.sources),'Two members saving same map place reuse the source';
  assert (select count(*)=2 from public.place_contributors),'Shared place retains both member contributions';
  begin
    perform public.pal_action(current_setting('pal.test.group')::uuid,'memory.delete',jsonb_build_object('id',current_setting('pal.test.memory')));
    raise exception 'Expected own-memory authorization';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.pal_action(current_setting('pal.test.group')::uuid,'memory.save',jsonb_build_object('kind','preference','key','food','value','steak','source_message_id',current_setting('pal.test.message')));
    raise exception 'Expected memory source-speaker authorization';
  exception when insufficient_privilege then null;
  end;
  assert not has_function_privilege('authenticated','public.pal_agent_action(uuid,uuid,text,jsonb)','execute'),'Member cannot invoke agent impersonation endpoint';
  assert not has_function_privilege('authenticated','private.pal_execute_action(uuid,uuid,text,jsonb,boolean)','execute'),'Member cannot call internal identity handler';
end $$;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
select public.pal_action(current_setting('pal.test.group')::uuid,'poll.vote',jsonb_build_object('id',current_setting('pal.test.poll'),'option_ids','["cafe"]'::jsonb));
select public.pal_device_register(repeat('a',64),'sandbox');
do $$
begin
  assert (select count(*)=0 from public.reminders where poll_id=current_setting('pal.test.poll')::uuid and status='scheduled'),'All votes cancel pending nudges';
  begin
    perform public.pal_action(current_setting('pal.test.group')::uuid,'poll.vote',jsonb_build_object('id',current_setting('pal.test.poll'),'option_ids','["invented"]'::jsonb));
    raise exception 'Expected invalid option rejection';
  exception when invalid_parameter_value then null;
  end;
end $$;

set local role service_role;
do $$
declare p uuid:=current_setting('pal.test.group')::uuid; j public.agent_jobs; claimed jsonb; conn jsonb; sync jsonb; result jsonb; source public.sources; reminder jsonb; v text;
begin
  assert jsonb_array_length(public.pal_group_state(p)->'members')=2,'Service reads group state without an end-user JWT';
  begin
    perform public.pal_agent_action(p,'10000000-0000-4000-8000-000000000001','plan.confirm',jsonb_build_object('id',current_setting('pal.test.plan'),'source_key','agent-confirm'));
    raise exception 'Expected explicit confirmation requirement';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.pal_agent_action(p,'10000000-0000-4000-8000-000000000001','poll.vote',jsonb_build_object('id',current_setting('pal.test.poll'),'option_ids','["cafe"]'::jsonb,'source_key','agent-vote'));
    raise exception 'Expected no voting impersonation';
  exception when insufficient_privilege then null;
  end;
  perform public.pal_agent_action(p,'10000000-0000-4000-8000-000000000001','reaction.toggle',jsonb_build_object('message_id',current_setting('pal.test.message'),'emoji','👍','source_key','react'));
  assert (select count(*)=1 from public.message_reactions where actor='pal' and user_id is null),'Agent reaction is attributed to Pal';
  update public.agent_jobs set run_after=now() where group_id=p;
  select * into j from public.claim_agent_jobs(10);
  assert cardinality(j.batch_message_ids)=2,'Debounced human messages batch into one job';
  assert (select count(*)=1 from public.agent_jobs where status='coalesced'),'Covered jobs are marked coalesced';
  assert (select count(*)=0 from public.claim_agent_jobs(10)),'At most one running job per group';
  assert public.complete_agent_job(j.id,j.attempts,null,'{"silent":true}'),'Passive job can finish silently';
  assert (select count(*)=0 from public.messages where source_key='job:'||j.id),'Silent completion does not invent a bubble';
  conn:=public.pal_integration_update('google_connections',null,jsonb_build_object('user_id','10000000-0000-4000-8000-000000000001','encrypted_refresh_token','test-ciphertext'));
  assert conn->>'calendar_id' is null,'App never silently uses primary Google calendar';
  result:=public.pal_integration_update('google_connections',(conn->>'id')::uuid,'{"op":"claim"}');
  assert result is not null,'Calendar creation claim obtains lease';
  assert public.pal_integration_update('google_connections',(conn->>'id')::uuid,'{"op":"claim"}') is null,'Overlapping callback cannot create duplicate calendar';
  perform public.pal_integration_update('google_connections',(conn->>'id')::uuid,jsonb_build_object('op','finish','expected_attempt',result->'calendar_attempts','calendar_id','pal-calendar'));
  conn:=public.pal_integration_update('google_connections',null,jsonb_build_object('user_id','10000000-0000-4000-8000-000000000001','encrypted_refresh_token','new-ciphertext'));
  assert conn->>'calendar_id'='pal-calendar','Reconnect preserves app calendar ID';
  claimed:=public.pal_integration_update('google_sync_items',null,'{"op":"claim","limit":20}');sync:=claimed->0;
  assert jsonb_array_length(claimed)=1 and (sync->>'sync_required')::boolean,'Only going member has calendar sync';
  conn:=public.pal_integration_update('google_connections',(conn->>'id')::uuid,jsonb_build_object('op','put','encrypted_access_token','access-ciphertext','expected_status','connected','expected_encrypted_refresh_token','new-ciphertext'));
  assert conn->>'encrypted_access_token'='access-ciphertext','Token refresh updates existing row without refresh-token input';
  assert (select state='syncing' and lease_until is not null from private.google_sync_items where id=(sync->>'id')::uuid),'Token refresh does not invalidate its own sync lease';
  assert public.pal_integration_update('google_sync_items',(sync->>'id')::uuid,jsonb_build_object('op','finish','expected_attempt',sync->'attempts','expected_version',sync->'desired_version','event_id','event-test','state','synced'))->>'ok'='true','Current calendar sync commits';
  result:=public.pal_integration_update('oauth_states',null,jsonb_build_object('user_id','10000000-0000-4000-8000-000000000001','state_hash','test-oauth-hash','encrypted_code_verifier','test-ciphertext'));
  assert public.pal_integration_update('oauth_states',(result->>'id')::uuid,'{"op":"claim"}') is not null,'OAuth state consumes atomically';
  assert public.pal_integration_update('oauth_states',(result->>'id')::uuid,'{"op":"claim"}') is null,'OAuth replay rejected';
  result:=public.pal_agent_action(p,'10000000-0000-4000-8000-000000000001','source.create',jsonb_build_object('url','https://www.instagram.com/reel/example/?utm_source=chat#fragment','source_message_id',current_setting('pal.test.message'),'source_key','source'));
  perform public.pal_agent_action(p,'10000000-0000-4000-8000-000000000002','source.create',jsonb_build_object('url','https://www.instagram.com/reel/example/?igsh=tracker','source_message_id',current_setting('pal.test.message_b'),'source_key','source'));
  assert (select count(*)=1 from public.sources where url is not null),'Tracking links canonicalize to one group source';
  select * into source from public.pal_claim_sources(1);
  result:=public.pal_complete_source(source.id,jsonb_build_object('expected_attempt',source.attempts,'status','resolving','provider_job_id','supadata-test-job','extraction','{"transcript":"saved"}'::jsonb));
  assert result->>'provider_job_id'='supadata-test-job','Provider submission ID survives polling/restarts';
  update public.sources set next_attempt=now() where id=source.id;
  select * into source from public.pal_claim_sources(1);
  result:=public.pal_complete_source(source.id,jsonb_build_object('expected_attempt',source.attempts,'status','needs_confirmation','candidates','[{"name":"Cafe option"}]'::jsonb));
  assert result->'extraction'->>'transcript'='saved','Mapping retries retain paid extraction results';
  assert cardinality(source.place_ids)=0,'Ambiguous candidates are not automatically pinned';
  assert (select count(*)=0 from public.pal_claim_sources(10)),'Finished extraction stops polling';
  reminder:=public.pal_agent_action(p,'10000000-0000-4000-8000-000000000001','reminder.create',jsonb_build_object('body','Leave now','due_at',now()+interval '1 minute','timezone','UTC','source_key','reminder','target_user_ids',jsonb_build_array('10000000-0000-4000-8000-000000000001')));
  update public.reminders set due_at=now()-interval '1 second' where id=(reminder->>'id')::uuid;
  assert public.pal_maintenance()=1,'Maintenance delivers a due reminder with clients offline';
  assert public.pal_maintenance()=0,'Reminder delivery remains idempotent';
  assert (select count(*)=1 from private.push_outbox where payload->>'reminder_id'=reminder->>'id'),'Outbox targets only selected member';
end $$;

set local role authenticated;
select public.send_message(current_setting('pal.test.group')::uuid,'Found this https://www.instagram.com/reel/example/?utm_source=friend','10000000-0000-4000-8000-000000000013');
select public.send_message(current_setting('pal.test.group')::uuid,'@Pal please help','10000000-0000-4000-8000-000000000014');
set local role service_role;
do $$
declare j public.agent_jobs;
begin
  assert (select count(*)=1 from public.sources where url is not null),'Human link ingestion uses the same canonical source pipeline';
  select * into j from public.claim_agent_jobs(1);
  assert j.explicit_mention and j.run_after<=now(),'Explicit mention is immediately claimable';
  perform set_config('pal.test.running_job',j.id::text,true);
end $$;
set local role authenticated;
select public.pal_action(current_setting('pal.test.group')::uuid,'group.settings','{"agent_paused":true}');
select public.send_message(current_setting('pal.test.group')::uuid,'@Pal ignored while paused','10000000-0000-4000-8000-000000000015');
set local role service_role;
do $$
begin
  assert (select status='cancelled' from public.agent_jobs where id=current_setting('pal.test.running_job')::uuid),'Pause invalidates running job scope';
  assert not public.complete_agent_job(current_setting('pal.test.running_job')::uuid,1,'Late response'),'Paused worker cannot publish';
  assert (select count(*)=0 from public.claim_agent_jobs(20)),'Paused group does not enqueue or claim new jobs';
end $$;
reset role;
do $$
begin
  assert private.pal_next_awake('2026-01-02 06:00:00+00','UTC')='2026-01-02 09:00:00+00'::timestamptz,'Quiet early morning waits until 9';
  assert private.pal_next_awake('2026-01-02 23:00:00+00','UTC')='2026-01-03 09:00:00+00'::timestamptz,'Quiet late evening waits until next morning';
  assert private.pal_canonical_url('https://www.instagram.com/reel/DbKdS2nA21V/?xtok=tracking')=private.pal_canonical_url('https://www.instagram.com/reel/DbKdS2nA21V/'),'Instagram xtok does not split source identity';
  assert private.pal_canonical_url('https://example.com/item?item=123&xtok=tracking&view=map')='https://example.com/item?item=123&view=map','Removing tracking preserves meaningful query parameters';
  insert into public.sources(group_id,created_by,url,canonical_url)
    values(current_setting('pal.test.group')::uuid,'10000000-0000-4000-8000-000000000001','https://www.instagram.com/reel/DbKdS2nA21V/?xtok=tracking',private.pal_canonical_url('https://www.instagram.com/reel/DbKdS2nA21V/?xtok=tracking'));
  assert (select url='https://www.instagram.com/reel/DbKdS2nA21V/?xtok=tracking' from public.sources where canonical_url='https://www.instagram.com/reel/DbKdS2nA21V'),'Canonicalization preserves original shared URL';
end $$;
set local role authenticated;
select public.pal_action(current_setting('pal.test.group')::uuid,'group.settings','{"agent_paused":false,"proactive_suggestions":true}');
set local role service_role;
do $$
declare m uuid; routed uuid;
begin
  insert into public.messages(group_id,role,body,source_key) values(current_setting('pal.test.group')::uuid,'system','Weekly test','test-weekly') returning id into m;
  insert into public.agent_jobs(message_id,group_id,requester_id,status,attempts,lease_until,job_kind,explicit_mention)
    values(m,current_setting('pal.test.group')::uuid,'10000000-0000-4000-8000-000000000001','running',1,now()+interval '5 minutes','weekly',false);
  insert into public.messages(group_id,role,body,source_key) values(current_setting('pal.test.group')::uuid,'system','Internal scheduling marker','weekly:push-regression') returning id into m;
  assert not exists(select 1 from private.push_outbox where message_id=m),'Internal weekly marker never creates APNs outbox';
  insert into public.messages(group_id,role,body,source_key,card)
  values(current_setting('pal.test.group')::uuid,'pal','Choose a time','card:push-routing',jsonb_build_object('type','availability','entity_id',current_setting('pal.test.poll'))) returning id into routed;
  assert (select count(*)=2 from private.push_outbox where message_id=routed and payload->>'type'='availability' and payload->>'entity_id'=current_setting('pal.test.poll')),'Card pushes persist exact type and entity route for both members';
end $$;
set local role authenticated;
select public.pal_action(current_setting('pal.test.group')::uuid,'group.settings','{"proactive_suggestions":false}');
set local role service_role;
do $$
begin
  assert (select count(*)=1 from public.agent_jobs where group_id=current_setting('pal.test.group')::uuid and job_kind='weekly' and status='cancelled' and lease_until is null),'Opt-out cancels running weekly scope';
end $$;
set local role authenticated;
select public.pal_action(current_setting('pal.test.group')::uuid,'plan.update',jsonb_build_object('id',current_setting('pal.test.plan'),'starts_at',now()+interval '4 days'));
set local role service_role;
do $$
begin
  assert (select count(*)=0 from public.plan_rsvps where plan_id=current_setting('pal.test.plan')::uuid),'Rescheduling requires fresh RSVP decisions';
  assert (select state='remove' from private.google_sync_items where plan_id=current_setting('pal.test.plan')::uuid),'Rescheduling without fresh RSVP queues old calendar removal';
  assert (select count(*)=2 from public.reminders where plan_id=current_setting('pal.test.plan')::uuid and status='cancelled'),'Obsolete event reminders cancel on reschedule';
end $$;
set local role authenticated;
select public.pal_action(current_setting('pal.test.group')::uuid,'plan.cancel',jsonb_build_object('id',current_setting('pal.test.plan')));
set local role service_role;
do $$
begin
  assert (select state='remove' from private.google_sync_items where plan_id=current_setting('pal.test.plan')::uuid),'Plan cancellation queues calendar removal';
  assert (select count(*)=0 from public.reminders where plan_id=current_setting('pal.test.plan')::uuid and status='scheduled'),'Plan cancellation invalidates event reminders';
  assert not has_function_privilege('authenticated','public.pal_integration_state(text,integer)','execute'),'Tokens and push outbox are never client-readable';
  assert not has_function_privilege('anon','public.pal_action(uuid,text,jsonb)','execute'),'Signed-out clients cannot perform actions';
end $$;
set local role authenticated;
select set_config('pal.test.time_poll',(public.pal_action(current_setting('pal.test.group')::uuid,'poll.create',jsonb_build_object('kind','time','question','Which time works?','options',jsonb_build_array(jsonb_build_object('id','fri','label','Friday','starts_at',now()+interval '2 days'),jsonb_build_object('id','sat','label','Saturday','starts_at',now()+interval '3 days')),'deadline_at',now()+interval '1 hour','source_key','time-decline-regression')))->>'id',true);
select public.pal_action(current_setting('pal.test.group')::uuid,'poll.vote',jsonb_build_object('id',current_setting('pal.test.time_poll'),'option_ids','[]'::jsonb));
do $$
declare state jsonb;
begin
  assert (select cardinality(option_ids)=0 from public.poll_responses where poll_id=current_setting('pal.test.time_poll')::uuid and user_id=auth.uid()),'Empty time choice is a persisted explicit response';
  select p into state from jsonb_array_elements(public.pal_group_state(current_setting('pal.test.group')::uuid)->'polls') p where p->>'id'=current_setting('pal.test.time_poll');
  assert state->'responses'=jsonb_build_array(jsonb_build_object('user_id',auth.uid(),'option_ids','[]'::jsonb)),'State distinguishes explicit decline from absent response';
  assert state->'votes'='[]'::jsonb,'Empty response does not invent a selected time';
  assert not exists(select 1 from jsonb_array_elements(state->'responses') r where r->>'user_id'='10000000-0000-4000-8000-000000000002'),'Member who has not answered remains unknown';
  begin
    perform public.pal_action(current_setting('pal.test.group')::uuid,'poll.vote',jsonb_build_object('id',current_setting('pal.test.poll'),'option_ids','[]'::jsonb));
    raise exception 'Expected empty place vote rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.pal_action(current_setting('pal.test.group')::uuid,'poll.vote',jsonb_build_object('id',current_setting('pal.test.time_poll')));
    raise exception 'Expected omitted time choice rejection';
  exception when invalid_parameter_value then null;
  end;
end $$;
reset role;
do $$
begin
  -- Fixture clock is awake in this IANA zone regardless of when the suite runs.
  update public.groups set timezone=(select name from pg_timezone_names where extract(hour from now() at time zone name)=12 order by name limit 1) where id=current_setting('pal.test.group')::uuid;
  update public.reminders set due_at=now()-interval '1 second' where poll_id=current_setting('pal.test.time_poll')::uuid and kind='poll_halfway';
end $$;
set local role service_role;
select public.pal_maintenance();
do $$
begin
  assert (select count(*)=1 from private.push_outbox where payload->>'poll_id'=current_setting('pal.test.time_poll') and payload ? 'reminder_id' and user_id='10000000-0000-4000-8000-000000000002'),'Halfway nudge targets only the unanswered member';
  assert not exists(select 1 from private.push_outbox where payload->>'poll_id'=current_setting('pal.test.time_poll') and payload ? 'reminder_id' and user_id='10000000-0000-4000-8000-000000000001'),'Explicit decline excludes member from nudges';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
select public.pal_action(current_setting('pal.test.group')::uuid,'poll.vote',jsonb_build_object('id',current_setting('pal.test.time_poll'),'option_ids','[]'::jsonb));
do $$
begin
  assert (select count(*)=2 from public.poll_responses where poll_id=current_setting('pal.test.time_poll')::uuid and cardinality(option_ids)=0),'Both members can explicitly decline all times';
  assert not exists(select 1 from public.reminders where poll_id=current_setting('pal.test.time_poll')::uuid and status='scheduled'),'All members responding cancels remaining deadline nudge';
end $$;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000003',true);
do $$
begin
  assert (select count(*)=0 from public.places),'Other groups cannot read saved places';
  assert (select count(*)=0 from public.profiles),'Other groups cannot read profiles';
  begin
    perform public.pal_group_state(current_setting('pal.test.group')::uuid);
    raise exception 'Expected group state denial';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.pal_action(current_setting('pal.test.group')::uuid,'plan.cancel',jsonb_build_object('id',current_setting('pal.test.plan')));
    raise exception 'Expected action denial';
  exception when insufficient_privilege then null;
  end;
end $$;
rollback;
