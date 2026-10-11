-- Preserve trusted action provenance; human-supplied source keys are not proof of agent work.
alter table private.action_receipts add column is_agent boolean not null default false;
do $$
declare definition text:=pg_get_functiondef('private.pal_execute_action(uuid,uuid,text,jsonb,boolean)'::regprocedure);
  receipt_old text:=$n$insert into private.action_receipts(group_id,user_id,action,source_key,input,result) values(p_group_id,p_user_id,p_action,v_key,p_data,result);$n$;
  receipt_new text:=$n$insert into private.action_receipts(group_id,user_id,action,source_key,input,result,is_agent) values(p_group_id,p_user_id,p_action,v_key,p_data,result,p_agent);$n$;
  poll_old text:=$n$when 'poll.create' then
      opts:=p_data->'options';$n$;
  poll_new text:=$n$when 'poll.create' then
      if p_data ? 'presentation' and (jsonb_typeof(p_data->'presentation') is distinct from 'string' or p_data->>'presentation' not in ('options','availability')
        or (p_data->>'presentation'='options' and p_data->>'kind' is distinct from 'place') or (p_data->>'presentation'='availability' and p_data->>'kind' is distinct from 'time')) then
        raise exception 'Rich board presentation must match its poll kind' using errcode='22023';
      end if;
      opts:=p_data->'options';$n$;
  reminders_old text:=$n$      insert into public.reminders(group_id,requester_id,body,due_at,timezone,source_key,poll_id,kind)
      values(p_group_id,p_user_id,poll.question,now()+(due-now())/2,g.timezone,'poll:'||poll.id||':halfway',poll.id,'poll_halfway'),
        (p_group_id,p_user_id,poll.question,due,g.timezone,'poll:'||poll.id||':deadline',poll.id,'poll_deadline');$n$;
  reminders_new text:=$n$      if coalesce(p_data->>'presentation','') not in ('options','availability') then
      insert into public.reminders(group_id,requester_id,body,due_at,timezone,source_key,poll_id,kind)
      values(p_group_id,p_user_id,poll.question,now()+(due-now())/2,g.timezone,'poll:'||poll.id||':halfway',poll.id,'poll_halfway'),
        (p_group_id,p_user_id,poll.question,due,g.timezone,'poll:'||poll.id||':deadline',poll.id,'poll_deadline');
      end if;$n$;
begin
  if (length(definition)-length(replace(definition,receipt_old,'')))/length(receipt_old)<>1 or position(poll_old in definition)=0 or position(reminders_old in definition)=0 then
    raise exception 'Expected existing receipt, poll and reminder delegates in Pal action dispatcher';
  end if;
  execute replace(replace(replace(definition,receipt_old,receipt_new),poll_old,poll_new),reminders_old,reminders_new);
end $$;

-- A new availability board can collect dated choices actually stated earlier in
-- its own frozen batch. Other polls and responses keep their chronology checks.
do $$
declare definition text:=pg_get_functiondef('private.pal_capture_member_response(uuid,integer,uuid,text,text,uuid,jsonb)'::regprocedure);
  prior text:=$n$if poll.status<>'open' or poll.deadline_at<=now() or source.created_at<poll.created_at then raise exception 'Source must respond to a current open poll' using errcode='22023'; end if;$n$;
  replacement text:=$n$if poll.status<>'open' or poll.deadline_at<=now() or (source.created_at<poll.created_at and not (
      poll.kind='time' and p_response->>'kind'='options' and exists(
        select 1 from private.action_receipts r where r.group_id=j.group_id and r.user_id=poll.created_by and r.action='poll.create' and r.is_agent
          and r.source_key like 'job:'||j.id||':poll.create:%' and r.input->>'job_id'=j.id::text and r.result->>'id'=poll.id::text
      )
    )) then raise exception 'Source must respond to a current open poll or its own job-created availability board' using errcode='22023'; end if;$n$;
begin
  if (length(definition)-length(replace(definition,prior,'')))/length(prior)<>1 then raise exception 'Expected existing poll response chronology guard'; end if;
  execute replace(definition,prior,replacement);
end $$;
