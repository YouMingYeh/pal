-- Ordinary group messages still coalesce a short burst, without a ten-second wait.
do $$
declare definition text:=pg_get_functiondef('private.send_message(uuid,text,uuid,uuid)'::regprocedure);
  prior text:=$needle$interval '10 seconds'$needle$;
begin
  if (length(definition)-length(replace(definition,prior,'')))/length(prior)<>2 then
    raise exception 'Expected the two current group conversation debounce deadlines';
  end if;
  execute replace(definition,prior,$needle$interval '3 seconds'$needle$);
end $$;
update public.agent_jobs set run_after=least(run_after,now()+interval '3 seconds')
where job_kind='chat' and status='queued' and not explicit_mention and attempts=0;
