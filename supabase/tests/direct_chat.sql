-- Dedicated test database only. Private chats, context and fixtures roll back.
begin;
insert into auth.users(id,email) values
 ('30000000-0000-4000-8000-000000000001','pal-direct-owner@example.invalid'),
 ('30000000-0000-4000-8000-000000000002','pal-direct-member@example.invalid'),
 ('30000000-0000-4000-8000-000000000003','pal-direct-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','30000000-0000-4000-8000-000000000001',true);
select set_config('pal.direct.id',(public.ensure_pal_direct()).id::text,true);
select set_config('pal.direct.invite',(select invite_code::text from public.groups where id=current_setting('pal.direct.id')::uuid),true);
do $$
declare g public.groups;
begin
  g:=public.ensure_pal_direct();
  assert g.id=current_setting('pal.direct.id')::uuid and g.is_direct and not g.proactive_suggestions,'Ensure reuses one quiet private Pal chat';
  assert (select count(*)=1 from public.group_members where group_id=g.id and user_id=auth.uid()),'Private chat contains only its owner';
  assert public.pal_group_state(g.id)->'settings'->>'is_direct'='true','Authorized direct state exposes its room type';
  begin
    perform public.join_group(g.invite_code);
    raise exception 'Expected direct invitation rejection even for owner';
  exception when insufficient_privilege then null;
  end;
end $$;
select set_config('pal.direct.visible',(public.create_group('Visible group 1')).id::text,true);
select set_config('pal.direct.visible_invite',(select invite_code::text from public.groups where id=current_setting('pal.direct.visible')::uuid),true);
do $$
declare i integer;
begin
  for i in 2..7 loop perform public.create_group('Visible group '||i); end loop;
  for i in 1..25 loop perform public.send_message(current_setting('pal.direct.visible')::uuid,'Message '||i||' '||repeat('x',600),gen_random_uuid()); end loop;
  for i in 1..11 loop perform public.pal_action(current_setting('pal.direct.visible')::uuid,'source.create',jsonb_build_object('url','https://example.invalid/article?id='||i,'title','Article '||i)); end loop;
end $$;
select public.pal_action(current_setting('pal.direct.visible')::uuid,'place.save','{"name":"Cafe","address":"1 Main St","latitude":25.03,"longitude":121.56,"provider":"google","provider_id":"direct-test-cafe"}');
select public.pal_action(current_setting('pal.direct.visible')::uuid,'plan.create',jsonb_build_object('title','Dinner','starts_at',now()+interval '2 days'));
select public.pal_action(current_setting('pal.direct.visible')::uuid,'memory.save',jsonb_build_object('kind','preference','key','own','value',repeat('v',250)));
select public.pal_action(current_setting('pal.direct.visible')::uuid,'memory.save',jsonb_build_object('kind','availability','key','expired','value','OLD_AVAILABILITY','expires_at',now()+interval '1 hour'));
select set_config('request.jwt.claim.sub','30000000-0000-4000-8000-000000000002',true);
select public.join_group(current_setting('pal.direct.visible_invite')::uuid);
select public.pal_action(current_setting('pal.direct.visible')::uuid,'memory.save','{"kind":"preference","key":"othermember","value":"OTHER_MEMBER_MEMORY"}');
select set_config('pal.direct.other_dm',(public.ensure_pal_direct()).id::text,true);
do $$
begin
  assert (select count(*)=0 from public.groups where id=current_setting('pal.direct.id')::uuid),'Other user cannot read owner private chat';
  begin
    perform public.join_group(current_setting('pal.direct.invite')::uuid);
    raise exception 'Expected outsider direct invitation rejection';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.send_message(current_setting('pal.direct.id')::uuid,'Intrude',gen_random_uuid());
    raise exception 'Expected outsider direct message rejection';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.pal_group_state(current_setting('pal.direct.id')::uuid);
    raise exception 'Expected outsider direct state rejection';
  exception when insufficient_privilege then null;
  end;
end $$;
select set_config('request.jwt.claim.sub','30000000-0000-4000-8000-000000000003',true);
select set_config('pal.direct.hidden',(public.create_group('HIDDEN_OUTSIDER_GROUP')).id::text,true);
select public.send_message(current_setting('pal.direct.hidden')::uuid,'HIDDEN_OUTSIDER_SECRET',gen_random_uuid());
select set_config('request.jwt.claim.sub','30000000-0000-4000-8000-000000000001',true);
select public.send_message(current_setting('pal.direct.id')::uuid,'Summarize my groups',gen_random_uuid());
do $$
begin
  assert (select run_after=now() and explicit_mention from public.agent_jobs where group_id=current_setting('pal.direct.id')::uuid),'Direct message is immediately eligible without @Pal';
  assert public.pal_group_state(current_setting('pal.direct.id')::uuid)->'pal_activity'->>'activity'='idle','Private queued work is not a chosen reply';
  assert not has_function_privilege('authenticated','public.pal_read_across_groups(uuid,integer,integer,text)','execute'),'Client cannot forge cross-group job scope';
  begin
    delete from public.group_members where group_id=current_setting('pal.direct.id')::uuid;
    raise exception 'Expected direct membership client write denial';
  exception when insufficient_privilege then null;
  end;
