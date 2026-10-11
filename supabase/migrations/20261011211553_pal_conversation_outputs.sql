-- Structured mentions and ordered Pal messages reuse the existing secured chat flow.
alter table public.messages add column mentions jsonb not null default '[]'::jsonb check(jsonb_typeof(mentions)='array');

create function private.pal_mentions_for_group(p_group_id uuid,p_mentions jsonb,p_allow_pal boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare item jsonb; normalized jsonb:='[]'; uid uuid; value jsonb;
begin
  if p_mentions is null or jsonb_typeof(p_mentions)<>'array' or jsonb_array_length(p_mentions)>8 then raise exception 'At most eight structured mentions required' using errcode='22023'; end if;
  for item in select x from jsonb_array_elements(p_mentions) x loop
    if jsonb_typeof(item)<>'object' or item->>'type' is null or item->>'type' not in ('user','pal') then raise exception 'Valid mention target required' using errcode='22023'; end if;
    if item->>'type'='pal' then
      if not p_allow_pal or exists(select 1 from jsonb_object_keys(item) k where k<>'type') then raise exception 'Only humans may mention Pal' using errcode='22023'; end if;
      value:=jsonb_build_object('type','pal');
    else
      if exists(select 1 from jsonb_object_keys(item) k where k not in ('type','user_id')) or jsonb_typeof(item->'user_id') is distinct from 'string'
        or item->>'user_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'User mention identity required' using errcode='22023'; end if;
      uid:=(item->>'user_id')::uuid;
      if not exists(select 1 from public.group_members where group_id=p_group_id and user_id=uid) then raise exception 'Mention must target a current group member' using errcode='42501'; end if;
      value:=jsonb_build_object('type','user','user_id',uid);
    end if;
    if normalized @> jsonb_build_array(value) then raise exception 'Duplicate mention target' using errcode='22023'; end if;
    normalized:=normalized||jsonb_build_array(value);
  end loop;
  return coalesce((select jsonb_agg(x order by x->>'type',x->>'user_id') from jsonb_array_elements(normalized) x),'[]');
end $$;
revoke all on function private.pal_mentions_for_group(uuid,jsonb,boolean) from public,anon,authenticated,service_role;

create function private.pal_message_references() returns trigger language plpgsql security definer set search_path='' as $$
begin
  new.mentions:=private.pal_mentions_for_group(new.group_id,new.mentions,new.role='user');
  if new.reply_to_id is not null and not exists(select 1 from public.messages where id=new.reply_to_id and group_id=new.group_id and role in ('user','pal')) then
    raise exception 'Reply must reference a human or Pal message in the same group' using errcode='42501';
  end if;
  return new;
end $$;
revoke all on function private.pal_message_references() from public,anon,authenticated,service_role;
create trigger pal_message_references before insert or update of mentions,reply_to_id,group_id,role on public.messages for each row execute function private.pal_message_references();

create function private.send_message(p_group_id uuid,p_body text,p_client_id uuid,p_reply_to_id uuid,p_mentions jsonb) returns public.messages
language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); m public.messages; targets jsonb;
begin
  perform 1 from public.groups where id=p_group_id for update;
  if not found or u is null or not exists(select 1 from public.group_members where group_id=p_group_id and user_id=u) then raise exception 'Group membership required' using errcode='42501'; end if;
  targets:=private.pal_mentions_for_group(p_group_id,p_mentions,true);
  select * into m from public.messages where group_id=p_group_id and sender_id=u and client_id=p_client_id;
  if found and m.mentions<>targets then raise exception 'Client ID already used for other mention targets' using errcode='22023'; end if;
  m:=private.send_message(p_group_id,p_body,p_client_id,p_reply_to_id);
  if m.mentions<>targets then update public.messages set mentions=targets where id=m.id returning * into m; end if;
  if targets @> '[{"type":"pal"}]'::jsonb then
    update public.agent_jobs set explicit_mention=true,run_after=now() where message_id=m.id and status='queued';
  end if;
  return m;
