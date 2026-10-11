begin;
insert into auth.users(id,email) values('c1000000-0000-4000-8000-000000000001','source-reply@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','c1000000-0000-4000-8000-000000000001',true);
select set_config('pal.source.group',(public.create_group('Source reply fixture')).id::text,true);
select public.send_message(current_setting('pal.source.group')::uuid,'https://www.instagram.com/reel/source-fixture/',gen_random_uuid());
do $$ begin
 assert (select count(*)=1 from public.messages where group_id=current_setting('pal.source.group')::uuid),'Pending extraction posts only the real human message';
 assert (select count(*)=1 from public.sources where group_id=current_setting('pal.source.group')::uuid),'Silent sharing still queues extraction';
 begin
  perform public.pal_complete_source((select id from public.sources where group_id=current_setting('pal.source.group')::uuid),'{}');
  raise exception 'Expected service-only completion';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
update public.sources set status='resolving',attempts=1 where group_id=current_setting('pal.source.group')::uuid;
set local role service_role;
do $$
declare source uuid; response jsonb; n integer;
begin
 select id into source from public.sources where group_id=current_setting('pal.source.group')::uuid;
 response:=jsonb_build_object('status','needs_confirmation','expected_attempt',1,'title','Cafe reel','candidates','[{"name":"Cafe","city":"San Francisco"}]'::jsonb,
  'reply',jsonb_build_object('body','Looks like Cafe in SF. Which branch did you mean?','emotion','curieux'));
 perform public.pal_complete_source(source,response||jsonb_build_object('expected_attempt',2));
 assert (select count(*)=1 from public.messages where group_id=current_setting('pal.source.group')::uuid),'A stale extraction cannot announce a result';
 perform public.pal_complete_source(source,response);
 assert (select count(*)=1 from public.messages where source_key='pal:source:'||source),'Completed extraction posts exactly one short real result';
 assert (select emotion='curieux' and reply_to_id=(select source_message_id from public.sources where id=source) from public.messages where source_key='pal:source:'||source),'Result retains emotion and references the actual shared message';
 perform public.pal_complete_source(source,response);
 assert (select count(*)=1 from public.messages where source_key='pal:source:'||source),'Completion retries never duplicate Pal';
 perform private.pal_source_reply(source,1,response->'reply');
 assert (select count(*)=1 from public.messages where source_key='pal:source:'||source),'An idempotent result cannot post again';
end $$;
rollback;
