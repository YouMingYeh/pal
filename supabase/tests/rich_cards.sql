-- Dedicated test database only. Rich group cards and response fixtures roll back.
begin;
insert into auth.users(id,email) values
 ('90000000-0000-4000-8000-000000000001','pal-rich-owner@example.invalid'),
 ('90000000-0000-4000-8000-000000000002','pal-rich-member@example.invalid'),
 ('90000000-0000-4000-8000-000000000003','pal-rich-unknown@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','90000000-0000-4000-8000-000000000001',true);
select set_config('pal.rich.group',(public.create_group('Rich cards')).id::text,true);
select set_config('pal.rich.invite',(select invite_code::text from public.groups where id=current_setting('pal.rich.group')::uuid),true);
select set_config('pal.rich.plan',(public.pal_action(current_setting('pal.rich.group')::uuid,'plan.create',jsonb_build_object('title','Dinner draft','starts_at',now()+interval '2 days')))->>'id',true);
select set_config('pal.rich.options',(public.pal_action(current_setting('pal.rich.group')::uuid,'poll.create',jsonb_build_object('kind','place','question','Ideas for us','options','[{"id":"walk","label":"River walk"},{"id":"museum","label":"Museum afternoon"}]'::jsonb,'deadline_at',now()+interval '1 day')))->>'id',true);
select set_config('pal.rich.availability',(public.pal_action(current_setting('pal.rich.group')::uuid,'poll.create',jsonb_build_object('kind','time','question','When works?','options',jsonb_build_array(jsonb_build_object('id','fri','label','Friday','starts_at',now()+interval '2 days'),jsonb_build_object('id','sat','label','Saturday','starts_at',now()+interval '3 days')),'deadline_at',now()+interval '1 day')))->>'id',true);
select set_config('pal.rich.source',(public.send_message(current_setting('pal.rich.group')::uuid,'Friday after seven works for me',gen_random_uuid())).id::text,true);
select public.pal_action(current_setting('pal.rich.group')::uuid,'memory.save',jsonb_build_object('kind','availability','key','This weekend','value','Friday after seven','source_message_id',current_setting('pal.rich.source'),'expires_at',now()+interval '4 days'));
select set_config('pal.rich.other_group',(public.create_group('Other rich group')).id::text,true);
select set_config('pal.rich.other_poll',(public.pal_action(current_setting('pal.rich.other_group')::uuid,'poll.create',jsonb_build_object('kind','place','question','Private ideas','options','[{"id":"a","label":"A"},{"id":"b","label":"B"}]'::jsonb,'deadline_at',now()+interval '1 day')))->>'id',true);
select set_config('request.jwt.claim.sub','90000000-0000-4000-8000-000000000002',true);
select public.join_group(current_setting('pal.rich.invite')::uuid);
select public.pal_action(current_setting('pal.rich.group')::uuid,'poll.vote',jsonb_build_object('id',current_setting('pal.rich.availability'),'option_ids','[]'::jsonb));
select set_config('request.jwt.claim.sub','90000000-0000-4000-8000-000000000003',true);
select public.join_group(current_setting('pal.rich.invite')::uuid);
set local role service_role;
create function pg_temp.rich_outputs(p_cards jsonb) returns uuid language plpgsql as $$
declare source_id uuid; job_id uuid; outputs jsonb;
begin
  insert into public.messages(group_id,sender_id,role,body) values(current_setting('pal.rich.group')::uuid,'90000000-0000-4000-8000-000000000001','user','Please show our group cards') returning id into source_id;
  insert into public.agent_jobs(group_id,message_id,requester_id,status,attempts,lease_until,batch_message_ids)
    values(current_setting('pal.rich.group')::uuid,source_id,'90000000-0000-4000-8000-000000000001','running',1,now()+interval '5 minutes',array[source_id]) returning id into job_id;
  select jsonb_agg(jsonb_build_object('body','Our group options','card',card) order by n) into outputs from jsonb_array_elements(p_cards) with ordinality x(card,n);
  assert public.complete_agent_job_with_outputs(job_id,1,outputs),'Valid rich card outputs complete';
  return job_id;
end $$;
create function pg_temp.reject_rich(p_state text,p_cards jsonb) returns void language plpgsql as $$
begin
  begin perform pg_temp.rich_outputs(p_cards);
  exception when others then if sqlstate=p_state then return; end if; raise; end;
  raise exception 'Expected rich card rejection %',p_state;
