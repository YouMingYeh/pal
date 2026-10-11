-- Assert-based integration suite; all fixtures roll back, including Auth users.
begin;
insert into auth.users(id,email) values
 ('00000000-0000-4000-8000-000000000001','pal-test-a@example.invalid'),
 ('00000000-0000-4000-8000-000000000002','pal-test-b@example.invalid'),
 ('00000000-0000-4000-8000-000000000003','pal-test-outsider@example.invalid');

set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
select set_config('pal.test.group_id',(public.create_group('Pal integration test')).id::text,true);
select set_config('pal.test.invite',(select invite_code::text from public.groups where id=current_setting('pal.test.group_id')::uuid),true);
select public.send_message(current_setting('pal.test.group_id')::uuid,'@Pal summarize our plan','00000000-0000-4000-8000-000000000010');
select public.send_message(current_setting('pal.test.group_id')::uuid,'@Pal summarize our plan','00000000-0000-4000-8000-000000000010');
do $$
begin
  assert (select count(*)=1 from public.messages), 'Retry must not duplicate messages';
  assert (select count(*)=1 from public.agent_jobs), 'Retry must not duplicate jobs';
  begin
    perform public.send_message(current_setting('pal.test.group_id')::uuid,'Changed body','00000000-0000-4000-8000-000000000010');
    raise exception 'Expected client ID conflict';
  exception when invalid_parameter_value then null;
  end;
end $$;

select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
do $$
begin
  assert (select count(*)=0 from public.messages), 'Non-member must not see messages';
  begin
    perform public.send_message(current_setting('pal.test.group_id')::uuid,'Intrusion','00000000-0000-4000-8000-000000000011');
    raise exception 'Expected group membership denial';
  exception when insufficient_privilege then null;
  end;
end $$;
select public.join_group(current_setting('pal.test.invite')::uuid);
select public.join_group(current_setting('pal.test.invite')::uuid);
select public.send_message(current_setting('pal.test.group_id')::uuid,'Dinner at seven','00000000-0000-4000-8000-000000000011');
do $$
begin
  assert (select count(*)=2 from public.messages), 'Second member sees both messages';
  assert (select count(*)=2 from public.group_members), 'Joining twice does not duplicate membership';
  assert (select count(*)=1 from public.agent_jobs), 'Ordinary messages do not trigger Pal';
end $$;

select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000003',true);
do $$
declare v_table text; v_column text;
begin
  assert (select count(*)=0 from public.groups), 'Outsider cannot see groups or invite codes';
  assert (select count(*)=0 from public.group_members), 'Outsider cannot see members';
  assert (select count(*)=0 from public.messages), 'Outsider cannot see messages';
  assert (select count(*)=0 from public.agent_jobs), 'Outsider cannot see jobs';
  assert (select count(*)=0 from public.reminders), 'Outsider cannot see reminders';
  foreach v_table in array array['groups','group_members','messages','agent_jobs','reminders'] loop
    v_column := case when v_table='group_members' then 'group_id' else 'id' end;
    begin
      execute format('insert into public.%I default values',v_table);
      raise exception 'Client could insert into %',v_table;
    exception when insufficient_privilege then null;
    end;
    begin
      execute format('update public.%I set %I=%I where false',v_table,v_column,v_column);
      raise exception 'Client could update %',v_table;
    exception when insufficient_privilege then null;
    end;
    begin
      execute format('delete from public.%I where false',v_table);
      raise exception 'Client could delete from %',v_table;
    exception when insufficient_privilege then null;
    end;
  end loop;
  assert not has_function_privilege('authenticated','public.claim_agent_jobs(integer)','EXECUTE'), 'Client cannot claim jobs';
  assert not has_function_privilege('authenticated','public.complete_agent_job(uuid,integer,text,text)','EXECUTE'), 'Client cannot complete jobs';
  assert not has_function_privilege('authenticated','public.fail_agent_job(uuid,integer,text)','EXECUTE'), 'Client cannot fail jobs';
  assert not has_function_privilege('authenticated','public.create_reminder(uuid,uuid,text,timestamptz,text,text)','EXECUTE'), 'Client cannot impersonate reminder tools';
  assert not has_function_privilege('authenticated','private.deliver_due_reminders()','EXECUTE'), 'Client cannot dispatch reminders';
end $$;

