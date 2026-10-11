begin;
insert into auth.users(id,email) values
 ('80000000-0000-4000-8000-000000000001','pal-output-owner@example.invalid'),
 ('80000000-0000-4000-8000-000000000002','pal-output-member@example.invalid'),
 ('80000000-0000-4000-8000-000000000003','pal-output-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','80000000-0000-4000-8000-000000000001',true);
select set_config('pal.output.group',(public.create_group('Conversation output')).id::text,true);
select set_config('pal.output.invite',(select invite_code::text from public.groups where id=current_setting('pal.output.group')::uuid),true);
select set_config('pal.output.plan',(public.pal_action(current_setting('pal.output.group')::uuid,'plan.create',jsonb_build_object('title','Dinner','starts_at',now()+interval '2 days')))->>'id',true);
select public.pal_action(current_setting('pal.output.group')::uuid,'plan.confirm',jsonb_build_object('id',current_setting('pal.output.plan')));
select set_config('pal.output.draft',(public.pal_action(current_setting('pal.output.group')::uuid,'plan.create',jsonb_build_object('title','Unconfirmed dinner','starts_at',now()+interval '3 days')))->>'id',true);
select set_config('request.jwt.claim.sub','80000000-0000-4000-8000-000000000002',true);
select public.join_group(current_setting('pal.output.invite')::uuid);
select set_config('pal.output.source',(public.send_message(current_setting('pal.output.group')::uuid,'Can you help?', '81000000-0000-4000-8000-000000000001',null,'[{"type":"pal"},{"type":"user","user_id":"80000000-0000-4000-8000-000000000001"}]')).id::text,true);
do $$
declare m public.messages;
begin
  m:=public.send_message(current_setting('pal.output.group')::uuid,'Can you help?','81000000-0000-4000-8000-000000000001',null,'[{"type":"user","user_id":"80000000-0000-4000-8000-000000000001"},{"type":"pal"}]');
  assert m.id=current_setting('pal.output.source')::uuid and jsonb_array_length(m.mentions)=2,'Canonical mention order makes human retries idempotent';
  assert (select explicit_mention and run_after=now() from public.agent_jobs where message_id=m.id),'Structured Pal mention is immediate without requiring literal text';
  begin
    perform public.send_message(m.group_id,m.body,m.client_id,null,'[]');
    raise exception 'Expected changed retry mentions rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.send_message(m.group_id,'Hello',gen_random_uuid(),null,'[{"type":"user","user_id":"80000000-0000-4000-8000-000000000003"}]');
    raise exception 'Expected outsider mention rejection';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.send_message(m.group_id,'Hello',gen_random_uuid(),null,'[{"type":"pal"},{"type":"pal"}]');
    raise exception 'Expected duplicate mention rejection';
  exception when invalid_parameter_value then null;
  end;
end $$;
select set_config('request.jwt.claim.sub','80000000-0000-4000-8000-000000000003',true);
select set_config('pal.output.other_group',(public.create_group('Other private fixture')).id::text,true);
select set_config('pal.output.other_message',(public.send_message(current_setting('pal.output.other_group')::uuid,'Private note',gen_random_uuid())).id::text,true);
set local role service_role;
insert into public.messages(group_id,role,body) values(current_setting('pal.output.group')::uuid,'pal','Previous Pal reply');
select set_config('pal.output.pal_message',(select id::text from public.messages where group_id=current_setting('pal.output.group')::uuid and role='pal' and body='Previous Pal reply'),true);
insert into public.messages(group_id,role,body) values(current_setting('pal.output.group')::uuid,'system','Internal trigger');
select set_config('pal.output.system_message',(select id::text from public.messages where group_id=current_setting('pal.output.group')::uuid and role='system' and body='Internal trigger'),true);
set local role authenticated;
select set_config('request.jwt.claim.sub','80000000-0000-4000-8000-000000000002',true);
select public.send_message(current_setting('pal.output.group')::uuid,'Thanks',gen_random_uuid(),current_setting('pal.output.pal_message')::uuid,'[]');
do $$
begin
  assert (select j.explicit_mention and j.run_after=now() from public.agent_jobs j join public.messages m on m.id=j.message_id where m.group_id=current_setting('pal.output.group')::uuid and m.body='Thanks'),'A human reply to Pal addresses it immediately without another mention';
  begin
    perform public.send_message(current_setting('pal.output.group')::uuid,'Foreign quote',gen_random_uuid(),current_setting('pal.output.other_message')::uuid,'[]');
    raise exception 'Expected cross-group reply rejection';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.send_message(current_setting('pal.output.group')::uuid,'System quote',gen_random_uuid(),current_setting('pal.output.system_message')::uuid,'[]');
    raise exception 'Expected system reply rejection';
  exception when insufficient_privilege then null;
  end;