end $$;
do $$
declare j uuid; s jsonb; n integer; options_id uuid:=current_setting('pal.rich.options')::uuid; availability uuid:=current_setting('pal.rich.availability')::uuid; plan uuid:=current_setting('pal.rich.plan')::uuid;
begin
  j:=pg_temp.rich_outputs(jsonb_build_array(jsonb_build_object('type','plan','entity_id',plan),jsonb_build_object('type','options','entity_id',options_id),jsonb_build_object('type','availability','entity_id',availability)));
  assert (select count(*)=3 from public.messages where source_key in ('job:'||j,'job:'||j||':part:2','job:'||j||':part:3')),'Three ordered rich bubbles reference persisted entities';
  assert (select card->>'type'='plan' and card->>'entity_id'=plan::text from public.messages where source_key='job:'||j),'Future draft plan details do not imply confirmation';
  assert (select status='draft' from public.plans where id=plan),'Displaying details never confirms a draft';
  assert (select card->>'type'='options' from public.messages where source_key='job:'||j||':part:2'),'Options alias is retained for native rendering';
  assert (select options->0->>'place_id' is null from public.polls where id=options_id),'Activity inspiration needs no invented saved place';
  perform pg_temp.rich_outputs(jsonb_build_array(jsonb_build_object('type','choice','entity_id',options_id)));
  s:=public.pal_group_state(current_setting('pal.rich.group')::uuid);
  assert (select jsonb_array_length(p->'responses')=1 and p->'responses'->0->'option_ids'='[]'::jsonb from jsonb_array_elements(s->'polls') p where p->>'id'=availability::text),'Explicit no-time response remains distinct from unknown';
  assert not exists(select 1 from public.poll_responses where poll_id=availability and user_id='90000000-0000-4000-8000-000000000003'),'Unanswered member schedule remains unknown';
  assert (select count(*)=1 from public.member_memories where group_id=current_setting('pal.rich.group')::uuid and kind='availability'),'Only actually stated member availability is stored';
  assert not exists(select 1 from public.plan_rsvps where plan_id=plan),'Showing any rich cards invents no attendance';
  perform pg_temp.reject_rich('42501',jsonb_build_array(jsonb_build_object('type','rsvp','entity_id',plan)));
  perform pg_temp.reject_rich('42501',jsonb_build_array(jsonb_build_object('type','options','entity_id',availability)));
  perform pg_temp.reject_rich('42501',jsonb_build_array(jsonb_build_object('type','availability','entity_id',options_id)));
  perform pg_temp.reject_rich('42501',jsonb_build_array(jsonb_build_object('type','options','entity_id',current_setting('pal.rich.other_poll'))));
  perform pg_temp.reject_rich('22023','[{"type":"options","entity_id":"00000000-0000-4000-8000-000000000000","responses":[{"user_id":"90000000-0000-4000-8000-000000000003","status":"free"}]}]');
  n:=(select count(*) from public.messages where group_id=current_setting('pal.rich.group')::uuid);
  perform pg_temp.reject_rich('42501',jsonb_build_array(jsonb_build_object('type','plan','entity_id',plan),jsonb_build_object('type','options','entity_id',current_setting('pal.rich.other_poll'))));
  assert (select count(*)=n from public.messages where group_id=current_setting('pal.rich.group')::uuid),'Invalid second rich card rolls back all outputs';
  update public.polls set status='closed' where id=options_id;
  perform pg_temp.reject_rich('42501',jsonb_build_array(jsonb_build_object('type','options','entity_id',options_id)));
  assert exists(select 1 from public.messages where source_key='job:'||j||':part:2'),'Existing closed card remains a persisted historical snapshot';
  update public.polls set status='open',deadline_at=now()-interval '1 second' where id=options_id;
  perform pg_temp.reject_rich('42501',jsonb_build_array(jsonb_build_object('type','choice','entity_id',options_id)));
  update public.plans set status='confirmed' where id=plan;
  perform pg_temp.rich_outputs(jsonb_build_array(jsonb_build_object('type','plan','entity_id',plan),jsonb_build_object('type','rsvp','entity_id',plan)));
  update public.plans set status='cancelled' where id=plan;
  perform pg_temp.reject_rich('42501',jsonb_build_array(jsonb_build_object('type','plan','entity_id',plan)));
  update public.plans set status='confirmed',starts_at=now()-interval '1 second' where id=plan;
  perform pg_temp.reject_rich('42501',jsonb_build_array(jsonb_build_object('type','rsvp','entity_id',plan)));
end $$;
rollback;
