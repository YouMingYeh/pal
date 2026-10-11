-- Isolated database only. Both rehearsals and identities roll back.
begin;
insert into auth.users(id,email) values
 ('d0110000-0000-4000-8000-000000000001','demo-kind-owner@example.invalid'),
 ('d0110000-0000-4000-8000-000000000002','demo-kind-maya@example.invalid'),
 ('d0110000-0000-4000-8000-000000000003','demo-kind-theo@example.invalid'),
 ('d0110000-0000-4000-8000-000000000004','demo-kind-ben@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','d0110000-0000-4000-8000-000000000001',true);
select set_config('demo.chat',(public.create_group('Demo chat isolated')).id::text,true);
select set_config('demo.plan',(public.create_group('Demo plan isolated')).id::text,true);
reset role;
update public.groups set is_demo=true where id in(current_setting('demo.chat')::uuid,current_setting('demo.plan')::uuid);
insert into public.group_members(group_id,user_id)
 select g,u from unnest(array[current_setting('demo.chat')::uuid,current_setting('demo.plan')::uuid]) g,
 unnest(array['d0110000-0000-4000-8000-000000000002'::uuid,'d0110000-0000-4000-8000-000000000003'::uuid,'d0110000-0000-4000-8000-000000000004'::uuid]) u;
set local role service_role;
select public.pal_demo_register(current_setting('demo.chat')::uuid,array['d0110000-0000-4000-8000-000000000002'::uuid,'d0110000-0000-4000-8000-000000000003'::uuid,'d0110000-0000-4000-8000-000000000004'::uuid],'{}','chat');
select public.pal_demo_register(current_setting('demo.plan')::uuid,array['d0110000-0000-4000-8000-000000000002'::uuid,'d0110000-0000-4000-8000-000000000003'::uuid,'d0110000-0000-4000-8000-000000000004'::uuid],'{}');
update private.pal_demo_rooms set next_step=3 where group_id in(current_setting('demo.chat')::uuid,current_setting('demo.plan')::uuid);
select set_config('demo.chat.generation',(public.pal_group_state(current_setting('demo.chat')::uuid)->'demo'->>'generation'),true);
select set_config('demo.chat.message',(public.pal_demo_begin(current_setting('demo.chat')::uuid,'d0110000-0000-4000-8000-000000000001',3,current_setting('demo.chat.generation')::uuid,gen_random_uuid(),'I survived Monday.','[]')).id::text,true);
do $$ declare state jsonb; begin
 state:=public.pal_group_state(current_setting('demo.chat')::uuid)->'demo';
 assert state->>'kind'='chat','Registered kind is explicit';
 assert state->>'step'='4','Chat fourth exchange advances without a draft';
 assert state->>'source_message_id'=current_setting('demo.chat.message'),'Source references actual accepted operator message';
 assert state->>'operator_message_id'=current_setting('demo.chat.message'),'Operator alias is exact';
 assert state->>'operator_user_id'='d0110000-0000-4000-8000-000000000001','Actual operator identity preserved';
 assert state->>'run_id' is not null and jsonb_array_length(state->'actor_ids')=3,'Run/cast metadata remains bounded';
 assert not exists(select 1 from public.plans where group_id=current_setting('demo.chat')::uuid),'Chat does not create or require dinner';
 assert not exists(select 1 from private.push_outbox where group_id=current_setting('demo.chat')::uuid),'Rehearsal stays push-silent';
 assert public.pal_group_state(current_setting('demo.plan')::uuid)->'demo'->>'kind'='plan','Three-argument registration still defaults to plan';
 begin
 perform public.pal_demo_begin(current_setting('demo.plan')::uuid,'d0110000-0000-4000-8000-000000000001',3,(public.pal_group_state(current_setting('demo.plan')::uuid)->'demo'->>'generation')::uuid,gen_random_uuid(),'Move dinner to eight.','[]');
 raise exception 'Planning fourth exchange must retain draft guard'; exception when invalid_parameter_value then null; end;
 begin
 perform public.pal_demo_register(current_setting('demo.chat')::uuid,'{}','{}','unknown');
 raise exception 'Unknown kind must fail before modifying registration'; exception when invalid_parameter_value then null; end;
 assert not has_function_privilege('authenticated','public.pal_demo_register(uuid,uuid[],uuid[],text)','execute'),'Members cannot configure cast';
end $$;
select public.pal_demo_reset(current_setting('demo.chat')::uuid,'d0110000-0000-4000-8000-000000000001');
do $$ declare state jsonb; begin
 state:=public.pal_group_state(current_setting('demo.chat')::uuid)->'demo';
 assert state->>'kind'='chat' and state->>'step'='0','Reset retains chat kind';
 assert state->>'operator_message_id' is null and state->>'operator_user_id' is null and state->>'run_id' is null,'Reset removes stale operator provenance';
 assert not exists(select 1 from public.messages where group_id=current_setting('demo.chat')::uuid),'Reset clears only rehearsal dialogue';
end $$;
rollback;