end $$;
set local role service_role;
select set_config('pal.output.job',(select id::text from public.claim_agent_jobs(20) where group_id=current_setting('pal.output.group')::uuid),true);
create function pg_temp.output(p_outputs jsonb,p_attempt integer default 1) returns boolean language sql as $$
  select public.complete_agent_job_with_outputs(current_setting('pal.output.job')::uuid,p_attempt,p_outputs)
$$;
create function pg_temp.reject_output(p_state text,p_outputs jsonb) returns void language plpgsql as $$
begin
  begin perform pg_temp.output(p_outputs);
  exception when others then if sqlstate=p_state then return; end if; raise; end;
  raise exception 'Expected output error %',p_state;
end $$;
do $$
declare j uuid:=current_setting('pal.output.job')::uuid; outputs jsonb; n integer; r jsonb; member_mentions jsonb:='[{"type":"user","user_id":"80000000-0000-4000-8000-000000000002"}]';
begin
  assert not has_function_privilege('authenticated','public.complete_agent_job_with_outputs(uuid,integer,jsonb,text)','execute'),'Humans cannot publish Pal outputs';
  assert not pg_temp.output('[{"body":"Wrong attempt"}]',2),'Stale completion cannot publish';
  update public.agent_jobs set lease_until=now()-interval '1 second' where id=j;
  assert not pg_temp.output('[{"body":"Expired output"}]'),'Expired output lease cannot publish';
  update public.agent_jobs set lease_until=now()+interval '5 minutes' where id=j;
  update public.groups set agent_paused=true where id=current_setting('pal.output.group')::uuid;
  assert not pg_temp.output('[{"body":"Paused output"}]'),'Paused group cannot publish output sets';
  update public.groups set agent_paused=false where id=current_setting('pal.output.group')::uuid;
  n:=(select count(*) from public.messages where group_id=current_setting('pal.output.group')::uuid);
  perform pg_temp.reject_output('42501',jsonb_build_array(jsonb_build_object('body','First valid'),jsonb_build_object('body','Forbidden','mentions',jsonb_build_array(jsonb_build_object('type','user','user_id','80000000-0000-4000-8000-000000000003')))));
  assert (select count(*)=n from public.messages where group_id=current_setting('pal.output.group')::uuid),'Invalid second output rolls back the entire message set';
  perform pg_temp.reject_output('22023','[{"body":"Hi","mentions":[{"type":"pal"}]}]');
  perform pg_temp.reject_output('22023','[{"body":"A"},{"body":"B"},{"body":"C"},{"body":"D"}]');
  perform pg_temp.reject_output('22023',jsonb_build_array(jsonb_build_object('body',repeat('a',3000)),jsonb_build_object('body',repeat('b',1001))));
  perform pg_temp.reject_output('42501',jsonb_build_array(jsonb_build_object('body','Foreign quote','reply_to_id',current_setting('pal.output.other_message'))));
  perform pg_temp.reject_output('42501',jsonb_build_array(jsonb_build_object('body','System quote','reply_to_id',current_setting('pal.output.system_message'))));
  perform pg_temp.reject_output('42501',jsonb_build_array(jsonb_build_object('body','Please RSVP','card',jsonb_build_object('type','rsvp','entity_id',current_setting('pal.output.draft')))));
  perform pg_temp.reject_output('22023',jsonb_build_array(jsonb_build_object('body','Choose','card',jsonb_build_object('type','invented','entity_id',current_setting('pal.output.plan')))));
  outputs:=jsonb_build_array(jsonb_build_object('body','First reply','emotion','heureux','reply_to_id',current_setting('pal.output.source'),'mentions',member_mentions),jsonb_build_object('body','Please RSVP','reply_to_id',current_setting('pal.output.pal_message'),'card',jsonb_build_object('type','rsvp','entity_id',current_setting('pal.output.plan'))));
  assert pg_temp.output(outputs),'Two ordered Pal outputs commit atomically';
  assert (select count(*)=2 from public.messages where source_key in ('job:'||j,'job:'||j||':part:2')),'Exactly two durable unique Pal bubbles exist';
  assert (select body='First reply' and emotion='heureux' and reply_to_id=current_setting('pal.output.source')::uuid and mentions=member_mentions from public.messages where source_key='job:'||j),'First output preserves targeted human reply and mention';
  assert (select body='Please RSVP' and card->>'type'='rsvp' and card->>'entity_id'=current_setting('pal.output.plan') and emotion='fier' from public.messages where source_key='job:'||j||':part:2'),'RSVP references the actual persisted confirmed plan';
  assert (select a.created_at<b.created_at from public.messages a join public.messages b on b.source_key='job:'||j||':part:2' where a.source_key='job:'||j),'Message ordering is deterministic';
  assert not pg_temp.output(outputs),'Completed retry cannot duplicate bubbles';
  assert (select count(*)=2 from public.agent_jobs where group_id=current_setting('pal.output.group')::uuid),'Pal multi-output does not create self-loops';
  r:=public.send_attachment_with_mentions(current_setting('pal.output.group')::uuid,'80000000-0000-4000-8000-000000000002','81000000-0000-4000-8000-000000000002',current_setting('pal.output.group')||'/80000000-0000-4000-8000-000000000002/82000000-0000-4000-8000-000000000001.jpg','image','image/jpeg',100,100,100,null,repeat('a',64),member_mentions,'Photo for you',current_setting('pal.output.source')::uuid);
  assert r->'message'->'mentions'=member_mentions and r->'message'->>'reply_to_id'=current_setting('pal.output.source'),'Attachment caption retains real mentions and reply reference';
  r:=public.send_attachment_with_mentions(current_setting('pal.output.group')::uuid,'80000000-0000-4000-8000-000000000002','81000000-0000-4000-8000-000000000002',current_setting('pal.output.group')||'/80000000-0000-4000-8000-000000000002/82000000-0000-4000-8000-000000000002.jpg','image','image/jpeg',100,100,100,null,repeat('a',64),member_mentions,'Photo for you',current_setting('pal.output.source')::uuid);
  assert r->>'uploaded_path_used'='false','Attachment mention retry reuses the original blob/message';
  begin
    perform public.send_attachment_with_mentions(current_setting('pal.output.group')::uuid,'80000000-0000-4000-8000-000000000002','81000000-0000-4000-8000-000000000002',current_setting('pal.output.group')||'/80000000-0000-4000-8000-000000000002/82000000-0000-4000-8000-000000000002.jpg','image','image/jpeg',100,100,100,null,repeat('a',64),'[]','Photo for you',current_setting('pal.output.source')::uuid);
    raise exception 'Expected attachment retry target mismatch';
  exception when invalid_parameter_value then null;
  end;
  update public.agent_jobs set run_after=now() where group_id=current_setting('pal.output.group')::uuid and status='queued';
  select id into j from public.claim_agent_jobs(20) where group_id=current_setting('pal.output.group')::uuid;
  n:=(select count(*) from public.messages where group_id=current_setting('pal.output.group')::uuid);
  assert public.complete_agent_job_with_outputs(j,1,'[]'),'Empty outputs preserve selective silence';
  assert (select count(*)=n from public.messages where group_id=current_setting('pal.output.group')::uuid),'Silent output set adds no bubble';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','80000000-0000-4000-8000-000000000002',true);
do $$
declare r jsonb;
begin
  r:=public.pal_action(current_setting('pal.output.group')::uuid,'message.reply',jsonb_build_object('body','Follow up','client_id','81000000-0000-4000-8000-000000000003','reply_to_id',current_setting('pal.output.pal_message'),'mentions','[{"type":"pal"}]'::jsonb,'source_key','reply-with-mention'));
  assert r->'mentions'='[{"type":"pal"}]'::jsonb and r->>'reply_to_id'=current_setting('pal.output.pal_message'),'Existing reply action forwards real mention targets';
  assert (select explicit_mention and run_after=now() from public.agent_jobs where message_id=(r->>'id')::uuid),'Mentioned Pal reply action wakes immediately';
end $$;
rollback;