set local role anon;
do $$
declare v_table text; v_column text;
begin
  foreach v_table in array array['groups','group_members','messages','agent_jobs','reminders'] loop
    v_column := case when v_table='group_members' then 'group_id' else 'id' end;
    begin
      execute format('select * from public.%I limit 1',v_table);
      raise exception 'Anonymous role could read %',v_table;
    exception when insufficient_privilege then null;
    end;
    begin
      execute format('insert into public.%I default values',v_table);
      raise exception 'Anonymous role could insert into %',v_table;
    exception when insufficient_privilege then null;
    end;
    begin
      execute format('update public.%I set %I=%I where false',v_table,v_column,v_column);
      raise exception 'Anonymous role could update %',v_table;
    exception when insufficient_privilege then null;
    end;
    begin
      execute format('delete from public.%I where false',v_table);
      raise exception 'Anonymous role could delete from %',v_table;
    exception when insufficient_privilege then null;
    end;
  end loop;
  assert not has_function_privilege('anon','public.create_group(text)','EXECUTE'), 'Signed-out clients cannot create groups';
  assert not has_function_privilege('anon','public.send_message(uuid,text,uuid)','EXECUTE'), 'Signed-out clients cannot send messages';
  assert not has_function_privilege('anon','public.claim_agent_jobs(integer)','EXECUTE'), 'Signed-out clients cannot claim jobs';
  assert not has_function_privilege('anon','public.complete_agent_job(uuid,integer,text,text)','EXECUTE'), 'Signed-out clients cannot complete jobs';
  assert not has_function_privilege('anon','public.fail_agent_job(uuid,integer,text)','EXECUTE'), 'Signed-out clients cannot fail jobs';
  assert not has_function_privilege('anon','public.create_reminder(uuid,uuid,text,timestamptz,text,text)','EXECUTE'), 'Signed-out clients cannot create reminders';
end $$;

set local role service_role;
do $$
declare v_job public.agent_jobs; v_reminder public.reminders; v_due timestamptz := now()+interval '1 minute';
begin
  select * into v_job from public.claim_agent_jobs(1);
  assert v_job.status='running' and v_job.attempts=1, 'Worker claim sets a lease';
  assert (select count(*)=0 from public.claim_agent_jobs(1)), 'Active lease excludes duplicate claim';
  assert not public.complete_agent_job(v_job.id,0,'Stale response'), 'Stale worker cannot complete a job';
  assert public.complete_agent_job(v_job.id,1,'The group plans dinner at seven.','{"sessionId":"test"}'), 'Current worker publishes result';
  assert not public.complete_agent_job(v_job.id,1,'Duplicate response'), 'Completion is idempotent';
  assert (select count(*)=1 from public.messages where source_key='job:'||v_job.id), 'One Pal result is posted';
  v_reminder := public.create_reminder(current_setting('pal.test.group_id')::uuid,'00000000-0000-4000-8000-000000000001','Leave for dinner',v_due,'America/Los_Angeles','test-reminder');
  assert (public.create_reminder(v_reminder.group_id,v_reminder.requester_id,v_reminder.body,v_due,v_reminder.timezone,'test-reminder')).id=v_reminder.id, 'Reminder tool retries deduplicate';
  begin
    perform public.create_reminder(v_reminder.group_id,'00000000-0000-4000-8000-000000000003','Intrusion',v_due,'UTC','intrusion');
    raise exception 'Expected requester membership denial';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.create_reminder(v_reminder.group_id,v_reminder.requester_id,'Invalid timezone',v_due,'Mars/Olympus','invalid-zone');
    raise exception 'Expected timezone denial';
  exception when invalid_parameter_value then null;
  end;
  update public.reminders set due_at=now()-interval '1 second' where id=v_reminder.id;
  v_reminder := public.create_reminder(v_reminder.group_id,v_reminder.requester_id,v_reminder.body,now()-interval '1 second',v_reminder.timezone,'test-reminder');
  assert v_reminder.status='scheduled', 'Retry returns existing reminder even after its due time';
  insert into public.reminders(group_id,requester_id,body,due_at,timezone,status,source_key)
    values(v_reminder.group_id,v_reminder.requester_id,'Cancelled reminder',now()-interval '1 second','UTC','cancelled','cancelled-reminder');
end $$;

reset role;
do $$
begin
  assert private.deliver_due_reminders()=1, 'Closed-client reminder dispatch delivers due reminder';
  assert private.deliver_due_reminders()=0, 'Second dispatch does not duplicate delivery';
  assert (select count(*)=1 from public.messages where source_key like 'reminder:%'), 'Exactly one reminder message committed';
  assert (select status='completed' from public.reminders where source_key='test-reminder'), 'Delivery and completion committed together';
  assert (select status='cancelled' from public.reminders where source_key='cancelled-reminder'), 'Cancelled reminders remain cancelled';
end $$;
rollback;
