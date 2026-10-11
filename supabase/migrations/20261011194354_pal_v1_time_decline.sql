-- An explicit empty time response means none work; no response remains unknown.
-- Keep existing grants and action semantics, and retain flat votes for old clients.
create or replace function private.pal_execute_action(p_group_id uuid,p_user_id uuid,p_action text,p_data jsonb,p_agent boolean) returns jsonb
language plpgsql set search_path='' as $$
declare
  g public.groups; rec private.action_receipts; result jsonb; entity uuid; sid uuid; v_key text:=p_data->>'source_key';
  s public.sources; place public.places; poll public.polls; plan public.plans; reminder public.reminders; memory public.member_memories;
  opts jsonb; opt jsonb; votes text[]; targets uuid[]; due timestamptz; tz text; pid text; n integer;
begin
  if p_data is null or jsonb_typeof(p_data)<>'object' or p_user_id is null then raise exception 'Action object and authenticated user required' using errcode='22023'; end if;
  select * into g from public.groups where id=p_group_id for update;
  if not found or not exists(select 1 from public.group_members where group_id=p_group_id and user_id=p_user_id) then raise exception 'Group membership required' using errcode='42501'; end if;
  if p_agent and p_action not in ('reaction.toggle','source.create','source.update','place.save','place.correct','poll.create','plan.create','plan.update','memory.save','memory.delete','reminder.create','reminder.update','reminder.cancel') then
    raise exception 'Agent action requires an explicit member decision' using errcode='42501';
  end if;
  if p_agent and (v_key is null or length(v_key) not between 1 and 200) then raise exception 'Agent source key required' using errcode='22023'; end if;
  if v_key is not null and length(v_key) not between 1 and 200 then raise exception 'Invalid source key' using errcode='22023'; end if;
  if p_agent and p_data ? 'job_id' and not exists(select 1 from public.agent_jobs where id=(p_data->>'job_id')::uuid and group_id=p_group_id and status='running') then raise exception 'Running group job required' using errcode='42501'; end if;
  if v_key is not null then
    select * into rec from private.action_receipts where group_id=p_group_id and user_id=p_user_id and action=p_action and source_key=v_key;
    if found then
      if rec.input<>p_data then raise exception 'Source key already used for another action input' using errcode='22023'; end if;
      return rec.result;
    end if;
  end if;
  entity:=nullif(p_data->>'id','')::uuid;
  sid:=nullif(p_data->>'source_message_id','')::uuid;
  if sid is not null and not exists(select 1 from public.messages where id=sid and group_id=p_group_id) then raise exception 'Source message belongs to another group' using errcode='42501'; end if;
  case p_action
    when 'group.settings' then
      tz:=coalesce(p_data->>'timezone',g.timezone);
      if not exists(select 1 from pg_catalog.pg_timezone_names where name=tz) then raise exception 'Valid IANA timezone required' using errcode='22023'; end if;
      update public.groups set name=coalesce(p_data->>'name',name),timezone=tz,
        proactive_suggestions=coalesce((p_data->>'proactive_suggestions')::boolean,proactive_suggestions),agent_paused=coalesce((p_data->>'agent_paused')::boolean,agent_paused)
      where id=p_group_id returning to_jsonb(groups) into result;
      if (result->>'agent_paused')::boolean then update public.agent_jobs set status='cancelled',lease_until=null where group_id=p_group_id and status in ('queued','running'); end if;
      if not (result->>'proactive_suggestions')::boolean then update public.agent_jobs set status='cancelled',lease_until=null where group_id=p_group_id and status in ('queued','running') and job_kind='weekly'; end if;
    when 'group.read' then
      entity:=(p_data->>'message_id')::uuid;
      if not exists(select 1 from public.messages where id=entity and group_id=p_group_id) then raise exception 'Group message required' using errcode='22023'; end if;
      due:=(select created_at from public.messages where id=entity);
      update public.group_members set last_read_at=due,last_read_message_id=entity where group_id=p_group_id and user_id=p_user_id and (last_read_at is null or last_read_at<=due);
      result:=jsonb_build_object('ok',true,'last_read_at',(select last_read_at from public.group_members where group_id=p_group_id and user_id=p_user_id));
    when 'message.reply' then
      result:=to_jsonb(private.send_message(p_group_id,p_data->>'body',(p_data->>'client_id')::uuid,(p_data->>'reply_to_id')::uuid));
    when 'reaction.toggle' then
      entity:=(p_data->>'message_id')::uuid;
      if not exists(select 1 from public.messages where id=entity and group_id=p_group_id) or coalesce(length(p_data->>'emoji'),0) not between 1 and 16 then raise exception 'Valid group message and emoji required' using errcode='22023'; end if;
      delete from public.message_reactions where message_id=entity and (case when p_agent then actor='pal' else user_id=p_user_id end) and emoji=p_data->>'emoji';
      if found then result:=jsonb_build_object('active',false);
      else
        insert into public.message_reactions(group_id,message_id,user_id,actor,emoji) values(p_group_id,entity,case when p_agent then null else p_user_id end,case when p_agent then 'pal' else 'user' end,p_data->>'emoji');
        result:=jsonb_build_object('active',true);
      end if;
    when 'memory.save' then
      if sid is not null and not exists(select 1 from public.messages where id=sid and group_id=p_group_id and sender_id=p_user_id and role='user') then raise exception 'Memory source must be the member speaking' using errcode='42501'; end if;
      if p_agent and sid is null then raise exception 'Explicit memory source required' using errcode='22023'; end if;
      if entity is not null and not exists(select 1 from public.member_memories where id=entity and group_id=p_group_id and user_id=p_user_id) then raise exception 'Only own memory can be edited' using errcode='42501'; end if;
      if p_data->>'kind'='availability' and (nullif(p_data->>'expires_at','')::timestamptz is null or (p_data->>'expires_at')::timestamptz<=now()) then raise exception 'Dated availability requires a future expiry' using errcode='22023'; end if;
      if entity is not null then
        update public.member_memories set kind=p_data->>'kind',key=btrim(p_data->>'key'),value=btrim(p_data->>'value'),source_message_id=sid,expires_at=nullif(p_data->>'expires_at','')::timestamptz,updated_at=now() where id=entity returning * into memory;
      else
        insert into public.member_memories(group_id,user_id,kind,key,value,source_message_id,expires_at)
        values(p_group_id,p_user_id,p_data->>'kind',btrim(p_data->>'key'),btrim(p_data->>'value'),sid,nullif(p_data->>'expires_at','')::timestamptz)
        on conflict(group_id,user_id,kind,key) do update set value=excluded.value,source_message_id=excluded.source_message_id,expires_at=excluded.expires_at,updated_at=now() returning * into memory;
      end if;
      result:=to_jsonb(memory);
    when 'memory.delete' then
      delete from public.member_memories where id=entity and group_id=p_group_id and user_id=p_user_id returning to_jsonb(member_memories) into result;
      if not found then raise exception 'Only own memory can be deleted' using errcode='42501'; end if;
    when 'source.create' then
      if p_data->>'url' is null then raise exception 'Source URL required' using errcode='22023'; end if;
      if sid is not null and not exists(select 1 from public.messages where id=sid and group_id=p_group_id and sender_id=p_user_id and role='user') then raise exception 'Source must be attributed to the member who shared it' using errcode='42501'; end if;
      insert into public.sources(group_id,created_by,source_message_id,url,canonical_url,title)
      values(p_group_id,p_user_id,sid,p_data->>'url',private.pal_canonical_url(p_data->>'url'),p_data->>'title')
      on conflict(group_id,canonical_url) do update set updated_at=now() returning * into s;
      insert into public.source_contributors(group_id,source_id,user_id,source_message_id) values(p_group_id,s.id,p_user_id,sid) on conflict(source_id,user_id) do nothing;
      perform private.pal_post_card(p_group_id,p_user_id,p_agent,'place',s.id,coalesce(s.title,'Finding places from this link'),v_key);
      result:=to_jsonb(s);
    when 'source.update' then
      select * into s from public.sources where id=entity and group_id=p_group_id for update;
      if not found then raise exception 'Group source required' using errcode='42501'; end if;
      if p_data ? 'place_ids' and exists(select 1 from jsonb_array_elements_text(p_data->'place_ids') x where not exists(select 1 from public.places where id=x::uuid and group_id=p_group_id)) then raise exception 'Group places required' using errcode='42501'; end if;
      update public.sources set title=coalesce(p_data->>'title',title),status=coalesce(p_data->>'status',status),
        candidates=coalesce(p_data->'candidates',candidates),place_ids=case when p_data ? 'place_ids' then array(select x::uuid from jsonb_array_elements_text(p_data->'place_ids') x) else place_ids end,updated_at=now()
      where id=entity returning * into s;
      result:=to_jsonb(s);
    when 'place.save','place.correct' then
      if p_data ? 'website' and p_data->>'website' is not null then perform private.pal_canonical_url(p_data->>'website'); end if;
      if p_data ? 'booking_url' and p_data->>'booking_url' is not null then perform private.pal_canonical_url(p_data->>'booking_url'); end if;
      if p_action='place.correct' then
        select * into place from public.places where id=entity and group_id=p_group_id for update;
        if not found then raise exception 'Group place required' using errcode='42501'; end if;
        update public.places set name=coalesce(p_data->>'name',name),address=coalesce(p_data->>'address',address),
          latitude=coalesce((p_data->>'latitude')::double precision,latitude),longitude=coalesce((p_data->>'longitude')::double precision,longitude),
          provider=coalesce(p_data->>'provider',provider),provider_id=coalesce(p_data->>'provider_id',provider_id),status=coalesce(p_data->>'status',status),
          candidates=coalesce(p_data->'candidates',candidates),website=coalesce(p_data->>'website',website),booking_url=coalesce(p_data->>'booking_url',booking_url),updated_at=now()
        where id=entity returning * into place;
        result:=to_jsonb(place);
      else
        pid:=coalesce(nullif(p_data->>'provider_id',''),'coordinates:'||round((p_data->>'latitude')::numeric,5)||':'||round((p_data->>'longitude')::numeric,5)||':'||lower(btrim(p_data->>'name')));
        insert into public.places(group_id,created_by,name,address,latitude,longitude,provider,provider_id,status,candidates,website,booking_url)
        values(p_group_id,p_user_id,btrim(p_data->>'name'),coalesce(p_data->>'address',''),(p_data->>'latitude')::double precision,(p_data->>'longitude')::double precision,coalesce(p_data->>'provider','apple'),pid,coalesce(p_data->>'status','resolved'),coalesce(p_data->'candidates','[]'),p_data->>'website',p_data->>'booking_url')
        on conflict(group_id,provider,provider_id) do update set updated_at=now() returning * into place;
        entity:=(p_data->>'source_id')::uuid;
        if entity is not null then
          select * into s from public.sources where id=entity and group_id=p_group_id for update;
          if not found then raise exception 'Group source required' using errcode='42501'; end if;
        else
          insert into public.sources(group_id,created_by,title,status,canonical_url) values(p_group_id,p_user_id,place.name,'resolved','pal://place/'||place.provider||'/'||place.provider_id)
          on conflict(group_id,canonical_url) do update set updated_at=now() returning * into s;
        end if;
        insert into public.source_contributors(group_id,source_id,user_id) values(p_group_id,s.id,p_user_id) on conflict(source_id,user_id) do nothing;
        insert into public.place_contributors(group_id,place_id,user_id,source_id) values(p_group_id,place.id,p_user_id,s.id) on conflict do nothing;
        update public.sources set place_ids=case when place.id=any(place_ids) then place_ids else array_append(place_ids,place.id) end,status='resolved',updated_at=now() where id=s.id;
        perform private.pal_post_card(p_group_id,p_user_id,p_agent,'place',s.id,place.name,v_key);
        result:=to_jsonb(place)||jsonb_build_object('source_id',s.id);
      end if;
    when 'place.delete' then
      if exists(select 1 from public.plans where place_id=entity and group_id=p_group_id and status='confirmed') then raise exception 'Remove place from confirmed plans first' using errcode='22023'; end if;
      delete from public.places where id=entity and group_id=p_group_id returning to_jsonb(places) into result;
      if not found then raise exception 'Group place required' using errcode='42501'; end if;
      update public.sources set place_ids=array_remove(place_ids,entity),updated_at=now() where group_id=p_group_id and entity=any(place_ids);
    when 'poll.create' then
      opts:=p_data->'options';
      if jsonb_typeof(opts)<>'array' or jsonb_array_length(opts) not between 2 and 8 then raise exception 'Poll requires 2-8 options' using errcode='22023'; end if;
      for opt in select value from jsonb_array_elements(opts) loop
        if coalesce(length(opt->>'id'),0) not between 1 and 64 or coalesce(length(opt->>'label'),0) not between 1 and 160 then raise exception 'Poll option ID and label required' using errcode='22023'; end if;
        if opt ? 'place_id' and not exists(select 1 from public.places where id=(opt->>'place_id')::uuid and group_id=p_group_id) then raise exception 'Group place required' using errcode='42501'; end if;
        if p_data->>'kind'='time' and (nullif(opt->>'starts_at','')::timestamptz is null or not isfinite((opt->>'starts_at')::timestamptz)) then raise exception 'Time option starts_at required' using errcode='22023'; end if;
      end loop;
      if (select count(distinct value->>'id') from jsonb_array_elements(opts))<>jsonb_array_length(opts) then raise exception 'Option IDs must be unique' using errcode='22023'; end if;
      due:=(p_data->>'deadline_at')::timestamptz;
      if due is null or not isfinite(due) or due<=now() then raise exception 'Future poll deadline required' using errcode='22023'; end if;
      insert into public.polls(group_id,created_by,kind,question,options,deadline_at) values(p_group_id,p_user_id,p_data->>'kind',p_data->>'question',opts,due) returning * into poll;
      insert into public.reminders(group_id,requester_id,body,due_at,timezone,source_key,poll_id,kind)
      values(p_group_id,p_user_id,poll.question,now()+(due-now())/2,g.timezone,'poll:'||poll.id||':halfway',poll.id,'poll_halfway'),
        (p_group_id,p_user_id,poll.question,due,g.timezone,'poll:'||poll.id||':deadline',poll.id,'poll_deadline');
      perform private.pal_post_card(p_group_id,p_user_id,p_agent,case when poll.kind='place' then 'choice' else 'availability' end,poll.id,poll.question,v_key);
      result:=to_jsonb(poll);
    when 'poll.vote' then
      select * into poll from public.polls where id=entity and group_id=p_group_id for update;
      if not found then raise exception 'Group poll required' using errcode='42501'; end if;
      if poll.status<>'open' or poll.deadline_at<=now() then raise exception 'Poll is closed' using errcode='22023'; end if;
      if not p_data ? 'option_ids' or jsonb_typeof(p_data->'option_ids')<>'array' then raise exception 'Explicit poll options array required' using errcode='22023'; end if;
      votes:=array(select distinct x from jsonb_array_elements_text(p_data->'option_ids') x);
      if (cardinality(votes)=0 and poll.kind<>'time') or exists(select 1 from unnest(votes) x where not exists(select 1 from jsonb_array_elements(poll.options) o where o->>'id'=x)) then raise exception 'Select valid poll options' using errcode='22023'; end if;
      insert into public.poll_responses(group_id,poll_id,user_id,option_ids) values(p_group_id,entity,p_user_id,votes)
      on conflict(poll_id,user_id) do update set option_ids=excluded.option_ids,updated_at=now();
      if not exists(select 1 from public.group_members m where m.group_id=p_group_id and not exists(select 1 from public.poll_responses r where r.poll_id=entity and r.user_id=m.user_id)) then
        update public.reminders set status='cancelled',version=version+1 where poll_id=entity and status='scheduled';
        update private.push_outbox set status='cancelled' where group_id=p_group_id and payload->>'poll_id'=entity::text and status in ('queued','sending');
      end if;
      result:=jsonb_build_object('id',entity,'user_id',p_user_id,'option_ids',votes);
    when 'plan.create' then
      if p_data ? 'place_id' and p_data->>'place_id' is not null and not exists(select 1 from public.places where id=(p_data->>'place_id')::uuid and group_id=p_group_id and status='resolved') then raise exception 'Resolved group place required' using errcode='42501'; end if;
      due:=(p_data->>'starts_at')::timestamptz;
      if due is null or due<=now() then raise exception 'Future plan time required' using errcode='22023'; end if;
      insert into public.plans(group_id,created_by,title,place_id,starts_at,ends_at,notes)
      values(p_group_id,p_user_id,p_data->>'title',(p_data->>'place_id')::uuid,due,coalesce((p_data->>'ends_at')::timestamptz,due+interval '1 hour'),coalesce(p_data->>'notes','')) returning * into plan;
      perform private.pal_post_card(p_group_id,p_user_id,p_agent,'plan',plan.id,plan.title,v_key);
      result:=to_jsonb(plan);
    when 'plan.update','plan.confirm','plan.cancel','plan.rsvp','plan.booking' then
      select * into plan from public.plans where id=entity and group_id=p_group_id for update;
      if not found then raise exception 'Group plan required' using errcode='42501'; end if;
      if p_agent and plan.status<>'draft' then raise exception 'Agent can only edit draft plans' using errcode='42501'; end if;
      if p_action='plan.update' then
        if plan.status='cancelled' then raise exception 'Cancelled plan cannot be edited' using errcode='22023'; end if;
        if p_data ? 'place_id' and p_data->>'place_id' is not null and not exists(select 1 from public.places where id=(p_data->>'place_id')::uuid and group_id=p_group_id and status='resolved') then raise exception 'Resolved group place required' using errcode='42501'; end if;
        if (p_data ? 'place_id' and (p_data->>'place_id')::uuid is distinct from plan.place_id) or (p_data ? 'starts_at' and (p_data->>'starts_at')::timestamptz is distinct from plan.starts_at)
          or (p_data ? 'ends_at' and (p_data->>'ends_at')::timestamptz is distinct from plan.ends_at) then
          delete from public.plan_rsvps where plan_id=entity;
        end if;
        update public.plans set title=coalesce(p_data->>'title',title),place_id=case when p_data ? 'place_id' then (p_data->>'place_id')::uuid else place_id end,
          starts_at=coalesce((p_data->>'starts_at')::timestamptz,starts_at),ends_at=coalesce((p_data->>'ends_at')::timestamptz,(p_data->>'starts_at')::timestamptz+(plan.ends_at-plan.starts_at),ends_at),notes=coalesce(p_data->>'notes',notes),version=version+1,updated_at=now()
        where id=entity returning * into plan;
        if plan.starts_at<=now() then raise exception 'Future plan time required' using errcode='22023'; end if;
      elsif p_action='plan.confirm' then
        if plan.status='cancelled' or plan.starts_at<=now() then raise exception 'Future active plan required' using errcode='22023'; end if;
        update public.plans set status='confirmed',version=version+1,updated_at=now() where id=entity returning * into plan;
      elsif p_action='plan.cancel' then
        update public.plans set status='cancelled',version=version+1,updated_at=now() where id=entity returning * into plan;
      elsif p_action='plan.rsvp' then
        if plan.status='cancelled' then raise exception 'Plan is cancelled' using errcode='22023'; end if;
        insert into public.plan_rsvps(group_id,plan_id,user_id,status) values(p_group_id,entity,p_user_id,p_data->>'status')
        on conflict(plan_id,user_id) do update set status=excluded.status,updated_at=now();
      else
        if plan.status<>'confirmed' then raise exception 'Confirm plan before booking' using errcode='22023'; end if;
        if length(coalesce(p_data->>'reference',''))>500 then raise exception 'Booking reference too long' using errcode='22023'; end if;
        update public.plans set booking_status=p_data->>'status',booking_reference=p_data->>'reference',updated_at=now() where id=entity returning * into plan;
      end if;
      if p_action<>'plan.booking' then perform private.pal_sync_plan(entity); end if;
      result:=to_jsonb(plan);
    when 'reminder.create' then
      reminder:=public.create_reminder(p_group_id,p_user_id,p_data->>'body',(p_data->>'due_at')::timestamptz,coalesce(p_data->>'timezone',g.timezone),coalesce(v_key,gen_random_uuid()::text));
      entity:=reminder.id;
      targets:=coalesce(array(select x::uuid from jsonb_array_elements_text(coalesce(p_data->'target_user_ids','[]')) x),'{}');
      if exists(select 1 from unnest(targets) x where not exists(select 1 from public.group_members where group_id=p_group_id and user_id=x)) then raise exception 'Reminder targets must be group members' using errcode='42501'; end if;
      if p_data->>'plan_id' is not null and not exists(select 1 from public.plans where id=(p_data->>'plan_id')::uuid and group_id=p_group_id) then raise exception 'Group plan required' using errcode='42501'; end if;
      if p_data->>'poll_id' is not null and not exists(select 1 from public.polls where id=(p_data->>'poll_id')::uuid and group_id=p_group_id) then raise exception 'Group poll required' using errcode='42501'; end if;
      update public.reminders set target_user_ids=targets,plan_id=(p_data->>'plan_id')::uuid,poll_id=(p_data->>'poll_id')::uuid where id=entity returning * into reminder;
      perform private.pal_post_card(p_group_id,p_user_id,p_agent,'reminder',entity,reminder.body,v_key);
      result:=to_jsonb(reminder);
    when 'reminder.update','reminder.cancel' then
      select * into reminder from public.reminders where id=entity and group_id=p_group_id and requester_id=p_user_id for update;
      if not found then raise exception 'Only own reminder can be changed' using errcode='42501'; end if;
      if reminder.kind<>'reminder' then raise exception 'Change the associated plan or poll instead' using errcode='22023'; end if;
      if reminder.status='completed' then raise exception 'Delivered reminder cannot be changed' using errcode='22023'; end if;
      if p_action='reminder.cancel' then update public.reminders set status='cancelled',version=version+1 where id=entity returning * into reminder;
      else
        due:=coalesce((p_data->>'due_at')::timestamptz,reminder.due_at);tz:=coalesce(p_data->>'timezone',reminder.timezone);
        if not isfinite(due) or due<=now() or not exists(select 1 from pg_catalog.pg_timezone_names where name=tz) then raise exception 'Future time and IANA timezone required' using errcode='22023'; end if;
        targets:=case when p_data ? 'target_user_ids' then array(select x::uuid from jsonb_array_elements_text(p_data->'target_user_ids') x) else reminder.target_user_ids end;
        if exists(select 1 from unnest(targets) x where not exists(select 1 from public.group_members where group_id=p_group_id and user_id=x)) then raise exception 'Group targets required' using errcode='42501'; end if;
        if p_data->>'plan_id' is not null and not exists(select 1 from public.plans where id=(p_data->>'plan_id')::uuid and group_id=p_group_id) then raise exception 'Group plan required' using errcode='42501'; end if;
        if p_data->>'poll_id' is not null and not exists(select 1 from public.polls where id=(p_data->>'poll_id')::uuid and group_id=p_group_id) then raise exception 'Group poll required' using errcode='42501'; end if;
        update public.reminders set body=coalesce(p_data->>'body',body),due_at=due,timezone=tz,target_user_ids=targets,
          plan_id=case when p_data ? 'plan_id' then (p_data->>'plan_id')::uuid else plan_id end,poll_id=case when p_data ? 'poll_id' then (p_data->>'poll_id')::uuid else poll_id end,status='scheduled',version=version+1 where id=entity returning * into reminder;
      end if;
      update private.push_outbox set status='cancelled',lease_until=null where group_id=p_group_id and payload->>'reminder_id'=entity::text and status in ('queued','sending');
      result:=to_jsonb(reminder);
    else raise exception 'Unsupported action %',p_action using errcode='22023';
  end case;
  if v_key is not null then insert into private.action_receipts(group_id,user_id,action,source_key,input,result) values(p_group_id,p_user_id,p_action,v_key,p_data,result); end if;
  return result;
