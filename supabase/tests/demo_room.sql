-- Isolated test database only. Every row rolls back.
begin;
insert into auth.users(id,email) values
 ('d0100000-0000-4000-8000-000000000001','demo-owner@example.invalid'),
 ('d0100000-0000-4000-8000-000000000002','demo-maya@example.invalid'),
 ('d0100000-0000-4000-8000-000000000003','demo-theo@example.invalid'),
 ('d0100000-0000-4000-8000-000000000004','demo-ben@example.invalid'),
 ('d0100000-0000-4000-8000-000000000005','demo-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','d0100000-0000-4000-8000-000000000001',true);
select set_config('demo.group',(public.create_group('Demo')).id::text,true);
select set_config('demo.normal',(public.create_group('Real chat preserved')).id::text,true);
reset role;
update public.groups set is_demo=true where id=current_setting('demo.group')::uuid;
insert into public.group_members(group_id,user_id) select current_setting('demo.group')::uuid,v from unnest(array['d0100000-0000-4000-8000-000000000002'::uuid,'d0100000-0000-4000-8000-000000000003'::uuid,'d0100000-0000-4000-8000-000000000004'::uuid]) v;
insert into public.group_members(group_id,user_id) values(current_setting('demo.normal')::uuid,'d0100000-0000-4000-8000-000000000005');
set local role service_role;
select public.pal_demo_register(current_setting('demo.group')::uuid,array['d0100000-0000-4000-8000-000000000002'::uuid,'d0100000-0000-4000-8000-000000000003'::uuid,'d0100000-0000-4000-8000-000000000004'::uuid],'{}');
select public.pal_demo_reset(current_setting('demo.group')::uuid,'d0100000-0000-4000-8000-000000000001');
select set_config('demo.generation',(public.pal_group_state(current_setting('demo.group')::uuid)->'demo'->>'generation'),true);
select set_config('demo.client',gen_random_uuid()::text,true);
select set_config('demo.message',(public.pal_demo_begin(current_setting('demo.group')::uuid,'d0100000-0000-4000-8000-000000000001',0,current_setting('demo.generation')::uuid,current_setting('demo.client')::uuid,'Dinner Friday?',
 '[{"user_id":"d0100000-0000-4000-8000-000000000002","body":"Friday after seven. Vegetarian."},{"user_id":"d0100000-0000-4000-8000-000000000003","body":"Eight works for me."}]')).id::text,true);
do $$ begin
 assert (select count(*)=0 from public.claim_agent_jobs(20)),'Pal cannot read a partly spoken scene';
 assert public.pal_demo_tick(current_setting('demo.group')::uuid)=1,'First actor emits once';
 assert public.pal_demo_tick(current_setting('demo.group')::uuid)=0,'Second actor waits its turn';
 assert (select count(*)=0 from public.claim_agent_jobs(20)),'Pal still waits for the remaining actor';
 assert (select count(*)=2 from public.messages where group_id=current_setting('demo.group')::uuid),'No canned Pal reply is inserted';
 assert (public.pal_demo_begin(current_setting('demo.group')::uuid,'d0100000-0000-4000-8000-000000000001',0,current_setting('demo.generation')::uuid,current_setting('demo.client')::uuid,'Dinner Friday?','[]')).id=current_setting('demo.message')::uuid,'A network retry reuses its actual human message and cast';
 begin
 perform public.pal_demo_begin(current_setting('demo.normal')::uuid,'d0100000-0000-4000-8000-000000000001',0,gen_random_uuid(),gen_random_uuid(),'Spoof','[]');
 raise exception 'Normal group must reject simulated actors'; exception when insufficient_privilege then null; end;
 begin
 perform public.pal_demo_reset(current_setting('demo.group')::uuid,'d0100000-0000-4000-8000-000000000005');
 raise exception 'Outsider must not reset'; exception when insufficient_privilege then null; end;
