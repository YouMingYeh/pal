-- Dedicated test database only. No provider calls; fixtures roll back.
begin;
insert into auth.users(id,email) values
 ('b0000000-0000-4000-8000-000000000001','pal-reply-owner@example.invalid'),
 ('b0000000-0000-4000-8000-000000000002','pal-reply-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','b0000000-0000-4000-8000-000000000001',true);
select set_config('pal.reply.group',(public.create_group('Selective reply')).id::text,true);
select public.send_message(current_setting('pal.reply.group')::uuid,'Thank you, Bob.',gen_random_uuid());
do $$
begin
  assert not has_function_privilege('authenticated','public.pal_begin_reply(uuid,integer)','execute'),'Members cannot forge reply intent';
  assert not has_function_privilege('anon','public.pal_begin_reply(uuid,integer)','execute'),'Anonymous clients cannot forge reply intent';
  assert public.pal_group_state(current_setting('pal.reply.group')::uuid)->'pal_activity'->>'activity'='idle','A queued group source never claims typing';
end $$;
set local role service_role;
do $$
declare j public.agent_jobs; stamp timestamptz; n integer;
begin
  update public.agent_jobs set run_after=now() where group_id=current_setting('pal.reply.group')::uuid;
  select * into j from public.claim_agent_jobs(1);
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Claiming and reading may still end in silence';
  assert not public.pal_begin_reply(j.id,j.attempts+1),'Wrong attempt cannot declare reply intent';
  assert public.pal_begin_reply(j.id,j.attempts),'Verified current reply intent succeeds';
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='typing','Only chosen live replies show typing';
  assert (public.pal_group_state(j.group_id)->'pal_activity'->>'expires_at')::timestamptz=now()+interval '20 seconds','Reply intent has a short bounded typing window';
  select reply_started_at into stamp from public.agent_jobs where id=j.id;
  assert public.pal_begin_reply(j.id,j.attempts),'Same-attempt retry is idempotent';
  assert (select reply_started_at=stamp from public.agent_jobs where id=j.id),'Retry retains its original start time';
  update public.agent_jobs set lease_until=now()-interval '1 second' where id=j.id;
  assert not public.pal_begin_reply(j.id,j.attempts),'Expired lease cannot mark typing';
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Expiry hides the existing marker';
  update public.agent_jobs set attempts=attempts+1,lease_until=now()+interval '5 minutes' where id=j.id;
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','A reclaimed attempt cannot inherit old reply intent';
  assert not public.pal_begin_reply(j.id,j.attempts),'A stale worker cannot mark the new attempt';
  assert public.pal_begin_reply(j.id,j.attempts+1),'The current retry can choose its own reply';
  update public.agent_jobs set reply_started_at=now()-interval '21 seconds' where id=j.id;
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','A stalled generator cannot leave typing visible';
  assert public.pal_begin_reply(j.id,j.attempts+1),'Same-attempt delivery may retry safely';
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Retry cannot extend the bounded typing window';
  update public.groups set agent_paused=true where id=j.group_id;
  assert not public.pal_begin_reply(j.id,j.attempts+1),'Paused groups deny reply intent';
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Pause hides chosen typing';
  update public.groups set agent_paused=false where id=j.group_id;
  delete from public.group_members where group_id=j.group_id and user_id=j.requester_id;
  assert not public.pal_begin_reply(j.id,j.attempts+1),'A departed requester has no job authority';
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Lost membership removes typing';
  insert into public.group_members(group_id,user_id) values(j.group_id,j.requester_id);
  update public.messages set role='system' where id=j.message_id;
  assert not public.pal_begin_reply(j.id,j.attempts+1),'A chat job requires its actual human source';
  update public.messages set role='user' where id=j.message_id;
  n:=(select count(*) from public.messages where group_id=j.group_id);
  assert public.complete_agent_job_with_outputs(j.id,j.attempts+1,'[]'),'A worker remains allowed to end without posting';
  assert (select count(*)=n from public.messages where group_id=j.group_id),'Activity does not force a message or create a response loop';
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Completion clears chosen typing';
  assert not public.pal_begin_reply(j.id,j.attempts+1),'Completed work cannot revive typing';
end $$;
set local role authenticated;
select set_config('pal.reply.dm',(public.ensure_pal_direct()).id::text,true);
select public.send_message(current_setting('pal.reply.dm')::uuid,'Hi Pal',gen_random_uuid());
do $$
begin
  assert public.pal_group_state(current_setting('pal.reply.dm')::uuid)->'pal_activity'->>'activity'='idle','Private DM also waits for a real reply decision';
end $$;
set local role service_role;
do $$
declare j public.agent_jobs; a jsonb;
begin
  select * into j from public.claim_agent_jobs(1);
  assert j.group_id=current_setting('pal.reply.dm')::uuid,'The remaining fixture is the private chat';
  assert public.pal_group_state(j.group_id)->'pal_activity'->>'activity'='idle','Private decision work also stays quiet';
  update public.agent_jobs set lease_until=now()+interval '5 seconds' where id=j.id;
  assert public.pal_begin_reply(j.id,j.attempts),'Private chats may signal a chosen real reply';
  a:=public.pal_group_state(j.group_id)->'pal_activity';
  assert a->>'activity'='typing' and a->>'status'='running','Private reply intent uses the same explicit phase';
  assert (a->>'expires_at')::timestamptz=now()+interval '5 seconds','A shorter lease wins over the 20-second cap';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','b0000000-0000-4000-8000-000000000002',true);
do $$
begin
  begin
    perform public.pal_group_state(current_setting('pal.reply.group')::uuid);
    raise exception 'Expected outsider privacy denial';
  exception when insufficient_privilege then null;
  end;
end $$;
rollback;
