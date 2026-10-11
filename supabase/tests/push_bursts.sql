-- Dedicated test database only. Notifications are never sent; all fixtures roll back.
begin;
insert into auth.users(id,email) values
 ('b6000000-0000-4000-8000-000000000001','push-owner@example.invalid'),
 ('b6000000-0000-4000-8000-000000000002','push-friend@example.invalid'),
 ('b6000000-0000-4000-8000-000000000003','push-muted@example.invalid');
insert into public.groups(id,name,creator_id) values ('b6100000-0000-4000-8000-000000000001','Push tests','b6000000-0000-4000-8000-000000000001');
insert into public.group_members(group_id,user_id) values
 ('b6100000-0000-4000-8000-000000000001','b6000000-0000-4000-8000-000000000001'),
 ('b6100000-0000-4000-8000-000000000001','b6000000-0000-4000-8000-000000000002'),
 ('b6100000-0000-4000-8000-000000000001','b6000000-0000-4000-8000-000000000003');
insert into public.profiles(user_id,display_name,notification_preferences) values ('b6000000-0000-4000-8000-000000000003','Muted member','{"enabled":false}')
on conflict(user_id) do update set notification_preferences=excluded.notification_preferences;
insert into public.messages(group_id,role,body,source_key,card) values
 ('b6100000-0000-4000-8000-000000000001','pal','First joke','job:b6200000-0000-4000-8000-000000000001',null),
 ('b6100000-0000-4000-8000-000000000001','pal','Please RSVP','job:b6200000-0000-4000-8000-000000000001:part:2','{"type":"plan","entity_id":"b6300000-0000-4000-8000-000000000001"}'),
 ('b6100000-0000-4000-8000-000000000001','pal','One last question?','job:b6200000-0000-4000-8000-000000000001:part:3',null),
 ('b6100000-0000-4000-8000-000000000001','pal','First thought','job:b6200000-0000-4000-8000-000000000002',null),
 ('b6100000-0000-4000-8000-000000000001','pal','Friday or Saturday?','job:b6200000-0000-4000-8000-000000000002:part:2',null);
do $$
begin
  assert (select count(*)=5 from public.messages where group_id='b6100000-0000-4000-8000-000000000001'),'Coalescing never removes chat bubbles';
  assert (select count(*)=2 from private.push_outbox where source_key like 'pal-turn:b6200000-0000-4000-8000-000000000001:%'),'Three Pal bubbles create one push per enabled recipient';
  assert not exists(select 1 from private.push_outbox where user_id='b6000000-0000-4000-8000-000000000003'),'Muted members still receive no pushes';
  assert (select bool_and(payload->>'type'='plan' and payload->'aps'->'alert'->>'body'='Please RSVP' and message_id=(payload->>'message_id')::uuid)
    from private.push_outbox where source_key like 'pal-turn:b6200000-0000-4000-8000-000000000001:%'),'The actionable plan survives later plain text with matching deep link';
  assert (select bool_and(payload->'aps'->'alert'->>'body'='Friday or Saturday?') from private.push_outbox
    where source_key like 'pal-turn:b6200000-0000-4000-8000-000000000002:%'),'Plain replies retain the newest conversational beat';
end $$;
insert into public.messages(group_id,sender_id,role,body) values
 ('b6100000-0000-4000-8000-000000000001','b6000000-0000-4000-8000-000000000001','user','Human message one'),
 ('b6100000-0000-4000-8000-000000000001','b6000000-0000-4000-8000-000000000001','user','Human message two');
insert into public.reminders(id,group_id,requester_id,body,due_at,status,source_key,target_user_ids) values
 ('b6400000-0000-4000-8000-000000000001','b6100000-0000-4000-8000-000000000001','b6000000-0000-4000-8000-000000000001','Bring the tickets',now(),'completed','push-reminder-1','{b6000000-0000-4000-8000-000000000001}');
insert into public.messages(group_id,role,body,source_key) values
 ('b6100000-0000-4000-8000-000000000001','system','Bring the tickets','reminder:b6400000-0000-4000-8000-000000000001'),
 ('b6100000-0000-4000-8000-000000000001','system','Plan changed','plan-change:push-test'),
 ('b6100000-0000-4000-8000-000000000001','system','Internal weekly request','weekly:push-test');