end $$;
create function public.send_message(p_group_id uuid,p_body text,p_client_id uuid,p_reply_to_id uuid,p_mentions jsonb) returns public.messages
language sql set search_path='' as $$ select private.send_message(p_group_id,p_body,p_client_id,p_reply_to_id,p_mentions) $$;
revoke all on function public.send_message(uuid,text,uuid,uuid,jsonb),private.send_message(uuid,text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.send_message(uuid,text,uuid,uuid,jsonb),private.send_message(uuid,text,uuid,uuid,jsonb) to authenticated;

create function private.send_attachment_with_mentions(
  p_group_id uuid,p_user_id uuid,p_client_id uuid,p_object_path text,p_kind text,p_mime_type text,
  p_byte_size bigint,p_width integer,p_height integer,p_duration_ms integer,p_sha256 text,p_mentions jsonb,
  p_body text default null,p_reply_to_id uuid default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.messages; targets jsonb; result jsonb;
begin
  if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
  perform 1 from public.groups where id=p_group_id for update;
  if not found or p_user_id is null or not exists(select 1 from public.group_members where group_id=p_group_id and user_id=p_user_id) then raise exception 'Group membership required' using errcode='42501'; end if;
  targets:=private.pal_mentions_for_group(p_group_id,p_mentions,true);
  select * into m from public.messages where group_id=p_group_id and sender_id=p_user_id and client_id=p_client_id;
  if found and m.mentions<>targets then raise exception 'Client ID already used for other mention targets' using errcode='22023'; end if;
  result:=private.send_attachment(p_group_id,p_user_id,p_client_id,p_object_path,p_kind,p_mime_type,p_byte_size,p_width,p_height,p_duration_ms,p_sha256,p_body,p_reply_to_id);
  select * into m from public.messages where id=(result->'message'->>'id')::uuid;
  if m.mentions<>targets then update public.messages set mentions=targets where id=m.id returning * into m; end if;
  if targets @> '[{"type":"pal"}]'::jsonb then update public.agent_jobs set explicit_mention=true,run_after=now() where message_id=m.id and status='queued'; end if;
  return jsonb_set(result,'{message}',to_jsonb(m));
end $$;
create function public.send_attachment_with_mentions(
  p_group_id uuid,p_user_id uuid,p_client_id uuid,p_object_path text,p_kind text,p_mime_type text,
  p_byte_size bigint,p_width integer,p_height integer,p_duration_ms integer,p_sha256 text,p_mentions jsonb,
  p_body text default null,p_reply_to_id uuid default null
) returns jsonb language sql set search_path='' as $$
  select private.send_attachment_with_mentions(p_group_id,p_user_id,p_client_id,p_object_path,p_kind,p_mime_type,p_byte_size,p_width,p_height,p_duration_ms,p_sha256,p_mentions,p_body,p_reply_to_id)
$$;
revoke all on function public.send_attachment_with_mentions(uuid,uuid,uuid,text,text,text,bigint,integer,integer,integer,text,jsonb,text,uuid),private.send_attachment_with_mentions(uuid,uuid,uuid,text,text,text,bigint,integer,integer,integer,text,jsonb,text,uuid) from public,anon,authenticated;
grant execute on function public.send_attachment_with_mentions(uuid,uuid,uuid,text,text,text,bigint,integer,integer,integer,text,jsonb,text,uuid),private.send_attachment_with_mentions(uuid,uuid,uuid,text,text,text,bigint,integer,integer,integer,text,jsonb,text,uuid) to service_role;

create function public.complete_agent_job_with_outputs(p_job_id uuid,p_attempt integer,p_outputs jsonb,p_result text default null) returns boolean
language plpgsql security definer set search_path='' as $$
declare j public.agent_jobs; output jsonb; targets jsonb; reply_id uuid; plan_id uuid; tone text; card jsonb; body text; total integer:=0; part integer:=0; stamp timestamptz;
begin
  if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
  if p_outputs is null or jsonb_typeof(p_outputs)<>'array' or jsonb_array_length(p_outputs)>3 then raise exception 'Zero to three Pal outputs required' using errcode='22023'; end if;
  select * into j from public.agent_jobs where id=p_job_id;
  if not found then return false; end if;
  perform 1 from public.groups where id=j.group_id and not agent_paused for update;
  if not found then return false; end if;
  select * into j from public.agent_jobs where id=p_job_id and attempts=p_attempt and status='running' and lease_until>now() for update;
  if not found then return false; end if;
  if not exists(select 1 from public.group_members where group_id=j.group_id and user_id=j.requester_id) then return false; end if;
  if j.job_kind='weekly' and not exists(select 1 from public.groups where id=j.group_id and proactive_suggestions) then return false; end if;
  stamp:=clock_timestamp();
  for output in select x from jsonb_array_elements(p_outputs) x loop
    if jsonb_typeof(output)<>'object' or exists(select 1 from jsonb_object_keys(output) k where k not in ('body','emotion','reply_to_id','mentions','card')) then raise exception 'Valid Pal output fields required' using errcode='22023'; end if;
    if jsonb_typeof(output->'body') is distinct from 'string' then raise exception 'Pal output text required' using errcode='22023'; end if;
    body:=btrim(output->>'body'); total:=total+length(body);
    if length(body) not between 1 and 4000 or total>4000 then raise exception 'Pal outputs must contain at most 4000 text characters total' using errcode='22023'; end if;
    tone:=coalesce(output->>'emotion','fier');
    if tone not in ('fier','heureux','hilare','curieux','confus','surpris','timide','triste','colere','somnolent','attentif','neutre') then raise exception 'Valid mascot emotion required' using errcode='22023'; end if;
    targets:=private.pal_mentions_for_group(j.group_id,coalesce(output->'mentions','[]'),false);
    reply_id:=(output->>'reply_to_id')::uuid;
    if reply_id is not null and not exists(select 1 from public.messages where id=reply_id and group_id=j.group_id and role in ('user','pal')) then raise exception 'Same-group human or Pal reply required' using errcode='42501'; end if;
    card:=null;
    if output->'card' is not null and output->'card'<>'null'::jsonb then
      card:=output->'card';
      if jsonb_typeof(card)<>'object' or card->>'type' is distinct from 'rsvp' or exists(select 1 from jsonb_object_keys(card) k where k not in ('type','entity_id')) or jsonb_typeof(card->'entity_id') is distinct from 'string' then raise exception 'Only a persisted RSVP card is allowed' using errcode='22023'; end if;
      plan_id:=(card->>'entity_id')::uuid;
      perform 1 from public.plans where id=plan_id and group_id=j.group_id and status='confirmed' and starts_at>now() for share;
      if not found then raise exception 'RSVP card requires a confirmed future plan in the same group' using errcode='42501'; end if;
      card:=jsonb_build_object('type','rsvp','entity_id',plan_id);
    end if;
    part:=part+1;
    insert into public.messages(group_id,role,body,source_key,emotion,reply_to_id,mentions,card,created_at)
    values(j.group_id,'pal',body,'job:'||j.id||case when part=1 then '' else ':part:'||part end,tone,reply_id,targets,card,stamp+(part-1)*interval '1 millisecond')
    on conflict(group_id,source_key) do nothing;
  end loop;
  update public.agent_jobs set status='completed',result=p_result,lease_until=null,completed_at=now() where id=j.id;
  return true;
end $$;
revoke all on function public.complete_agent_job_with_outputs(uuid,integer,jsonb,text) from public,anon,authenticated;
grant execute on function public.complete_agent_job_with_outputs(uuid,integer,jsonb,text) to service_role;

-- Change only the reply delegation inside the existing action dispatcher, keeping
-- every current action's permission, receipt, scheduling and version checks.
do $$
declare definition text:=pg_get_functiondef('private.pal_execute_action(uuid,uuid,text,jsonb,boolean)'::regprocedure);
  prior text:=$needle$result:=to_jsonb(private.send_message(p_group_id,p_data->>'body',(p_data->>'client_id')::uuid,(p_data->>'reply_to_id')::uuid));$needle$;
  replacement text:=$needle$result:=to_jsonb(private.send_message(p_group_id,p_data->>'body',(p_data->>'client_id')::uuid,(p_data->>'reply_to_id')::uuid,coalesce(p_data->'mentions','[]'::jsonb)));$needle$;
begin
  if (length(definition)-length(replace(definition,prior,'')))/length(prior)<>1 then raise exception 'Expected one existing reply delegate in Pal action dispatcher'; end if;
  execute replace(definition,prior,replacement);
end $$;

create function private.pal_reply_job_ready() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.job_kind='chat' and exists(select 1 from public.messages source join public.messages target on target.id=source.reply_to_id and target.group_id=source.group_id
    where source.id=new.message_id and source.group_id=new.group_id and source.role='user' and target.role='pal') then
    new.explicit_mention:=true; new.run_after:=now();
  end if;
  return new;
end $$;
revoke all on function private.pal_reply_job_ready() from public,anon,authenticated,service_role;
create trigger pal_reply_job_ready before insert on public.agent_jobs for each row execute function private.pal_reply_job_ready();
