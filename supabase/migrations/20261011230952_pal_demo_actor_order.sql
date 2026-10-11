-- Mock cast messages are normal chatter; the operator's oldest job owns the burst.
do $$ declare definition text:=pg_get_functiondef('public.pal_demo_tick(uuid)'::regprocedure);
 prior text:='insert into public.agent_jobs(group_id,message_id,requester_id,run_after) values(d.group_id,m.id,l.user_id,now());';
 begin
 if position(prior in definition)=0 then raise exception 'Expected current rehearsal emission'; end if;
 execute replace(definition,prior,'insert into public.agent_jobs(group_id,message_id,requester_id,run_after,explicit_mention) values(d.group_id,m.id,l.user_id,now(),false);');
 end $$;