do $$
begin
  assert (select count(*)=2 from private.push_outbox o join public.messages m on m.id=o.message_id where m.body like 'Human message %'),'Human messages remain independent and exclude their own sender';
  assert (select count(*)=1 from private.push_outbox where payload->>'reminder_id'='b6400000-0000-4000-8000-000000000001'),'Targeted reminder remains a separate delivery';
  assert (select count(*)=2 from private.push_outbox o join public.messages m on m.id=o.message_id where m.source_key='plan-change:push-test'),'Independent plan changes retain their own deliveries';
  assert not exists(select 1 from private.push_outbox o join public.messages m on m.id=o.message_id where m.source_key='weekly:push-test'),'Internal weekly requests stay silent';
end $$;
update private.push_outbox set status='sent',attempts=1,sent_at=now()
where source_key='pal-turn:b6200000-0000-4000-8000-000000000002:user:b6000000-0000-4000-8000-000000000001';
update public.group_members set last_read_at=now() where group_id='b6100000-0000-4000-8000-000000000001' and user_id='b6000000-0000-4000-8000-000000000001';
do $$
begin
  assert (select status='sent' and attempts=1 from private.push_outbox where source_key='pal-turn:b6200000-0000-4000-8000-000000000002:user:b6000000-0000-4000-8000-000000000001'),'Reading never rewrites a delivery record';
  assert not exists(select 1 from private.push_outbox where user_id='b6000000-0000-4000-8000-000000000001' and status='queued' and payload->>'reminder_id' is null),'Already-read queued chat notifications are cancelled';
  assert (select status='queued' from private.push_outbox where payload->>'reminder_id'='b6400000-0000-4000-8000-000000000001'),'Reading chat does not cancel an independently scheduled reminder';
  assert exists(select 1 from private.push_outbox where user_id='b6000000-0000-4000-8000-000000000002' and status='queued'),'One reader never silences another member';
end $$;
-- Real confirmations with more than eight tags retain two chat bubbles, but one push per member.
insert into auth.users(id,email)
select ('b7000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'push-rsvp-'||n||'@example.invalid' from generate_series(1,9) n;
insert into public.profiles(user_id,display_name)
select ('b7000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'RSVP friend '||n from generate_series(1,9) n;
insert into public.groups(id,name,creator_id) values ('b7100000-0000-4000-8000-000000000001','Large RSVP group','b7000000-0000-4000-8000-000000000001');
insert into public.group_members(group_id,user_id)
select 'b7100000-0000-4000-8000-000000000001',('b7000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,9) n;
insert into public.plans(id,group_id,created_by,title,starts_at,ends_at,status)
values ('b7200000-0000-4000-8000-000000000001','b7100000-0000-4000-8000-000000000001','b7000000-0000-4000-8000-000000000001','Dinner',now()+interval '3 days',now()+interval '3 days 2 hours','confirmed');
do $$ begin
  assert (select count(*)=2 from public.messages where group_id='b7100000-0000-4000-8000-000000000001'),'Nine tags remain in two real RSVP chat bubbles';
  assert (select count(*)=9 and count(distinct user_id)=9 from private.push_outbox where source_key like 'plan-rsvp:b7200000-0000-4000-8000-000000000001:1:%'),'Each member receives one push for the confirmed plan version';
  assert not exists(select 1 from private.push_outbox o join public.messages m on m.id=o.message_id
    where o.source_key like 'plan-rsvp:b7200000-0000-4000-8000-000000000001:1:%'
      and (m.card->>'type'<>'rsvp' or not m.mentions @> jsonb_build_array(jsonb_build_object('type','user','user_id',o.user_id))
        or o.message_id<>(o.payload->>'message_id')::uuid)),'Each actionable deep link uses the bubble mentioning its own recipient';
end $$;
update public.plans set starts_at=starts_at+interval '1 hour',ends_at=ends_at+interval '1 hour',version=2
where id='b7200000-0000-4000-8000-000000000001';
do $$ begin
  assert (select count(*)=18 from private.push_outbox where source_key like 'plan-rsvp:b7200000-0000-4000-8000-000000000001:%'),'Rescheduling creates a separate push for the new version';
  assert not exists(select user_id from private.push_outbox where source_key like 'plan-rsvp:b7200000-0000-4000-8000-000000000001:%'
    group by user_id having count(*)<>2),'Every member receives exactly one push per each of two plan versions';
end $$;
rollback;