end $$;

create or replace function private.pal_group_state(p_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if current_setting('role',true)<>'service_role' and not exists(select 1 from public.group_members where group_id=p_group_id and user_id=auth.uid()) then
    raise exception 'Group membership required' using errcode='42501';
  end if;
  if not exists(select 1 from public.groups where id=p_group_id) then raise exception 'Group not found' using errcode='22023'; end if;
  return jsonb_build_object(
    'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'display_name',coalesce(p.display_name,'Member'),'avatar_url',p.avatar_url,'last_read_at',m.last_read_at,'last_read_message_id',m.last_read_message_id) order by m.joined_at) from public.group_members m left join public.profiles p on p.user_id=m.user_id where m.group_id=p_group_id),'[]'),
    'places',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('contributors',coalesce((select jsonb_agg(jsonb_build_object('user_id',c.user_id,'source_id',c.source_id)) from public.place_contributors c where c.place_id=p.id),'[]')) order by p.created_at) from public.places p where p.group_id=p_group_id),'[]'),
    'sources',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('contributors',coalesce((select jsonb_agg(to_jsonb(c)) from public.source_contributors c where c.source_id=s.id),'[]')) order by s.created_at) from public.sources s where s.group_id=p_group_id),'[]'),
    'polls',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('responses',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'option_ids',r.option_ids) order by r.user_id) from public.poll_responses r where r.poll_id=p.id),'[]'),'votes',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'option_id',o)) from public.poll_responses r cross join lateral unnest(r.option_ids) o where r.poll_id=p.id),'[]')) order by p.created_at) from public.polls p where p.group_id=p_group_id),'[]'),
    'plans',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('attendees',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'status',r.status)) from public.plan_rsvps r where r.plan_id=p.id),'[]')) order by p.starts_at) from public.plans p where p.group_id=p_group_id),'[]'),
    'memories',coalesce((select jsonb_agg(to_jsonb(m)||jsonb_build_object('body',m.key||': '||m.value) order by m.updated_at) from public.member_memories m where m.group_id=p_group_id and (m.expires_at is null or m.expires_at>now())),'[]'),
    'reminders',coalesce((select jsonb_agg(to_jsonb(r) order by r.due_at) from public.reminders r where r.group_id=p_group_id),'[]'),
    'reactions',coalesce((select jsonb_agg(to_jsonb(r)) from public.message_reactions r where r.group_id=p_group_id),'[]'),
    'settings',(select jsonb_build_object('name',g.name,'timezone',g.timezone,'proactive_suggestions',g.proactive_suggestions,'agent_paused',g.agent_paused) from public.groups g where id=p_group_id)
  );
end $$;
