-- A shared link can be queued without posting a fake Pal progress message.
create or replace function private.pal_post_card(p_group_id uuid,p_user_id uuid,p_agent boolean,
 p_type text,p_entity_id uuid,p_body text,p_source_key text) returns void
language sql set search_path='' as $$
 insert into public.messages(group_id,sender_id,role,body,card,source_key)
 select p_group_id,case when p_agent then null else p_user_id end,
  case when p_agent then 'pal' else 'system' end,p_body,
  jsonb_build_object('type',p_type,'entity_id',p_entity_id),
  'card:'||p_type||':'||p_entity_id||case when p_type='place' then '' else ':'||coalesce(p_source_key,gen_random_uuid()::text) end
 where not (p_type='place' and (p_body='Finding places from this link' or exists(
   select 1 from public.sources s where s.id=p_entity_id and s.group_id=p_group_id
   and s.status in ('pending','resolving'))))
 on conflict(group_id,source_key) do nothing
$$;

-- Completion and its short reply commit together; retries never post twice.
create function private.pal_source_reply(p_id uuid,p_attempt integer,p_reply jsonb) returns void
language plpgsql set search_path='' as $$
declare s public.sources; body text; emotion text; quoted uuid;
begin
 if current_setting('role',true)<>'service_role' then raise exception 'Service only' using errcode='42501'; end if;
 select src.* into s from public.sources src join public.group_members m
  on m.group_id=src.group_id and m.user_id=src.created_by
  join public.groups g on g.id=src.group_id
  where src.id=p_id and src.attempts=p_attempt and src.status in ('resolved','needs_confirmation','failed') and not g.agent_paused;
 if not found then return; end if;
 if jsonb_typeof(p_reply)<>'object' or p_reply-array['body','emotion']<>'{}'::jsonb
  or jsonb_typeof(p_reply->'body') is distinct from 'string' then
  raise exception 'A short completed-source reply is required' using errcode='22023';
 end if;
 body:=btrim(p_reply->>'body'); emotion:=coalesce(p_reply->>'emotion','curieux');
 if length(body) not between 1 and 320 or emotion not in
  ('fier','heureux','hilare','curieux','confus','surpris','timide','triste','colere','somnolent','attentif','neutre') then
  raise exception 'Invalid source reply' using errcode='22023';
 end if;
 select id into quoted from public.messages where id=s.source_message_id and group_id=s.group_id and role='user';
 insert into public.messages(group_id,sender_id,role,body,source_key,emotion,reply_to_id)
 values(s.group_id,null,'pal',body,'pal:source:'||s.id,emotion,quoted)
 on conflict(group_id,source_key) do nothing;
end $$;
revoke all on function private.pal_source_reply(uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function private.pal_source_reply(uuid,integer,jsonb) to service_role;

alter function public.pal_complete_source(uuid,jsonb) rename to pal_complete_source_before_silent;
create function public.pal_complete_source(p_id uuid,p_result jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare result jsonb;
begin
 result:=public.pal_complete_source_before_silent(p_id,p_result);
 if result->>'id' is not null and p_result ? 'reply' then
  perform private.pal_source_reply(p_id,(result->>'attempts')::integer,p_result->'reply');
 end if;
 return result;
end $$;
revoke all on function public.pal_complete_source(uuid,jsonb),public.pal_complete_source_before_silent(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.pal_complete_source(uuid,jsonb),public.pal_complete_source_before_silent(uuid,jsonb) to service_role;
