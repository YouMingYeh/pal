-- Keep Pal's separate chat bubbles, with one actionable notification per turn and recipient.
create or replace function private.pal_queue_push() returns trigger
language plpgsql security definer set search_path='' as $$
declare r public.reminders; tz text; due timestamptz; push_key text;
begin
  if new.role='system' and (new.source_key like 'weekly:%' or new.source_key like 'pal:weekly:%') then return new; end if;
  select timezone into tz from public.groups where id=new.group_id;
  if new.source_key like 'reminder:%' then select * into r from public.reminders where id=split_part(new.source_key,':',2)::uuid; end if;
  due:=private.pal_next_awake(now(),tz);
  push_key:=case when new.role='pal' and new.source_key ~ '^job:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(:part:[23])?$'
    then 'pal-turn:'||split_part(new.source_key,':',2)
    when new.role='pal' and new.source_key ~ '^plan-rsvp:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9]+:part:[1-9][0-9]*$'
    then 'plan-rsvp:'||split_part(new.source_key,':',2)||':'||split_part(new.source_key,':',3)
    else 'message:'||new.id end;
  insert into private.push_outbox as queued(message_id,group_id,user_id,plan_id,payload,next_attempt,source_key)
  select new.id,new.group_id,m.user_id,r.plan_id,
    jsonb_build_object('aps',jsonb_build_object('alert',jsonb_build_object('title','Pal','body',left(new.body,120)),'sound','default'),
      'group_id',new.group_id,'message_id',new.id,'type',new.card->>'type','entity_id',new.card->>'entity_id','reminder_id',r.id,'plan_id',r.plan_id,'poll_id',r.poll_id),
    due,push_key||':user:'||m.user_id
  from public.group_members m left join public.profiles p on p.user_id=m.user_id
  where m.group_id=new.group_id and m.user_id is distinct from new.sender_id and coalesce(p.notifications_enabled,true)
    and (r.id is null or cardinality(r.target_user_ids)=0 or m.user_id=any(r.target_user_ids))
    and (r.poll_id is null or not exists(select 1 from public.poll_responses v where v.poll_id=r.poll_id and v.user_id=m.user_id))
    and (r.id is null or r.kind not in ('plan_24h','plan_2h') or exists(select 1 from public.plan_rsvps v where v.plan_id=r.plan_id and v.user_id=m.user_id and v.status='going'))
  on conflict(source_key) do update set (message_id,payload)=(
    select candidate.message_id,candidate.payload
    from (values (queued.message_id,queued.payload,0),(excluded.message_id,excluded.payload,1)) candidate(message_id,payload,newest)
    order by case when candidate.payload->>'type' in ('plan','rsvp') then 3
      when candidate.payload->>'type'='availability' then 2
      when candidate.payload->>'type' in ('options','choice') then 1 else 0 end desc,
      case when push_key like 'plan-rsvp:%' then exists(
        select 1 from public.messages msg where msg.id=candidate.message_id
          and msg.mentions @> jsonb_build_array(jsonb_build_object('type','user','user_id',queued.user_id))
      ) else false end desc,candidate.newest desc limit 1
  ) where queued.status='queued';
  return new;
end $$;

-- A delayed worker should not alert for ordinary chat text the recipient already saw.
create function private.pal_cancel_read_pushes() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.last_read_at is not null and (old.last_read_at is null or new.last_read_at>old.last_read_at) then
    update private.push_outbox o set status='cancelled',lease_until=null
    from public.messages msg where o.message_id=msg.id and o.group_id=new.group_id and o.user_id=new.user_id
      and o.status='queued' and msg.created_at<=new.last_read_at
      and o.payload->>'reminder_id' is null;
  end if;
  return new;
end $$;
revoke all on function private.pal_cancel_read_pushes() from public,anon,authenticated,service_role;
create trigger pal_cancel_read_pushes after update of last_read_at on public.group_members
  for each row execute function private.pal_cancel_read_pushes();
