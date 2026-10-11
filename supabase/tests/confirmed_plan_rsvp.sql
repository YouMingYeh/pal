-- Dedicated test database only. Automatic attendance requests keep genuine member identities.
begin;
insert into auth.users(id,email)
select ('b2000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'pal-rsvp-'||n||'@example.invalid'
from generate_series(1,11) n;
insert into public.profiles(user_id,display_name)
select ('b2000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'Friend '||n from generate_series(1,11) n;
set local role authenticated;
select set_config('request.jwt.claim.sub','b2000000-0000-4000-8000-000000000001',true);
select set_config('pal.rsvp.group',(public.create_group('Friday dinner')).id::text,true);
select set_config('pal.rsvp.invite',(select invite_code::text from public.groups where id=current_setting('pal.rsvp.group')::uuid),true);
do $$ begin
  for n in 2..10 loop
    perform set_config('request.jwt.claim.sub','b2000000-0000-4000-8000-'||lpad(n::text,12,'0'),true);
    perform public.join_group(current_setting('pal.rsvp.invite')::uuid);
  end loop;
end $$;
reset role;
delete from public.group_members where group_id=current_setting('pal.rsvp.group')::uuid and user_id='b2000000-0000-4000-8000-000000000010';
set local role authenticated;
select set_config('request.jwt.claim.sub','b2000000-0000-4000-8000-000000000011',true);
select set_config('pal.rsvp.other',(public.create_group('Other group')).id::text,true);
select set_config('request.jwt.claim.sub','b2000000-0000-4000-8000-000000000001',true);
select set_config('pal.rsvp.place',(public.pal_action(current_setting('pal.rsvp.group')::uuid,'place.save','{"name":"Tur","address":"1 Main St","latitude":37.78,"longitude":-122.41,"provider":"apple","provider_id":"pal-rsvp-tur"}'))->>'id',true);
select set_config('pal.rsvp.plan',(public.pal_action(current_setting('pal.rsvp.group')::uuid,'plan.create',jsonb_build_object('title','Dinner','place_id',current_setting('pal.rsvp.place'),'starts_at','2030-01-05T04:00:00Z')))->>'id',true);
do $$ begin
  assert not exists(select 1 from public.messages where group_id=current_setting('pal.rsvp.group')::uuid and source_key like 'plan-rsvp:%'),'Draft plans never request attendance';
  assert not has_function_privilege('authenticated','private.pal_confirmed_plan_rsvp()','execute'),'Members cannot call the trigger directly';
end $$;
select public.pal_action(current_setting('pal.rsvp.group')::uuid,'plan.confirm',jsonb_build_object('id',current_setting('pal.rsvp.plan'),'source_key','confirm-rsvp-test'));
do $$
declare p uuid:=current_setting('pal.rsvp.plan')::uuid; gid uuid:=current_setting('pal.rsvp.group')::uuid;
begin
  assert (select count(*)=2 from public.messages where group_id=gid and source_key like 'plan-rsvp:'||p||':2:%'),'Nine members receive two bounded messages';
  assert (select bool_and(role='pal' and sender_id is null and emotion='heureux' and card=jsonb_build_object('type','rsvp','entity_id',p) and jsonb_array_length(mentions) between 1 and 8)
    from public.messages where group_id=gid and source_key like 'plan-rsvp:%'),'Every request is a real Pal message with the same current plan card and bounded mentions';
  assert (select count(*)=9 and count(distinct tag->>'user_id')=9 from public.messages msg cross join lateral jsonb_array_elements(msg.mentions) tag
    where msg.group_id=gid and msg.source_key like 'plan-rsvp:'||p||':2:%'),'Every current member is tagged exactly once';
  assert not exists(select 1 from public.messages msg cross join lateral jsonb_array_elements(msg.mentions) tag
    where msg.group_id=gid and msg.source_key like 'plan-rsvp:%' and not exists(select 1 from public.group_members m where m.group_id=gid and m.user_id=(tag->>'user_id')::uuid)),'Removed members and other groups are never mentioned';
  assert (select bool_and(body like '%Fri, Jan 4, 8:00 PM (America/Los_Angeles) at Tur%' and body like '%Tap Yes, Maybe or No%' and body not ilike '%booked%')
    from public.messages where group_id=gid and source_key like 'plan-rsvp:%'),'Time and venue use actual group facts without inventing a booking';
  assert not exists(select 1 from public.plan_rsvps where plan_id=p),'No member is automatically marked attending';
end $$;
select public.pal_action(current_setting('pal.rsvp.group')::uuid,'plan.confirm',jsonb_build_object('id',current_setting('pal.rsvp.plan'),'source_key','confirm-rsvp-test'));
select public.pal_action(current_setting('pal.rsvp.group')::uuid,'plan.rsvp',jsonb_build_object('id',current_setting('pal.rsvp.plan'),'status','going'));
select public.pal_action(current_setting('pal.rsvp.group')::uuid,'plan.update',jsonb_build_object('id',current_setting('pal.rsvp.plan'),'notes','Bring an appetite'));
do $$ begin
  assert (select count(*)=2 from public.messages where group_id=current_setting('pal.rsvp.group')::uuid and source_key like 'plan-rsvp:%'),'Retries and note edits do not repeat the request';
  assert (select status='going' from public.plan_rsvps where plan_id=current_setting('pal.rsvp.plan')::uuid and user_id=auth.uid()),'Note edits preserve attendance';
end $$;
select public.pal_action(current_setting('pal.rsvp.group')::uuid,'plan.update',jsonb_build_object('id',current_setting('pal.rsvp.plan'),'starts_at','2030-01-05T05:00:00Z','source_key','move-rsvp-test'));
select public.pal_action(current_setting('pal.rsvp.group')::uuid,'plan.update',jsonb_build_object('id',current_setting('pal.rsvp.plan'),'starts_at','2030-01-05T05:00:00Z','source_key','move-rsvp-test'));
do $$ begin
  assert (select count(*)=4 from public.messages where group_id=current_setting('pal.rsvp.group')::uuid and source_key like 'plan-rsvp:%'),'Material rescheduling requests renewed attendance once per version';
  assert (select count(*)=2 from public.messages where group_id=current_setting('pal.rsvp.group')::uuid and source_key like 'plan-rsvp:%:4:%' and body like 'Plan changed.%9:00 PM%'),'The new request states the new time';
  assert not exists(select 1 from public.plan_rsvps where plan_id=current_setting('pal.rsvp.plan')::uuid),'Old attendance cannot transfer to a new time';
  assert (select count(*)=2 from public.reminders where plan_id=current_setting('pal.rsvp.plan')::uuid and status='scheduled'),'Only replacement attendance reminders remain scheduled';
end $$;
select public.pal_action(current_setting('pal.rsvp.group')::uuid,'plan.rsvp',jsonb_build_object('id',current_setting('pal.rsvp.plan'),'status','maybe'));
select set_config('pal.rsvp.second_place',(public.pal_action(current_setting('pal.rsvp.group')::uuid,'place.save','{"name":"Cafe","address":"2 Main St","latitude":37.8,"longitude":-122.4,"provider":"apple","provider_id":"pal-rsvp-cafe"}'))->>'id',true);
select public.pal_action(current_setting('pal.rsvp.group')::uuid,'plan.update',jsonb_build_object('id',current_setting('pal.rsvp.plan'),'place_id',current_setting('pal.rsvp.second_place')));
reset role;
delete from public.group_members where group_id=current_setting('pal.rsvp.group')::uuid and user_id='b2000000-0000-4000-8000-000000000009';
set local role authenticated;
select public.pal_action(current_setting('pal.rsvp.group')::uuid,'plan.update',jsonb_build_object('id',current_setting('pal.rsvp.plan'),'ends_at','2030-01-05T07:00:00Z'));
do $$ begin
  assert (select count(*)=7 from public.messages where group_id=current_setting('pal.rsvp.group')::uuid and source_key like 'plan-rsvp:%'),'Venue changes and end-time changes both request new attendance; eight remaining members fit one message';
  assert (select jsonb_array_length(mentions)=8 and body like '%at Cafe%' from public.messages where group_id=current_setting('pal.rsvp.group')::uuid and source_key like 'plan-rsvp:%:6:%'),'The latest request includes only current members and current venue';
  assert not exists(select 1 from public.plan_rsvps where plan_id=current_setting('pal.rsvp.plan')::uuid),'Venue changes also clear prior attendance';
end $$;
select public.pal_action(current_setting('pal.rsvp.group')::uuid,'plan.confirm',jsonb_build_object('id',current_setting('pal.rsvp.plan')));
select public.pal_action(current_setting('pal.rsvp.group')::uuid,'plan.cancel',jsonb_build_object('id',current_setting('pal.rsvp.plan')));
reset role;
update public.plans set status='confirmed',starts_at=now()-interval '1 hour',version=version+1 where id=current_setting('pal.rsvp.plan')::uuid;
do $$ begin
  assert (select count(*)=7 from public.messages where group_id=current_setting('pal.rsvp.group')::uuid and source_key like 'plan-rsvp:%'),'Repeated confirmation, cancellation and expired fixtures never send another request';
  assert not exists(select 1 from public.messages where group_id=current_setting('pal.rsvp.other')::uuid and source_key like 'plan-rsvp:%'),'No cross-group request is posted';
end $$;
set local role authenticated;
select set_config('pal.rsvp.direct',(public.ensure_pal_direct()).id::text,true);
select set_config('pal.rsvp.direct_plan',(public.pal_action(current_setting('pal.rsvp.direct')::uuid,'plan.create',jsonb_build_object('title','Personal meetup','starts_at',now()+interval '3 days')))->>'id',true);
select public.pal_action(current_setting('pal.rsvp.direct')::uuid,'plan.confirm',jsonb_build_object('id',current_setting('pal.rsvp.direct_plan')));
do $$ begin
  assert (select count(*)=1 from public.messages where group_id=current_setting('pal.rsvp.direct')::uuid and source_key like 'plan-rsvp:%'),'A private plan only asks its owner';
  assert (select mentions=jsonb_build_array(jsonb_build_object('type','user','user_id',auth.uid())) from public.messages where group_id=current_setting('pal.rsvp.direct')::uuid and source_key like 'plan-rsvp:%'),'Private chat never imports other-group members';
end $$;
rollback;
