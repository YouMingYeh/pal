-- Foreground opt-in shares are scoped to one group, expire, and disappear with membership.
create table public.group_member_locations (
  group_id uuid not null,
  user_id uuid not null,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy double precision not null check (accuracy between 0 and 10000),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '1 hour',
  primary key (group_id,user_id),
  foreign key (group_id,user_id) references public.group_members(group_id,user_id) on delete cascade
);
alter table public.group_member_locations enable row level security;
revoke all on public.group_member_locations from public,anon,authenticated;
grant select,delete on public.group_member_locations to authenticated;
grant insert(group_id,user_id,latitude,longitude,accuracy),update(latitude,longitude,accuracy) on public.group_member_locations to authenticated;
grant all on public.group_member_locations to service_role;

create policy members_read_locations on public.group_member_locations for select to authenticated using (
  group_id in (select private.my_group_ids()) and (expires_at>now() or user_id=(select auth.uid()))
);
create policy own_insert_location on public.group_member_locations for insert to authenticated with check (
  user_id=(select auth.uid()) and group_id in (select private.my_group_ids())
  and exists(select 1 from public.groups g where g.id=group_id and not g.is_direct)
);
create policy own_update_location on public.group_member_locations for update to authenticated using (
  user_id=(select auth.uid()) and group_id in (select private.my_group_ids())
) with check (
  user_id=(select auth.uid()) and group_id in (select private.my_group_ids())
  and exists(select 1 from public.groups g where g.id=group_id and not g.is_direct)
);
create policy own_delete_location on public.group_member_locations for delete to authenticated using (
  user_id=(select auth.uid()) and group_id in (select private.my_group_ids())
);

create function private.pal_location_timestamp() returns trigger
language plpgsql set search_path='' as $$
begin
  new.updated_at:=now();
  new.expires_at:=now()+interval '1 hour';
  return new;
end $$;
revoke all on function private.pal_location_timestamp() from public,anon,authenticated;
create trigger pal_location_timestamp before insert or update on public.group_member_locations
for each row execute function private.pal_location_timestamp();

create function private.pal_group_location(p_group_id uuid,p_location jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); r public.group_member_locations;
begin
  if u is null then raise exception 'Authentication required' using errcode='42501'; end if;
  perform 1 from public.group_members where group_id=p_group_id and user_id=u for key share;
  if not found then raise exception 'Group membership required' using errcode='42501'; end if;
  if p_location is null then
    delete from public.group_member_locations where group_id=p_group_id and user_id=u;
    return jsonb_build_object('location',null);
  end if;
  if exists(select 1 from public.groups where id=p_group_id and is_direct) then
    raise exception 'Location sharing is for shared groups' using errcode='22023';
  end if;
  if jsonb_typeof(p_location)<>'object' or p_location-array['latitude','longitude','accuracy']<>'{}'::jsonb
    or jsonb_typeof(p_location->'latitude') is distinct from 'number'
    or jsonb_typeof(p_location->'longitude') is distinct from 'number'
    or jsonb_typeof(p_location->'accuracy') is distinct from 'number' then
    raise exception 'Location coordinates and accuracy required' using errcode='22023';
  end if;
  if not ((p_location->>'latitude')::double precision between -90 and 90
    and (p_location->>'longitude')::double precision between -180 and 180
    and (p_location->>'accuracy')::double precision between 0 and 10000) then
    raise exception 'Invalid location coordinates or accuracy' using errcode='22023';
  end if;
  insert into public.group_member_locations(group_id,user_id,latitude,longitude,accuracy)
  values(p_group_id,u,(p_location->>'latitude')::double precision,(p_location->>'longitude')::double precision,(p_location->>'accuracy')::double precision)
  on conflict(group_id,user_id) do update set latitude=excluded.latitude,longitude=excluded.longitude,accuracy=excluded.accuracy
  returning * into r;
  return jsonb_build_object('location',to_jsonb(r)-'group_id');
end $$;
create function public.pal_group_location(p_group_id uuid,p_location jsonb default null) returns jsonb
language sql set search_path='' as $$ select private.pal_group_location(p_group_id,p_location) $$;
revoke all on function private.pal_group_location(uuid,jsonb),public.pal_group_location(uuid,jsonb) from public,anon;
grant execute on function private.pal_group_location(uuid,jsonb),public.pal_group_location(uuid,jsonb) to authenticated;

-- Preserve the latest verified state function, including activity/card changes from preceding migrations.
alter function private.pal_group_state(uuid) rename to pal_group_state_before_locations;
create function private.pal_group_state(p_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare state jsonb;
begin
  state:=private.pal_group_state_before_locations(p_group_id);
  return state||jsonb_build_object('locations',coalesce((select jsonb_agg(to_jsonb(l)-'group_id' order by l.user_id)
    from public.group_member_locations l join public.group_members m using(group_id,user_id)
    where l.group_id=p_group_id and l.expires_at>now()),'[]'::jsonb));
end $$;
create or replace function public.pal_group_state(p_group_id uuid) returns jsonb
language sql stable set search_path='' as $$ select private.pal_group_state(p_group_id) $$;
revoke all on function private.pal_group_state(uuid),private.pal_group_state_before_locations(uuid) from public,anon;
grant execute on function private.pal_group_state(uuid),private.pal_group_state_before_locations(uuid) to authenticated,service_role;

do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    alter publication supabase_realtime add table public.group_member_locations;
  end if;
end $$;
