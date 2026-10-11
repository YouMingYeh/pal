-- A resumed agent may retry a reminder after its due time.
create or replace function public.create_reminder(p_group_id uuid,p_requester_id uuid,p_body text,p_due_at timestamptz,p_timezone text,p_source_key text) returns public.reminders
language plpgsql set search_path = '' as $$
declare v_reminder public.reminders;
begin
  if not exists (select 1 from public.group_members where group_id=p_group_id and user_id=p_requester_id) then
    raise exception 'Group membership required' using errcode='42501';
  end if;
  if p_due_at is null or not isfinite(p_due_at) then raise exception 'Valid reminder time required' using errcode='22023'; end if;
  if p_timezone is null or not exists (select 1 from pg_catalog.pg_timezone_names where name=p_timezone) then raise exception 'Valid IANA timezone required' using errcode='22023'; end if;
  if p_body is null or length(btrim(p_body)) not between 1 and 2000 or p_source_key is null or length(p_source_key) not between 1 and 200 then raise exception 'Valid reminder and source key required' using errcode='22023'; end if;
  select * into v_reminder from public.reminders where group_id=p_group_id and source_key=p_source_key;
  if found then
    if v_reminder.requester_id <> p_requester_id or v_reminder.body <> btrim(p_body) or v_reminder.due_at <> p_due_at or v_reminder.timezone <> p_timezone then
      raise exception 'Source key already used for another reminder' using errcode='22023';
    end if;
    return v_reminder;
  end if;
  if p_due_at <= now() then raise exception 'Reminder time must be in the future' using errcode='22023'; end if;
  insert into public.reminders(group_id,requester_id,body,due_at,timezone,source_key)
  values(p_group_id,p_requester_id,btrim(p_body),p_due_at,p_timezone,p_source_key)
  on conflict (group_id,source_key) do nothing returning * into v_reminder;
  if not found then
    select * into v_reminder from public.reminders where group_id=p_group_id and source_key=p_source_key;
    if v_reminder.requester_id <> p_requester_id or v_reminder.body <> btrim(p_body) or v_reminder.due_at <> p_due_at or v_reminder.timezone <> p_timezone then
      raise exception 'Source key already used for another reminder' using errcode='22023';
    end if;
  end if;
  return v_reminder;
end $$;
