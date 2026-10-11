-- Dedicated local test database; location fixtures and all writes roll back.
begin;
insert into auth.users(id,email) values
 ('b1000000-0000-4000-8000-000000000001','pal-location-a@example.invalid'),
 ('b1000000-0000-4000-8000-000000000002','pal-location-b@example.invalid'),
 ('b1000000-0000-4000-8000-000000000003','pal-location-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-000000000001',true);
select set_config('pal.location.group',(public.create_group('Location friends')).id::text,true);
select set_config('pal.location.invite',(select invite_code::text from public.groups where id=current_setting('pal.location.group')::uuid),true);
select set_config('pal.location.other',(public.create_group('Unshared location group')).id::text,true);
select set_config('pal.location.direct',(public.ensure_pal_direct()).id::text,true);
select public.pal_group_location(current_setting('pal.location.group')::uuid,'{"latitude":37.78,"longitude":-122.41,"accuracy":12}');
do $$
declare r jsonb; g uuid:=current_setting('pal.location.group')::uuid;
begin
  r:=public.pal_group_state(g);
  assert jsonb_array_length(r->'locations')=1,'Opted-in location appears in its group';
  assert r->'locations'->0->>'user_id'=auth.uid()::text,'Speaker identity comes from authentication';
  assert (r->'locations'->0->>'updated_at')::timestamptz=now(),'Only server time sets update';
  assert (r->'locations'->0->>'expires_at')::timestamptz=now()+interval '1 hour','TTL is one hour';
  assert not (r->'locations'->0 ? 'group_id'),'No redundant cross-group identifier';
  assert jsonb_array_length(public.pal_group_state(current_setting('pal.location.other')::uuid)->'locations')=0,'Sharing never fans out to other groups';
  assert r ? 'pal_activity' and r ? 'plans' and r ? 'polls','Latest state wrapper preserves existing fields';
  begin perform public.pal_group_location(g,'{"latitude":91,"longitude":0,"accuracy":1}'); raise exception 'Expected coordinate rejection'; exception when invalid_parameter_value then null; end;
  begin perform public.pal_group_location(g,'{"latitude":0,"longitude":181,"accuracy":1}'); raise exception 'Expected longitude rejection'; exception when invalid_parameter_value then null; end;
  begin perform public.pal_group_location(g,'{"latitude":0,"longitude":0,"accuracy":-1}'); raise exception 'Expected accuracy rejection'; exception when invalid_parameter_value then null; end;
  begin perform public.pal_group_location(g,'{"latitude":0,"longitude":0,"accuracy":1,"updated_at":"2099-01-01"}'); raise exception 'Expected clock injection rejection'; exception when invalid_parameter_value then null; end;
  begin perform public.pal_group_location(g,'{"latitude":0,"longitude":0,"accuracy":1,"user_id":"b1000000-0000-4000-8000-000000000002"}'); raise exception 'Expected identity injection rejection'; exception when invalid_parameter_value then null; end;
  begin perform public.pal_group_location(g,'{"latitude":"37","longitude":0,"accuracy":1}'); raise exception 'Expected string coordinate rejection'; exception when invalid_parameter_value then null; end;
  begin perform public.pal_group_location(current_setting('pal.location.direct')::uuid,'{"latitude":0,"longitude":0,"accuracy":1}'); raise exception 'Expected private-chat rejection'; exception when invalid_parameter_value then null; end;
  begin update public.group_member_locations set expires_at='2099-01-01' where group_id=g; raise exception 'Expected direct clock-column rejection'; exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-000000000002',true);
