-- Dedicated test database only. Ordinary messages create prompt, coalesced work without @Pal.
begin;
insert into auth.users(id,email) values ('b4000000-0000-4000-8000-000000000001','pal-fast-chat@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','b4000000-0000-4000-8000-000000000001',true);
select set_config('pal.fast.group',(public.create_group('Dinner friends')).id::text,true);
select set_config('pal.fast.first',(public.send_message(current_setting('pal.fast.group')::uuid,'Friday dinner anyone?',gen_random_uuid())).id::text,true);
select set_config('pal.fast.second',(public.send_message(current_setting('pal.fast.group')::uuid,'Somewhere vegetarian-friendly would be good.',gen_random_uuid())).id::text,true);
do $$ begin
  assert (select count(*)=2 from public.agent_jobs where group_id=current_setting('pal.fast.group')::uuid and not explicit_mention and run_after=now()+interval '3 seconds'),'Every normal human message queues work after the same short burst deadline';
end $$;
reset role;
update public.agent_jobs set run_after=now()-interval '1 second' where group_id=current_setting('pal.fast.group')::uuid;
set local role service_role;
select set_config('pal.fast.job',(select id::text from public.claim_agent_jobs(20) where group_id=current_setting('pal.fast.group')::uuid),true);
do $$ begin
  assert (select not explicit_mention and cardinality(batch_message_ids)=2 from public.agent_jobs where id=current_setting('pal.fast.job')::uuid),'Untagged messages become one running job with both verified sources';
  assert (select count(*)=1 from public.agent_jobs where group_id=current_setting('pal.fast.group')::uuid and status='coalesced'),'The burst remains one conversation turn';
  assert public.complete_agent_job_with_outputs(current_setting('pal.fast.job')::uuid,1,'[]'::jsonb),'Useful observation can still finish silently';
  assert not exists(select 1 from public.messages where group_id=current_setting('pal.fast.group')::uuid and role='pal'),'Queueing does not force Pal to reply';
end $$;
set local role authenticated;
select set_config('pal.fast.tagged',(public.send_message(current_setting('pal.fast.group')::uuid,'@Pal help us find dinner',gen_random_uuid())).id::text,true);
do $$ begin
  assert (select explicit_mention and run_after=now() from public.agent_jobs where message_id=current_setting('pal.fast.tagged')::uuid),'Direct requests stay immediate';
end $$;
select set_config('pal.fast.direct',(public.ensure_pal_direct()).id::text,true);
select set_config('pal.fast.dm',(public.send_message(current_setting('pal.fast.direct')::uuid,'Hi',gen_random_uuid())).id::text,true);
do $$ begin
  assert (select explicit_mention and run_after=now() from public.agent_jobs where message_id=current_setting('pal.fast.dm')::uuid),'Private Pal messages stay immediate';
end $$;
rollback;
