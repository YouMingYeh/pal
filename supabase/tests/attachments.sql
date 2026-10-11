-- Dedicated test database only. Media metadata, message/job rows and fixtures roll back.
begin;
insert into auth.users(id,email) values
 ('80000000-0000-4000-8000-000000000001','pal-media-a@example.invalid'),
 ('80000000-0000-4000-8000-000000000002','pal-media-b@example.invalid'),
 ('80000000-0000-4000-8000-000000000003','pal-media-outsider@example.invalid');
create function pg_temp.media(p_group uuid,p_user uuid,p_client uuid,p_path text,p_hash text default repeat('a',64),p_kind text default 'image',p_body text default null,p_reply uuid default null,p_duration integer default null) returns jsonb language sql as $$
  select public.send_attachment(p_group,p_user,p_client,p_path,p_kind,case when p_kind='image' then 'image/jpeg' else 'audio/mp4' end,1000,
    case when p_kind='image' then 640 else null end,case when p_kind='image' then 480 else null end,p_duration,p_hash,p_body,p_reply)
$$;
create policy media_test_permissive_objects on storage.objects for all to authenticated using(true) with check(true);
set local role authenticated;
select set_config('request.jwt.claim.sub','80000000-0000-4000-8000-000000000001',true);
select set_config('pal.media.group',(public.create_group('Media group')).id::text,true);
select set_config('pal.media.invite',(select invite_code::text from public.groups where id=current_setting('pal.media.group')::uuid),true);
select set_config('pal.media.text',(public.send_message(current_setting('pal.media.group')::uuid,'Text already sent','81000000-0000-4000-8000-000000000003')).id::text,true);
select set_config('request.jwt.claim.sub','80000000-0000-4000-8000-000000000002',true);
select public.join_group(current_setting('pal.media.invite')::uuid);
select set_config('request.jwt.claim.sub','80000000-0000-4000-8000-000000000003',true);
select set_config('pal.media.other_group',(public.create_group('Other group')).id::text,true);
select set_config('pal.media.other_message',(public.send_message(current_setting('pal.media.other_group')::uuid,'Other group text','81000000-0000-4000-8000-000000000009')).id::text,true);
set local role service_role;
do $$
declare r jsonb; replay jsonb; base text:=current_setting('pal.media.group')||'/80000000-0000-4000-8000-000000000001/'; before_messages bigint; before_jobs bigint; previous_sub text:=current_setting('request.jwt.claim.sub');
begin
  assert (select not public and file_size_limit=4194304 and allowed_mime_types=array['image/jpeg','audio/mp4'] from storage.buckets where id='message-attachments'),'Private media bucket enforces 4 MiB and supported formats';
  r:=pg_temp.media(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000001',base||'82000000-0000-4000-8000-000000000001.jpg');
  perform set_config('pal.media.message',r->'message'->>'id',true);
  assert r->'message'->>'sender_id'='80000000-0000-4000-8000-000000000001','Message actor is the verified requester';
  assert r->'attachment'->>'message_id'=r->'message'->>'id' and r->>'uploaded_path_used'='true','Attachment and message persist atomically';
  assert current_setting('request.jwt.claim.sub')=previous_sub,'Scoped send restores the original JWT subject';
  replay:=pg_temp.media(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000001',base||'82000000-0000-4000-8000-000000000002.jpg');
  assert replay->'attachment'=r->'attachment' and replay->'message'=r->'message' and replay->>'uploaded_path_used'='false','Retry returns original rows and identifies the unused uploaded blob';
  assert (select count(*)=1 from public.agent_jobs where message_id=(r->'message'->>'id')::uuid),'Retry never duplicates agent work';
  before_messages:=(select count(*) from public.messages); before_jobs:=(select count(*) from public.agent_jobs);
  begin
    perform pg_temp.media(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000001',base||'82000000-0000-4000-8000-000000000002.jpg',repeat('b',64));
    raise exception 'Expected different file retry rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform pg_temp.media(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000001',base||'82000000-0000-4000-8000-000000000002.jpg',p_body=>'Different caption');
    raise exception 'Expected changed caption retry rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform pg_temp.media(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000001',base||'82000000-0000-4000-8000-000000000002.jpg',p_reply=>current_setting('pal.media.text')::uuid);
    raise exception 'Expected changed reply retry rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform pg_temp.media(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000003',base||'82000000-0000-4000-8000-000000000003.jpg',p_body=>'Text already sent');
    raise exception 'Expected existing text-only client ID rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform pg_temp.media(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000003','81000000-0000-4000-8000-000000000004',base||'82000000-0000-4000-8000-000000000004.jpg');
    raise exception 'Expected nonmember requester rejection';
  exception when insufficient_privilege then null;
  end;
  begin
    perform pg_temp.media(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000004',current_setting('pal.media.other_group')||'/80000000-0000-4000-8000-000000000001/82000000-0000-4000-8000-000000000004.jpg');
    raise exception 'Expected cross-group storage path rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform pg_temp.media(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000004',base||'82000000-0000-4000-8000-000000000004.jpg',p_reply=>current_setting('pal.media.other_message')::uuid);
    raise exception 'Expected cross-group reply rejection';
  exception when insufficient_privilege then null;
  end;
  assert current_setting('request.jwt.claim.sub')=previous_sub,'Failed scoped send restores original JWT subject';
  begin
    perform public.send_attachment(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000004',base||'82000000-0000-4000-8000-000000000004.jpg','image','image/jpeg',4194305,640,480,null,repeat('a',64));
    raise exception 'Expected oversized media rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform pg_temp.media(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000004',base||'82000000-0000-4000-8000-000000000001.jpg');
    raise exception 'Expected storage object reuse rejection';
  exception when unique_violation then null;
  end;
  assert (select count(*)=before_messages from public.messages) and (select count(*)=before_jobs from public.agent_jobs),'Failed attachment insertion rolls back message and agent work';
  begin
    perform pg_temp.media(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000005',base||'82000000-0000-4000-8000-000000000005.m4a',p_kind=>'audio',p_duration=>60001);
    raise exception 'Expected overlong recording rejection';
  exception when invalid_parameter_value then null;
  end;
  r:=pg_temp.media(current_setting('pal.media.group')::uuid,'80000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000005',base||'82000000-0000-4000-8000-000000000005.m4a',p_kind=>'audio',p_duration=>60000);
  assert r->'attachment'->>'duration_ms'='60000' and r->'message'->>'body'='Voice message','60-second voice message stores playable metadata';
  insert into storage.objects(bucket_id,name) values('message-attachments',base||'82000000-0000-4000-8000-000000000001.jpg');
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','80000000-0000-4000-8000-000000000002',true);
do $$
begin
  assert (select count(*)=2 from public.message_attachments where group_id=current_setting('pal.media.group')::uuid),'Current group member reads both persisted attachments';
  assert not exists(select 1 from storage.objects where bucket_id='message-attachments'),'Group membership never grants direct private blob access';
  assert not has_function_privilege('authenticated','public.send_attachment(uuid,uuid,uuid,text,text,text,bigint,integer,integer,integer,text,text,uuid)','execute'),'Clients cannot spoof attachment requesters';
  begin
    delete from public.message_attachments where group_id=current_setting('pal.media.group')::uuid;
    raise exception 'Expected member attachment write rejection';
  exception when insufficient_privilege then null;
  end;
end $$;
select set_config('request.jwt.claim.sub','80000000-0000-4000-8000-000000000003',true);
do $$
begin
  assert not exists(select 1 from public.message_attachments where group_id=current_setting('pal.media.group')::uuid),'Other group cannot read attachments';
end $$;
set local role anon;
do $$
begin
  assert not has_function_privilege('anon',(select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and p.proname='send_attachment'),'execute'),'Signed-out clients cannot invoke private media send';
end $$;
rollback;
