-- Dedicated test database only. Source-grounded confirmation fixtures roll back.
begin;
insert into auth.users(id,email) values
 ('60000000-0000-4000-8000-000000000001','pal-confirm-owner@example.invalid'),
 ('60000000-0000-4000-8000-000000000002','pal-confirm-speaker@example.invalid'),
 ('60000000-0000-4000-8000-000000000003','pal-confirm-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select set_config('pal.confirm.group',(public.create_group('Confirmation group')).id::text,true);
select set_config('pal.confirm.invite',(select invite_code::text from public.groups where id=current_setting('pal.confirm.group')::uuid),true);
select set_config('pal.confirm.plan',(public.pal_action(current_setting('pal.confirm.group')::uuid,'plan.create',jsonb_build_object('title','Dinner','starts_at',now()+interval '2 days')))->>'id',true);
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000002',true);
select public.join_group(current_setting('pal.confirm.invite')::uuid);
select set_config('pal.confirm.source',(public.send_message(current_setting('pal.confirm.group')::uuid,'Confirm Dinner',gen_random_uuid())).id::text,true);
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000003',true);
select set_config('pal.confirm.other_group',(public.create_group('Other confirmation group')).id::text,true);
select set_config('pal.confirm.other_plan',(public.pal_action(current_setting('pal.confirm.other_group')::uuid,'plan.create',jsonb_build_object('title','Secret dinner','starts_at',now()+interval '2 days')))->>'id',true);
select set_config('pal.confirm.other_source',(public.send_message(current_setting('pal.confirm.other_group')::uuid,'Confirm Dinner',gen_random_uuid())).id::text,true);
reset role;
update public.plans set updated_at=now()-interval '2 seconds' where id=current_setting('pal.confirm.plan')::uuid;
update public.agent_jobs set run_after=now()-interval '1 second' where group_id=current_setting('pal.confirm.group')::uuid;
set local role service_role;
select set_config('pal.confirm.job',(select id::text from public.claim_agent_jobs(20) where group_id=current_setting('pal.confirm.group')::uuid),true);
create function pg_temp.confirm(p_source uuid,p_target uuid,p_response jsonb,p_evidence text default 'Confirm Dinner',p_attempt integer default 1) returns jsonb language sql as $$
  select public.pal_capture_member_response(current_setting('pal.confirm.job')::uuid,p_attempt,p_source,p_evidence,'confirmation',p_target,p_response)
$$;
create function pg_temp.reject_confirmation(p_state text,p_source uuid,p_target uuid,p_response jsonb,p_evidence text default 'Confirm Dinner',p_attempt integer default 1) returns void language plpgsql as $$
begin
  begin
    perform pg_temp.confirm(p_source,p_target,p_response,p_evidence,p_attempt);
  exception when others then
    if sqlstate=p_state then return; end if;
    raise;
  end;
  raise exception 'Expected confirmation error %',p_state;
end $$;
do $$
declare s uuid:=current_setting('pal.confirm.source')::uuid; p uuid:=current_setting('pal.confirm.plan')::uuid; j uuid:=current_setting('pal.confirm.job')::uuid; r jsonb; v integer;
begin
  assert not has_function_privilege('authenticated','public.pal_capture_member_response(uuid,integer,uuid,text,text,uuid,jsonb)','execute'),'Client cannot bypass the verified source tool';
  perform pg_temp.reject_confirmation('22023',s,p,'{"plan_version":1}','Dinner');
  perform pg_temp.reject_confirmation('22023',s,p,'{"plan_version":1,"user_id":"60000000-0000-4000-8000-000000000001"}');
  perform pg_temp.reject_confirmation('22023',s,p,'{"plan_version":2}');
  perform pg_temp.reject_confirmation('22023',s,p,'{}');
  perform pg_temp.reject_confirmation('42501',s,p,'{"plan_version":1}','Confirm Dinner',2);
  perform pg_temp.reject_confirmation('42501',s,current_setting('pal.confirm.other_plan')::uuid,'{"plan_version":1}');
  perform pg_temp.reject_confirmation('42501',current_setting('pal.confirm.other_source')::uuid,p,'{"plan_version":1}');
  update public.agent_jobs set lease_until=now()-interval '1 second' where id=j;
  perform pg_temp.reject_confirmation('42501',s,p,'{"plan_version":1}');
  update public.agent_jobs set lease_until=now()+interval '5 minutes' where id=j;
  update public.plans set updated_at=now()+interval '1 second' where id=p;
  perform pg_temp.reject_confirmation('22023',s,p,'{"plan_version":1}');
  update public.plans set updated_at=now()-interval '2 seconds',status='cancelled' where id=p;
  perform pg_temp.reject_confirmation('22023',s,p,'{"plan_version":1}');
  update public.plans set status='draft',starts_at=now()-interval '1 second' where id=p;
  perform pg_temp.reject_confirmation('22023',s,p,'{"plan_version":1}');
  update public.plans set starts_at=now()+interval '2 days' where id=p;
  delete from public.group_members where group_id=current_setting('pal.confirm.group')::uuid and user_id='60000000-0000-4000-8000-000000000002';
  perform pg_temp.reject_confirmation('42501',s,p,'{"plan_version":1}');
  insert into public.group_members(group_id,user_id) values(current_setting('pal.confirm.group')::uuid,'60000000-0000-4000-8000-000000000002');
  begin
    perform public.pal_agent_action(current_setting('pal.confirm.group')::uuid,'60000000-0000-4000-8000-000000000002','plan.confirm',jsonb_build_object('id',p,'source_key','model-only-confirm'));
    raise exception 'Expected broad agent confirmation to stay blocked';
  exception when insufficient_privilege then null;
  end;
  r:=pg_temp.confirm(s,p,'{"plan_version":1}');
  assert r->>'captured'='true' and r->>'user_id'='60000000-0000-4000-8000-000000000002','Confirmation is attributed to the actual human source speaker';
  assert (select status='confirmed' and version=2 from public.plans where id=p),'Explicit human conversation confirms the current draft';
  assert (select count(*)=1 from private.action_receipts where group_id=current_setting('pal.confirm.group')::uuid and user_id='60000000-0000-4000-8000-000000000002' and action='plan.confirm'),'Private receipt audits the real human confirmation';
  assert not exists(select 1 from public.plan_rsvps where plan_id=p),'Confirmation does not invent anyone attendance';
  assert not exists(select 1 from private.push_outbox where plan_id=p),'Confirmation sends no attendance notifications before an own RSVP';
  assert not exists(select 1 from private.google_sync_items where plan_id=p),'Confirmation creates no personal calendar events before an own RSVP';
  r:=pg_temp.confirm(s,p,'{"plan_version":1}');
  assert r->>'replayed'='true' and (select version=2 from public.plans where id=p),'Same source retry retains the first confirmation without version changes';
  perform pg_temp.reject_confirmation('22023',s,p,'{"plan_version":2}');
  update public.plans set status='cancelled',version=3 where id=p;
  r:=pg_temp.confirm(s,p,'{"plan_version":1}');
  assert r->>'replayed'='true' and (select status='cancelled' and version=3 from public.plans where id=p),'Lost-response retry cannot undo a subsequent cancellation';
end $$;
rollback;
