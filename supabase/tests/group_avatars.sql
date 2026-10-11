-- Dedicated test database only. Group creation and avatar references roll back.
begin;
insert into auth.users(id,email) values
 ('70000000-0000-4000-8000-000000000001','pal-group-avatar-owner@example.invalid'),
 ('70000000-0000-4000-8000-000000000002','pal-group-avatar-member@example.invalid'),
 ('70000000-0000-4000-8000-000000000003','pal-group-avatar-outsider@example.invalid');
select set_config('request.jwt.claim.sub','70000000-0000-4000-8000-000000000003',true);
set local role service_role;
do $$
declare created jsonb; replay jsonb; path text:='groups/70000000-0000-4000-8000-000000000001/72000000-0000-4000-8000-000000000001.jpg'; previous_sub text:=current_setting('request.jwt.claim.sub');
begin
  created:=public.pal_group_create('70000000-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000001','Photo group',path,repeat('a',64));
  perform set_config('pal.group_avatar.id',created->'group'->>'id',true);
  perform set_config('pal.group_avatar.invite',created->'group'->>'invite_code',true);
  assert created->'group'->>'avatar_path'=path and created->>'uploaded_path_used'='true','Create saves name and actual avatar reference together';
  assert exists(select 1 from public.group_members where group_id=current_setting('pal.group_avatar.id')::uuid and user_id='70000000-0000-4000-8000-000000000001'),'Creator joins the new group atomically';
  assert current_setting('request.jwt.claim.sub')=previous_sub,'Group creation restores the caller JWT subject';
  replay:=public.pal_group_create('70000000-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000001','Photo group','groups/70000000-0000-4000-8000-000000000001/72000000-0000-4000-8000-000000000002.jpg',repeat('a',64));
  assert replay->'group'=created->'group' and replay->>'uploaded_path_used'='false','Lost-response retry returns the original group and unused blob disposition';
  assert (select count(*)=1 from public.groups where creator_id='70000000-0000-4000-8000-000000000001'),'Retry creates exactly one group';
  begin
    perform public.pal_group_create('70000000-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000001','Changed name',path,repeat('a',64));
    raise exception 'Expected changed creation name rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.pal_group_create('70000000-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000001','Photo group',path,repeat('b',64));
    raise exception 'Expected changed creation image rejection';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.pal_group_create('70000000-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000002','Invalid owner','groups/70000000-0000-4000-8000-000000000002/72000000-0000-4000-8000-000000000002.jpg',repeat('a',64));
    raise exception 'Expected cross-owner avatar rejection';
  exception when invalid_parameter_value then null;
  end;
  assert (select count(*)=1 from public.groups where creator_id='70000000-0000-4000-8000-000000000001'),'Rejected photo creation leaves no group or membership';
  update public.groups set name='Renamed later' where id=current_setting('pal.group_avatar.id')::uuid;
  replay:=public.pal_group_create('70000000-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000001','Photo group',path,repeat('a',64));
  assert replay->'group'->>'id'=current_setting('pal.group_avatar.id') and replay->'group'->>'name'='Renamed later','Retry validates frozen creation input without overwriting a later group rename';
  replay:=public.pal_group_create('70000000-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000002','No photo');
  assert replay->'group'->>'avatar_path' is null,'New idempotent group creation also supports no photo';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','70000000-0000-4000-8000-000000000002',true);
select public.join_group(current_setting('pal.group_avatar.invite')::uuid);
do $$
declare settings jsonb;
begin
  assert (select avatar_path is not null from public.groups where id=current_setting('pal.group_avatar.id')::uuid),'Only authorized group rows provide the avatar path';
  settings:=public.pal_group_state(current_setting('pal.group_avatar.id')::uuid)->'settings';
  assert settings->>'creator_id'='70000000-0000-4000-8000-000000000001' and settings->>'avatar_path' is not null,'Group state exposes creator and avatar for authorized backend signing';
  assert not has_function_privilege('authenticated','public.pal_group_create(uuid,uuid,text,text,text)','execute'),'Client cannot impersonate group creation owner';
end $$;
select set_config('request.jwt.claim.sub','70000000-0000-4000-8000-000000000003',true);
do $$
begin
  assert not exists(select 1 from public.groups where id=current_setting('pal.group_avatar.id')::uuid),'Outsider cannot read group avatar path';
  begin
    perform public.pal_group_state(current_setting('pal.group_avatar.id')::uuid);
    raise exception 'Expected group avatar state denial';
  exception when insufficient_privilege then null;
  end;
end $$;
select public.create_group('Legacy create remains supported');
rollback;
