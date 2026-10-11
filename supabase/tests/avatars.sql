-- Dedicated test database only. Storage fixtures and profile changes roll back.
begin;
insert into auth.users(id,email) values
 ('90000000-0000-4000-8000-000000000001','pal-avatar-owner@example.invalid'),
 ('90000000-0000-4000-8000-000000000002','pal-avatar-member@example.invalid'),
 ('90000000-0000-4000-8000-000000000003','pal-avatar-outsider@example.invalid');
-- A broad unrelated policy must still not expose this bucket.
create policy avatar_test_permissive_objects on storage.objects for all to authenticated using(true) with check(true);
create policy avatar_test_permissive_buckets on storage.buckets for all to authenticated using(true) with check(true);
do $$
begin
  assert (select not public and file_size_limit=5242880 and allowed_mime_types=array['image/jpeg'] from storage.buckets where id='avatars'),'Private avatar bucket restricts stored JPEGs to 5 MiB';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','90000000-0000-4000-8000-000000000001',true);
select set_config('pal.avatar.group',(public.create_group('Avatar tests')).id::text,true);
select set_config('pal.avatar.invite',(select invite_code::text from public.groups where id=current_setting('pal.avatar.group')::uuid),true);
select public.pal_profile_save('{"display_name":"Owner","avatar_url":"https://example.invalid/legacy.jpg"}');
set local role service_role;
do $$
declare r jsonb;
begin
  r:=public.pal_avatar_replace('90000000-0000-4000-8000-000000000001','90000000-0000-4000-8000-000000000001/91000000-0000-4000-8000-000000000001.jpg');
  assert r->>'previous_path' is null and r->'profile'->>'avatar_url' is null,'First upload clears legacy URL without inventing an old object';
  r:=public.pal_avatar_replace('90000000-0000-4000-8000-000000000001','90000000-0000-4000-8000-000000000001/91000000-0000-4000-8000-000000000002.jpg','Owner photo saved');
  assert r->'profile'->>'display_name'='Owner photo saved','Name and photo save atomically';
  assert r->>'previous_path'='90000000-0000-4000-8000-000000000001/91000000-0000-4000-8000-000000000001.jpg','Replacement returns the previous path for safe object cleanup';
  begin
    perform public.pal_avatar_replace('90000000-0000-4000-8000-000000000001','90000000-0000-4000-8000-000000000002/91000000-0000-4000-8000-000000000002.jpg');
    raise exception 'Expected cross-owner avatar path rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.pal_avatar_replace('90000000-0000-4000-8000-000000000001',null,'   ');
    raise exception 'Expected blank avatar display name rejection';
  exception when invalid_parameter_value then null;
  end;
  assert (select avatar_path is not null and display_name='Owner photo saved' from public.profiles where user_id='90000000-0000-4000-8000-000000000001'),'Invalid name/photo operation preserves the current profile';
  insert into storage.objects(bucket_id,name) values('avatars','90000000-0000-4000-8000-000000000001/91000000-0000-4000-8000-000000000002.jpg');
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','90000000-0000-4000-8000-000000000002',true);
select public.join_group(current_setting('pal.avatar.invite')::uuid);
do $$
begin
  assert not has_function_privilege('authenticated','public.pal_avatar_replace(uuid,text,text)','execute'),'Members cannot impersonate upload owner';
  assert not has_function_privilege('anon','private.pal_avatar_replace(uuid,text,text)','execute'),'Signed-out clients cannot bypass the public wrapper';
  assert (select count(*)=0 from storage.objects where bucket_id='avatars'),'Even group members cannot read private avatar objects directly';
  assert (select count(*)=0 from storage.buckets where id='avatars'),'Broad bucket policies cannot expose private avatar metadata';
  assert exists(select 1 from jsonb_array_elements(public.pal_group_state(current_setting('pal.avatar.group')::uuid)->'members') m where m->>'user_id'='90000000-0000-4000-8000-000000000001' and m->>'avatar_path' is not null),'Authorized group state supplies the path for backend signing';
  begin
    insert into storage.objects(bucket_id,name) values('avatars','90000000-0000-4000-8000-000000000001/91000000-0000-4000-8000-000000000003.jpg');
    raise exception 'Expected private avatar overwrite rejection';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.profiles set avatar_path=null where user_id='90000000-0000-4000-8000-000000000001';
    assert not found,'Group member cannot modify another profile';
  exception when insufficient_privilege then null;
  end;
end $$;
select set_config('request.jwt.claim.sub','90000000-0000-4000-8000-000000000003',true);
do $$
begin
  assert not exists(select 1 from public.profiles where user_id='90000000-0000-4000-8000-000000000001'),'Outsider cannot read private avatar path';
  begin
    perform public.pal_group_state(current_setting('pal.avatar.group')::uuid);
    raise exception 'Expected avatar group state denial';
  exception when insufficient_privilege then null;
  end;
end $$;
select set_config('request.jwt.claim.sub','90000000-0000-4000-8000-000000000001',true);
select public.pal_profile_save('{"display_name":"Owner renamed"}');
do $$
begin
  assert (select avatar_path is not null from public.profiles where user_id=auth.uid()),'Unrelated profile edits preserve avatar';
end $$;
do $$
declare r jsonb;
begin
  r:=public.pal_profile_save('{"avatar_url":null}');
  assert r->>'_previous_avatar_path'='90000000-0000-4000-8000-000000000001/91000000-0000-4000-8000-000000000002.jpg','Clear returns the exact previous path from the locked row';
  assert (select avatar_path is null and avatar_url is null from public.profiles where user_id=auth.uid()),'Explicit null avatar clears private and legacy references';
end $$;
rollback;
