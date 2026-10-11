-- Explicit conversational confirmation follows the actual member action path.
create or replace function private.pal_capture_member_response(
  p_job_id uuid,p_job_attempt integer,p_source_message_id uuid,p_evidence text,
  p_target_kind text,p_target_id uuid,p_response jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.agent_jobs; source public.messages; poll public.polls; plan public.plans;
  prior_source uuid; prior_updated timestamptz; effective_prior timestamptz; key text; v_action text;
  data jsonb; result jsonb; receipt private.action_receipts; choices jsonb; prior_context text;
begin
  if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
  select * into j from public.agent_jobs where id=p_job_id;
  if not found then raise exception 'Running group job required' using errcode='42501'; end if;
  perform 1 from public.groups where id=j.group_id and not agent_paused for update;
  if not found then raise exception 'Active group required' using errcode='42501'; end if;
  select * into j from public.agent_jobs where id=p_job_id and status='running' and attempts=p_job_attempt and lease_until>now() for update;
  if not found then raise exception 'Active job lease and attempt required' using errcode='42501'; end if;
  select * into source from public.messages where id=p_source_message_id and group_id=j.group_id and role='user' and sender_id is not null and id=any(j.batch_message_ids);
  if not found or not exists(select 1 from public.group_members where group_id=j.group_id and user_id=source.sender_id) then raise exception 'Frozen batch human speaker required' using errcode='42501'; end if;
  if p_evidence is null or length(p_evidence) not between 1 and 2000 or p_evidence<>btrim(source.body) then raise exception 'Entire source message evidence required' using errcode='22023'; end if;
  if p_response is null or jsonb_typeof(p_response)<>'object' then raise exception 'Response object required' using errcode='22023'; end if;
  if p_target_kind='poll' then
    if exists(select 1 from jsonb_object_keys(p_response) k where k not in ('kind','option_ids')) then raise exception 'Only poll response fields allowed' using errcode='22023'; end if;
    select * into poll from public.polls where id=p_target_id and group_id=j.group_id for update;
    if not found then raise exception 'Same-group poll required' using errcode='42501'; end if;
    if poll.status<>'open' or poll.deadline_at<=now() or source.created_at<poll.created_at then raise exception 'Source must respond to a current open poll' using errcode='22023'; end if;
    case p_response->>'kind'
      when 'options' then
        if jsonb_typeof(p_response->'option_ids') is distinct from 'array' or jsonb_array_length(p_response->'option_ids')=0 then raise exception 'Explicit selected options required' using errcode='22023'; end if;
        if exists(select 1 from jsonb_array_elements(p_response->'option_ids') x where jsonb_typeof(x)<>'string') then raise exception 'Option IDs must be strings' using errcode='22023'; end if;
        choices:=p_response->'option_ids';
      when 'either' then
        select jsonb_agg(o->>'id' order by o->>'id') into choices from jsonb_array_elements(poll.options) o;
      when 'none' then
        if poll.kind<>'time' then raise exception 'Decline all is available only for time polls' using errcode='22023'; end if;
        if p_response ? 'option_ids' and p_response->'option_ids'<>'[]'::jsonb then raise exception 'Decline all cannot select options' using errcode='22023'; end if;
        choices:='[]';
      else raise exception 'Valid poll response kind required' using errcode='22023';
    end case;
    if exists(select 1 from jsonb_array_elements_text(choices) x where not exists(select 1 from jsonb_array_elements(poll.options) o where o->>'id'=x)) then raise exception 'Select valid target poll options' using errcode='22023'; end if;
    select coalesce(jsonb_agg(x order by x),'[]') into choices from (select distinct value as x from jsonb_array_elements_text(choices)) c;
    v_action:='poll.vote';
    data:=jsonb_build_object('id',p_target_id,'option_ids',choices);
    select source_message_id,updated_at into prior_source,prior_updated from public.poll_responses where poll_id=p_target_id and user_id=source.sender_id;
  elsif p_target_kind='plan' then
    if exists(select 1 from jsonb_object_keys(p_response) k where k not in ('status','plan_version')) then raise exception 'Only own RSVP fields allowed' using errcode='22023'; end if;
    select * into plan from public.plans where id=p_target_id and group_id=j.group_id for update;
    if not found then raise exception 'Same-group plan required' using errcode='42501'; end if;
    if plan.status<>'confirmed' or plan.starts_at is null or plan.starts_at<=now() or source.created_at<plan.updated_at then raise exception 'Source must respond to a current confirmed future plan' using errcode='22023'; end if;
    if jsonb_typeof(p_response->'plan_version') is distinct from 'number' or p_response->>'plan_version' !~ '^[1-9][0-9]{0,8}$' or (p_response->>'plan_version')::integer<>plan.version then raise exception 'Current plan version required' using errcode='22023'; end if;
    if p_response->>'status' is null or p_response->>'status' not in ('going','maybe','declined') then raise exception 'Valid own RSVP required' using errcode='22023'; end if;
    v_action:='plan.rsvp';
    data:=jsonb_build_object('id',p_target_id,'status',p_response->>'status','plan_version',plan.version);
    select source_message_id,updated_at into prior_source,prior_updated from public.plan_rsvps where plan_id=p_target_id and user_id=source.sender_id;
  elsif p_target_kind='confirmation' then
    if exists(select 1 from jsonb_object_keys(p_response) k where k<>'plan_version') then raise exception 'Only plan confirmation version allowed' using errcode='22023'; end if;
    if jsonb_typeof(p_response->'plan_version') is distinct from 'number' or p_response->>'plan_version' !~ '^[1-9][0-9]{0,8}$' then raise exception 'Current draft plan version required' using errcode='22023'; end if;
    select * into plan from public.plans where id=p_target_id and group_id=j.group_id for update;
    if not found then raise exception 'Same-group draft plan required' using errcode='42501'; end if;
    v_action:='plan.confirm';
    data:=jsonb_build_object('id',p_target_id,'plan_version',(p_response->>'plan_version')::integer);
    -- Confirmation changes the plan's version/status. Check the source receipt
    -- first so a transport retry cannot reconfirm or undo a later human edit.
    key:='capture:'||source.id||':'||p_target_kind||':'||p_target_id;
    select * into receipt from private.action_receipts r where r.group_id=j.group_id and r.user_id=source.sender_id and r.action=v_action and r.source_key=key;
    if found then
      if receipt.input<>data||jsonb_build_object('source_key',key,'source_message_id',source.id,'evidence',p_evidence,'source_created_at',source.created_at) then raise exception 'Source already captured with another confirmation' using errcode='22023'; end if;
      return receipt.result||jsonb_build_object('captured',true,'replayed',true,'source_message_id',source.id,'user_id',source.sender_id);
    end if;
    if plan.status<>'draft' or plan.starts_at is null or plan.starts_at<=now() or source.created_at<plan.updated_at then raise exception 'Source must confirm a current future draft' using errcode='22023'; end if;
    if (p_response->>'plan_version')::integer<>plan.version then raise exception 'Current draft plan version required' using errcode='22023'; end if;
  else raise exception 'Only poll, plan and confirmation responses can be captured' using errcode='22023';
  end if;
  if prior_source is not null then select created_at into effective_prior from public.messages where id=prior_source;
  else effective_prior:=prior_updated;
  end if;
  if prior_source is distinct from source.id and effective_prior>source.created_at then return jsonb_build_object('captured',false,'reason','newer_response'); end if;
  key:='capture:'||source.id||':'||p_target_kind||':'||p_target_id;
  data:=data||jsonb_build_object('source_key',key,'source_message_id',source.id,'evidence',p_evidence,'source_created_at',source.created_at);
  select * into receipt from private.action_receipts r where r.group_id=j.group_id and r.user_id=source.sender_id and r.action=v_action and r.source_key=key;
  if found then
    if receipt.input<>data then raise exception 'Source already captured with another response' using errcode='22023'; end if;
    return receipt.result||jsonb_build_object('captured',true,'replayed',true,'source_message_id',source.id,'user_id',source.sender_id);
  end if;
  prior_context:=current_setting('pal.capture_source_message_id',true);
  perform set_config('pal.capture_source_message_id',source.id::text,true);
  begin
    result:=private.pal_execute_action(j.group_id,source.sender_id,v_action,data,false);
  exception when others then
    perform set_config('pal.capture_source_message_id',coalesce(prior_context,''),true);
    raise;
  end;
  perform set_config('pal.capture_source_message_id',coalesce(prior_context,''),true);
  return result||jsonb_build_object('captured',true,'source_message_id',source.id,'user_id',source.sender_id);
end $$;
revoke all on function public.pal_capture_member_response(uuid,integer,uuid,text,text,uuid,jsonb),private.pal_capture_member_response(uuid,integer,uuid,text,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.pal_capture_member_response(uuid,integer,uuid,text,text,uuid,jsonb),private.pal_capture_member_response(uuid,integer,uuid,text,text,uuid,jsonb) to service_role;