end $$;
update private.pal_demo_lines set due_at=now()-interval '1 second' where emitted_at is null;
select public.pal_demo_tick(current_setting('demo.group')::uuid);
select set_config('demo.job',(select id::text from public.claim_agent_jobs(20)),true);
do $$ declare j public.agent_jobs; begin
 select * into j from public.agent_jobs where id=current_setting('demo.job')::uuid;
 assert cardinality(j.batch_message_ids)=3,'The real turn includes operator and both actual mock-speaker sources';
 assert public.complete_agent_job_with_outputs(j.id,j.attempts,'[{"body":"Friday dinner has finally escaped the group chat.","emotion":"fier"}]');
 assert public.pal_group_state(j.group_id)->'demo'->>'status'='ready','Only actual completion unlocks the next scene';
 assert not exists(select 1 from private.push_outbox where group_id=j.group_id),'Rehearsal never pushes the scripted burst';
end $$;
-- The controller's explicitly approved time change updates the draft instead of duplicating it.
insert into public.plans(group_id,created_by,title,status,starts_at,ends_at,place_id) select current_setting('demo.group')::uuid,'d0100000-0000-4000-8000-000000000001','Dinner','draft',starts_at,starts_at+interval '2 hours',null from private.pal_demo_rooms where group_id=current_setting('demo.group')::uuid;
-- A real connected member still must not receive automatic rehearsal events.
insert into private.google_connections(user_id,status,calendar_id,encrypted_refresh_token) values('d0100000-0000-4000-8000-000000000001','connected','unit-test-calendar','unit-test-encrypted-placeholder');
insert into public.plans(group_id,created_by,title,status,starts_at,ends_at) values(current_setting('demo.group')::uuid,'d0100000-0000-4000-8000-000000000001','Demo dinner','confirmed',now()+interval '7 days',now()+interval '7 days 2 hours');
insert into public.plan_rsvps(plan_id,group_id,user_id,status) select id,group_id,'d0100000-0000-4000-8000-000000000001','going' from public.plans where group_id=current_setting('demo.group')::uuid;
select public.pal_integration_update('google_connections',null,jsonb_build_object('user_id','d0100000-0000-4000-8000-000000000001','status','connected','resync',true));
do $$ begin
 assert not exists(select 1 from private.google_sync_items s join public.plans p on p.id=s.plan_id where p.group_id=current_setting('demo.group')::uuid),'No rehearsal Google copy';
 assert not exists(select 1 from private.push_outbox where group_id=current_setting('demo.group')::uuid),'Automatic rehearsal invitation remains push-silent';
end $$;
set local role authenticated;
select public.send_message(current_setting('demo.normal')::uuid,'This real message remains intact',gen_random_uuid());
do $$ begin
 assert not has_function_privilege('authenticated','public.pal_demo_begin(uuid,uuid,integer,uuid,uuid,text,jsonb)','execute'),'No privileged actor endpoint exposed to members';
 assert exists(select 1 from jsonb_array_elements(public.pal_inbox()) g where g->>'id'=current_setting('demo.group') and (g->>'is_demo')::boolean),'Inbox marks only the registered rehearsal';
end $$;
set local role service_role;
select public.pal_demo_reset(current_setting('demo.group')::uuid,'d0100000-0000-4000-8000-000000000001');
do $$ begin
 assert (select count(*)=0 from public.messages where group_id=current_setting('demo.group')::uuid),'Restart clears only rehearsal dialogue';
 assert (select count(*)=1 from public.messages where group_id=current_setting('demo.normal')::uuid),'Real conversation remains identical';
 assert exists(select 1 from private.push_outbox where group_id=current_setting('demo.normal')::uuid),'Real chat notifications continue';
 begin
 perform public.pal_demo_begin(current_setting('demo.group')::uuid,'d0100000-0000-4000-8000-000000000001',0,current_setting('demo.generation')::uuid,gen_random_uuid(),'Old stale action','[]');
 raise exception 'An earlier rehearsal must not restart after reset'; exception when invalid_parameter_value then null; end;
end $$;
rollback;