end $$;
set local role service_role;
-- Simulate time passing after a valid member-created availability entry.
update public.member_memories set expires_at=now()-interval '1 hour'
where group_id=current_setting('pal.direct.visible')::uuid and key='expired';
select set_config('pal.direct.job',(select id::text from public.claim_agent_jobs(20) where group_id=current_setting('pal.direct.id')::uuid),true);
do $$
declare first_page jsonb; second_page jsonb; filtered jsonb; i jsonb; msg jsonb; previous timestamptz; normal_job uuid;
begin
  begin
    insert into public.group_members(group_id,user_id) values(current_setting('pal.direct.id')::uuid,'30000000-0000-4000-8000-000000000002');
    raise exception 'Expected direct nonowner membership rejection even via service';
  exception when insufficient_privilege then null;
  end;
  first_page:=public.pal_read_across_groups(current_setting('pal.direct.job')::uuid,1);
  second_page:=public.pal_read_across_groups(current_setting('pal.direct.job')::uuid,1,5);
  assert jsonb_array_length(first_page->'groups')=5 and first_page->>'next_offset'='5' and first_page->>'truncated'='true','Context pages only five authorized groups with explicit pagination';
  assert jsonb_array_length(second_page->'groups')=2 and second_page->>'next_offset' is null,'Second page contains the remaining own groups';
  assert not exists(select 1 from jsonb_array_elements(first_page->'groups'||second_page->'groups') g where g->>'id' in (current_setting('pal.direct.id'),current_setting('pal.direct.other_dm'),current_setting('pal.direct.hidden'))),'Context excludes both private chats and outsider groups';
  assert (first_page::text||second_page::text) not like '%OTHER_MEMBER_MEMORY%' and (first_page::text||second_page::text) not like '%OLD_AVAILABILITY%' and (first_page::text||second_page::text) not like '%HIDDEN_OUTSIDER_SECRET%','Context excludes other member memories, expired availability and outsider messages';
  filtered:=public.pal_read_across_groups(current_setting('pal.direct.job')::uuid,1,0,'Visible group 1');
  i:=filtered->'groups'->0;
  assert jsonb_array_length(filtered->'groups')=1 and i->>'id'=current_setting('pal.direct.visible'),'Literal group-name query keeps actor membership scope';
  assert jsonb_array_length(i->'messages')=20 and jsonb_array_length(i->'sources')=10 and i->>'truncated'='true','Per-group recent arrays have explicit bounds';
  assert jsonb_array_length(i->'plans')=1 and jsonb_array_length(i->'places')=1,'Plans and saved spots are available as bounded public context';
  assert jsonb_array_length(i->'memories')=1 and i->'memories'->0->>'user_id'='30000000-0000-4000-8000-000000000001' and i->'memories'->0->>'value_truncated'='true','Only own unexpired memory is returned with value truncation';
  assert i::text not like '%avatar_path%' and i::text not like '%encrypted_refresh_token%' and i::text not like '%invite_code%','Public whitelist exposes no avatar paths, private provider credentials or invitation tokens';
  previous:='-infinity';
  for msg in select value from jsonb_array_elements(i->'messages') loop
    assert length(msg->>'body')<=500,'Message excerpts are bounded';
    assert (msg->>'created_at')::timestamptz>=previous,'Newest selected messages arrive in chronological order';
    previous:=(msg->>'created_at')::timestamptz;
  end loop;
  begin
    perform public.pal_read_across_groups(current_setting('pal.direct.job')::uuid,2);
    raise exception 'Expected stale context attempt rejection';
  exception when insufficient_privilege then null;
  end;
  update public.agent_jobs set lease_until=now()-interval '1 second' where id=current_setting('pal.direct.job')::uuid;
  begin
    perform public.pal_read_across_groups(current_setting('pal.direct.job')::uuid,1);
    raise exception 'Expected expired context lease rejection';
  exception when insufficient_privilege then null;
  end;
  update public.agent_jobs set lease_until=now()+interval '5 minutes' where id=current_setting('pal.direct.job')::uuid;
  delete from public.group_members where group_id=current_setting('pal.direct.visible')::uuid and user_id='30000000-0000-4000-8000-000000000001';
  filtered:=public.pal_read_across_groups(current_setting('pal.direct.job')::uuid,1,0,'Visible group 1');
  assert jsonb_array_length(filtered->'groups')=0,'Removed memberships immediately remove old group context and memory';
  select id into normal_job from public.agent_jobs where group_id=current_setting('pal.direct.hidden')::uuid limit 1;
  update public.agent_jobs set status='running',attempts=1,lease_until=now()+interval '5 minutes' where id=normal_job;
  begin
    perform public.pal_read_across_groups(normal_job,1);
    raise exception 'Expected ordinary shared-group context capability rejection';
  exception when insufficient_privilege then null;
  end;
end $$;
rollback;
