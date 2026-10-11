-- Preserve shared URLs; normalize tracking only. Internal weekly jobs never notify.
create or replace function private.pal_canonical_url(p_url text) returns text
language plpgsql immutable set search_path='' as $$
declare u text; parts text[];
begin
  if p_url is null then return null; end if;
  if length(p_url)>2000 or p_url !~ '^https?://[^[:space:]/?#]+' then raise exception 'Valid HTTP URL required' using errcode='22023'; end if;
  u:=split_part(p_url,'#',1);
  parts:=regexp_match(u,'^(https?://)([^/?#]+)(.*)$');
  u:=lower(parts[1]||parts[2])||parts[3];
  u:=regexp_replace(u,'([?&])(utm_[^=&]*|igsh|igshid|fbclid|gclid|si|xtok)=[^&]*','\1','gi');
  u:=replace(regexp_replace(u,'&+','&','g'),'?&','?');
  return regexp_replace(u,'[?&/]+$','');
end $$;

create or replace function private.pal_queue_push() returns trigger
language plpgsql security definer set search_path='' as $$
declare r public.reminders; tz text; due timestamptz;
begin
  if new.role='system' and (new.source_key like 'weekly:%' or new.source_key like 'pal:weekly:%') then return new; end if;
  select timezone into tz from public.groups where id=new.group_id;
  if new.source_key like 'reminder:%' then select * into r from public.reminders where id=split_part(new.source_key,':',2)::uuid; end if;
  due:=private.pal_next_awake(now(),tz);
  insert into private.push_outbox(message_id,group_id,user_id,plan_id,payload,next_attempt,source_key)
  select new.id,new.group_id,m.user_id,r.plan_id,
    jsonb_build_object('aps',jsonb_build_object('alert',jsonb_build_object('title','Pal','body',left(new.body,120)),'sound','default'),
      'group_id',new.group_id,'message_id',new.id,'type',new.card->>'type','entity_id',new.card->>'entity_id','reminder_id',r.id,'plan_id',r.plan_id,'poll_id',r.poll_id),
    due,'message:'||new.id||':user:'||m.user_id
  from public.group_members m left join public.profiles p on p.user_id=m.user_id
  where m.group_id=new.group_id and m.user_id is distinct from new.sender_id and coalesce(p.notifications_enabled,true)
    and (r.id is null or cardinality(r.target_user_ids)=0 or m.user_id=any(r.target_user_ids))
    and (r.poll_id is null or not exists(select 1 from public.poll_responses v where v.poll_id=r.poll_id and v.user_id=m.user_id))
    and (r.id is null or r.kind not in ('plan_24h','plan_2h') or exists(select 1 from public.plan_rsvps v where v.plan_id=r.plan_id and v.user_id=m.user_id and v.status='going'))
  on conflict(source_key) do nothing;
  return new;
end $$;