select public.join_group(current_setting('pal.location.invite')::uuid);
select public.pal_group_location(current_setting('pal.location.group')::uuid,'{"latitude":37.79,"longitude":-122.40,"accuracy":20}');
do $$
declare n integer;
begin
  assert (select count(*)=2 from public.group_member_locations where group_id=current_setting('pal.location.group')::uuid),'Current members see fresh opted-in records';
  update public.group_member_locations set latitude=0 where user_id='b1000000-0000-4000-8000-000000000001';
  get diagnostics n=row_count;
  assert n=0,'Members cannot change another member location';
  delete from public.group_member_locations where user_id='b1000000-0000-4000-8000-000000000001';
  get diagnostics n=row_count;
  assert n=0,'Members cannot stop another member location';
  begin insert into public.group_member_locations(group_id,user_id,latitude,longitude,accuracy) values(current_setting('pal.location.other')::uuid,auth.uid(),0,0,1); raise exception 'Expected foreign-group write rejection'; exception when insufficient_privilege then null; end;
end $$;
reset role;
alter table public.group_member_locations disable trigger pal_location_timestamp;
update public.group_member_locations set expires_at=now()-interval '1 minute' where user_id='b1000000-0000-4000-8000-000000000002';
alter table public.group_member_locations enable trigger pal_location_timestamp;
set local role authenticated;
select set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-000000000001',true);
do $$ begin
  assert jsonb_array_length(public.pal_group_state(current_setting('pal.location.group')::uuid)->'locations')=1,'Expired sharing is unknown in app and agent context';
  assert (select count(*)=1 from public.group_member_locations where group_id=current_setting('pal.location.group')::uuid),'Peers cannot query expired coordinates directly';
end $$;
select set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-000000000002',true);
update public.group_member_locations set latitude=38 where group_id=current_setting('pal.location.group')::uuid and user_id=auth.uid();
do $$ begin
  assert jsonb_array_length(public.pal_group_state(current_setting('pal.location.group')::uuid)->'locations')=2,'Own expired record can renew safely';
  assert (select expires_at=now()+interval '1 hour' and updated_at=now() from public.group_member_locations where group_id=current_setting('pal.location.group')::uuid and user_id=auth.uid()),'Direct writes also receive server time';
end $$;
select public.pal_group_location(current_setting('pal.location.group')::uuid,null);
select public.pal_group_location(current_setting('pal.location.group')::uuid,null);
do $$ begin
  assert jsonb_array_length(public.pal_group_state(current_setting('pal.location.group')::uuid)->'locations')=1,'Stop sharing is idempotent and preserves the other member';
end $$;
select public.pal_group_location(current_setting('pal.location.group')::uuid,'{"latitude":38,"longitude":-122,"accuracy":15}');
select set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-000000000003',true);
do $$ begin
  assert (select count(*)=0 from public.group_member_locations),'Outsiders see no coordinates';
  begin perform public.pal_group_location(current_setting('pal.location.group')::uuid,'{"latitude":0,"longitude":0,"accuracy":1}'); raise exception 'Expected outsider write rejection'; exception when insufficient_privilege then null; end;
  begin perform public.pal_group_state(current_setting('pal.location.group')::uuid); raise exception 'Expected outsider state rejection'; exception when insufficient_privilege then null; end;
end $$;
reset role;
delete from public.group_members where group_id=current_setting('pal.location.group')::uuid and user_id='b1000000-0000-4000-8000-000000000002';
do $$ begin assert (select count(*)=1 from public.group_member_locations where group_id=current_setting('pal.location.group')::uuid),'Revoking membership cascades its raw location'; end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-000000000002',true);
do $$ begin
  assert (select count(*)=0 from public.group_member_locations),'Former members immediately lose location reads';
  begin perform public.pal_group_location(current_setting('pal.location.group')::uuid,'{"latitude":0,"longitude":0,"accuracy":1}'); raise exception 'Expected former member write rejection'; exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role anon;
do $$ begin
  begin perform public.pal_group_location(current_setting('pal.location.group')::uuid,null); raise exception 'Expected anonymous RPC rejection'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.group_member_locations; raise exception 'Expected anonymous table rejection'; exception when insufficient_privilege then null; end;
end $$;
rollback;
