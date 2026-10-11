-- Dedicated test database only. Inbox fixtures and membership changes roll back.
begin;
insert into auth.users(id,email) values
 ('b9000000-0000-4000-8000-000000000001','inbox-owner@example.invalid'),
 ('b9000000-0000-4000-8000-000000000002','inbox-friend@example.invalid'),
 ('b9000000-0000-4000-8000-000000000003','inbox-outsider@example.invalid');
insert into public.groups(id,name,creator_id,created_at) values
 ('b9100000-0000-4000-8000-000000000001','Shared dinner','b9000000-0000-4000-8000-000000000001',now()-interval '3 days'),
 ('b9100000-0000-4000-8000-000000000002','Empty room','b9000000-0000-4000-8000-000000000001',now()-interval '2 days'),
 ('b9100000-0000-4000-8000-000000000003','OUTSIDER SECRET','b9000000-0000-4000-8000-000000000003',now()-interval '1 day');
insert into public.group_members(group_id,user_id,last_read_at) values
 ('b9100000-0000-4000-8000-000000000001','b9000000-0000-4000-8000-000000000001',now()-interval '1 minute'),
 ('b9100000-0000-4000-8000-000000000001','b9000000-0000-4000-8000-000000000002',null),
 ('b9100000-0000-4000-8000-000000000002','b9000000-0000-4000-8000-000000000001',null),
 ('b9100000-0000-4000-8000-000000000003','b9000000-0000-4000-8000-000000000003',null);
insert into public.messages(group_id,sender_id,role,body,created_at,source_key) values
 ('b9100000-0000-4000-8000-000000000001','b9000000-0000-4000-8000-000000000002','user','Already read',now()-interval '2 minutes',null),
 ('b9100000-0000-4000-8000-000000000001','b9000000-0000-4000-8000-000000000002','user','Friday?',now()-interval '5 seconds',null),
 ('b9100000-0000-4000-8000-000000000001',null,'pal','What time?',now()-interval '4 seconds',null),
 ('b9100000-0000-4000-8000-000000000001','b9000000-0000-4000-8000-000000000001','user','Own latest message',now()-interval '1 second',null),
 ('b9100000-0000-4000-8000-000000000001',null,'system','INTERNAL WEEKLY',now(),'weekly:inbox-test'),
 ('b9100000-0000-4000-8000-000000000001',null,'pal','INTERNAL WEEKLY REPLY',now(),'pal:weekly:inbox-test'),
 ('b9100000-0000-4000-8000-000000000003','b9000000-0000-4000-8000-000000000003','user','PRIVATE MESSAGE',now(),null);
set local role authenticated;
select set_config('request.jwt.claim.sub','b9000000-0000-4000-8000-000000000001',true);
do $$
declare inbox jsonb; room jsonb; direct_id uuid;
begin
  inbox:=public.pal_inbox();
  assert jsonb_array_length(inbox)=3,'Inbox contains only current memberships and the ensured private chat';
  assert inbox->0->>'is_direct'='true' and inbox->0->>'name'='Pal','Private Pal chat opens the ordered inbox';
  assert inbox->0->'invite_code'='null'::jsonb,'Private invitation is never exposed';
  assert inbox->1->>'name'='Shared dinner' and inbox->2->>'name'='Empty room','Existing shared-room ordering is preserved';
  room:=inbox->1;
  assert room->'last_message'->>'body'='Own latest message','Internal weekly records cannot become the preview';
  assert (room->>'unread_count')::integer=2,'Unread excludes own, read and internal weekly messages while counting Pal';
  assert room->'last_read_at'<>'null'::jsonb and room->'invite_code'<>'null'::jsonb,'Shared-room response preserves read state and invite';
  assert inbox->2->'last_message'='null'::jsonb and inbox->2->>'unread_count'='0','Empty room has honest empty summary';
  direct_id:=(inbox->0->>'id')::uuid;
  assert public.pal_inbox()->0->>'id'=direct_id::text,'Repeated reads reuse the same private chat';
  assert (select count(*)=1 from public.groups where creator_id=auth.uid() and is_direct),'Repeated reads do not duplicate private rooms';
  assert not has_function_privilege('anon','public.pal_inbox()','execute') and
    not has_function_privilege('service_role','public.pal_inbox()','execute'),'Client inbox is not a service or anonymous endpoint';
end $$;
select set_config('request.jwt.claim.sub','b9000000-0000-4000-8000-000000000002',true);
do $$
declare inbox jsonb;
begin
  inbox:=public.pal_inbox();
  assert jsonb_array_length(inbox)=2,'Friend sees their own private room and the shared room only';
  assert (inbox->0->>'creator_id')::uuid=auth.uid(),'A different owner never sees the first private chat';
  assert inbox->1->>'unread_count'='2','A member with no read marker counts the other user and Pal, not their own texts';
end $$;
reset role;
delete from public.group_members where group_id='b9100000-0000-4000-8000-000000000001' and user_id='b9000000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','b9000000-0000-4000-8000-000000000001',true);
do $$
begin
  assert jsonb_array_length(public.pal_inbox())=2,'Revoked membership takes effect on the next read without a cache';
end $$;
select set_config('request.jwt.claim.sub','',true);
do $$
begin
  begin
    perform public.pal_inbox();
    raise exception 'Expected missing authenticated identity rejection';
  exception when insufficient_privilege then null;
  end;
end $$;
rollback;
