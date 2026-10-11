-- A real confirmation starts attendance collection without asking the model to impersonate it.
create function private.pal_confirmed_plan_rsvp() returns trigger
language plpgsql security definer set search_path='' as $$
declare g public.groups; venue text; material boolean:=false; batch record; stamp timestamptz:=clock_timestamp();
begin
  if new.status<>'confirmed' or new.starts_at<=now() then return new; end if;
  if tg_op='UPDATE' then
    material:=new.starts_at is distinct from old.starts_at or new.ends_at is distinct from old.ends_at
      or new.place_id is distinct from old.place_id;
    if old.status='confirmed' and not material then return new; end if;
    if material then delete from public.plan_rsvps where plan_id=new.id; end if;
  end if;
  select * into g from public.groups where id=new.group_id;
  if not found or g.agent_paused then return new; end if;
  if new.place_id is not null then
    select name into venue from public.places where id=new.place_id and group_id=new.group_id;
  end if;
  -- Keep every selected identity current until the reference validator inserts the messages.
  perform 1 from public.group_members where group_id=new.group_id for key share;
  for batch in
    select part,jsonb_agg(jsonb_build_object('type','user','user_id',user_id) order by user_id) as mentions,
      string_agg('@'||label,', ' order by user_id) as names
    from (
      select m.user_id,(row_number() over(order by m.user_id)-1)/8+1 as part,
        left(regexp_replace(coalesce(p.display_name,'Friend'),'[[:space:]]+',' ','g'),40) as label
      from public.group_members m left join public.profiles p on p.user_id=m.user_id
      where m.group_id=new.group_id
    ) members group by part order by part
  loop
    insert into public.messages(group_id,role,body,source_key,emotion,mentions,card,created_at)
    values(new.group_id,'pal',
      case when material then 'Plan changed. ' else '' end
      ||to_char(new.starts_at at time zone g.timezone,'Dy, Mon FMDD, FMHH12:MI AM')||' ('||g.timezone||')'
      ||case when venue is not null then ' at '||left(venue,160) else ' · '||left(new.title,160) end||E'.\n'
      ||batch.names||', are you in? Tap Yes, Maybe or No. No essay required.',
      'plan-rsvp:'||new.id||':'||new.version||':part:'||batch.part,'heureux',batch.mentions,
      jsonb_build_object('type','rsvp','entity_id',new.id),stamp+(batch.part-1)*interval '1 millisecond')
    on conflict(group_id,source_key) do nothing;
  end loop;
  return new;
end $$;
revoke all on function private.pal_confirmed_plan_rsvp() from public,anon,authenticated,service_role;
create trigger pal_confirmed_plan_rsvp after insert or update of status,starts_at,ends_at,place_id on public.plans
  for each row execute function private.pal_confirmed_plan_rsvp();
