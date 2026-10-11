-- Questions are persisted inside their delivered messages; suggestions are ordinary reply shortcuts.
create or replace function public.complete_agent_job_with_outputs(p_job_id uuid,p_attempt integer,p_outputs jsonb,p_result text default null) returns boolean
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
      if jsonb_typeof(card)<>'object' or card->>'type' is null or card->>'type' not in ('plan','rsvp','options','choice','availability','question')
        or jsonb_typeof(card->'entity_id') is distinct from 'string' then raise exception 'Valid group card reference required' using errcode='22023'; end if;
      plan_id:=(card->>'entity_id')::uuid;
      if card->>'type'='question' then
        if plan_id<>j.group_id then raise exception 'Question must belong to the current group' using errcode='42501'; end if;
        if exists(select 1 from jsonb_object_keys(card) k where k not in ('type','entity_id','question','suggestions'))
          or jsonb_typeof(card->'question') is distinct from 'string' or length(btrim(card->>'question')) not between 1 and 200
          or jsonb_typeof(card->'suggestions') is distinct from 'array' or jsonb_array_length(card->'suggestions') not between 2 and 4 then
          raise exception 'Short question and two to four suggested answers required' using errcode='22023';
        end if;
        if exists(select 1 from jsonb_array_elements(card->'suggestions') answer where jsonb_typeof(answer)<>'string' or length(btrim(answer#>>'{}')) not between 1 and 60)
          or (select count(distinct lower(btrim(answer#>>'{}'))) from jsonb_array_elements(card->'suggestions') answer)<>jsonb_array_length(card->'suggestions') then
          raise exception 'Suggested answers must be short and unique' using errcode='22023';
        end if;
        card:=jsonb_build_object('type','question','entity_id',j.group_id,'question',btrim(card->>'question'),
          'suggestions',(select jsonb_agg(btrim(answer#>>'{}') order by pos) from jsonb_array_elements(card->'suggestions') with ordinality answers(answer,pos)));
      else
        if exists(select 1 from jsonb_object_keys(card) k where k not in ('type','entity_id')) then raise exception 'Only persisted entity fields allowed' using errcode='22023'; end if;
        if card->>'type' in ('plan','rsvp') then
          perform 1 from public.plans where id=plan_id and group_id=j.group_id and starts_at>now()
            and (status='confirmed' or (card->>'type'='plan' and status='draft')) for share;
          if not found then raise exception 'Plan card requires a future active group plan; RSVP requires confirmation' using errcode='42501'; end if;
        else
          perform 1 from public.polls where id=plan_id and group_id=j.group_id and status='open' and deadline_at>now()
            and kind=case when card->>'type'='availability' then 'time' else 'place' end for share;
          if not found then raise exception 'Options or availability card requires a matching open future group poll' using errcode='42501'; end if;
        end if;
        card:=jsonb_build_object('type',card->>'type','entity_id',plan_id);
      end if;
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
