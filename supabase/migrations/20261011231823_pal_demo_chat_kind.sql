-- Both rehearsal kinds reuse the protected cast and persisted conversation pipeline.
alter table private.pal_demo_rooms add column kind text not null default 'plan' check(kind in ('chat','plan'));

create or replace function private.pal_demo_state(p_group_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind',d.kind,'generation',d.generation,'step',d.next_step,'total',6,
 'run_id',d.active_run,'starts_at',d.starts_at,'source_message_id',r.message_id,
 'operator_message_id',r.message_id,'operator_user_id',r.user_id,
 'actor_ids',(select jsonb_agg(a.user_id order by a.position) from private.pal_demo_actors a where a.group_id=d.group_id),
 'status',case when exists(select 1 from private.pal_demo_lines l where l.run_id=d.active_run and l.emitted_at is null) then 'actors'
 when j.status in ('queued','running') then 'pal' when j.status='failed' then 'failed' else 'ready' end)
 from private.pal_demo_rooms d join public.groups g on g.id=d.group_id and g.is_demo and not g.is_direct
 left join private.pal_demo_runs r on r.id=d.active_run and r.group_id=d.group_id
 left join lateral (
 select work.status from public.agent_jobs work join public.messages msg on msg.id=r.message_id
 where work.group_id=d.group_id and work.created_at>=msg.created_at and work.status not in ('coalesced','cancelled')
 order by work.created_at desc,work.id desc limit 1
 ) j on true where d.group_id=p_group_id
$$;

-- A defaulted fourth argument preserves existing three-argument callers without ambiguous overloads.
alter function public.pal_demo_register(uuid,uuid[],uuid[]) set schema private;
alter function private.pal_demo_register(uuid,uuid[],uuid[]) rename to pal_demo_register_before_kind;
revoke all on function private.pal_demo_register_before_kind(uuid,uuid[],uuid[]) from public,anon,authenticated,service_role;
create function public.pal_demo_register(p_group_id uuid,p_actor_ids uuid[],p_place_ids uuid[],p_kind text default 'plan') returns void
language plpgsql security definer set search_path='' as $$
begin
 if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
 if p_kind is null or p_kind not in ('chat','plan') or p_actor_ids is null or p_place_ids is null
 or (p_kind='chat' and cardinality(p_place_ids)<>0) then raise exception 'Valid rehearsal kind and cast required' using errcode='22023'; end if;
 perform private.pal_demo_register_before_kind(p_group_id,p_actor_ids,p_place_ids);
 update private.pal_demo_rooms set kind=p_kind where group_id=p_group_id;
end $$;
revoke all on function public.pal_demo_register(uuid,uuid[],uuid[],text) from public,anon,authenticated;
grant execute on function public.pal_demo_register(uuid,uuid[],uuid[],text) to service_role;

do $$ declare definition text:=pg_get_functiondef('public.pal_demo_begin(uuid,uuid,integer,uuid,uuid,text,jsonb)'::regprocedure);
 needle text:='if p_step=3 then';
begin
 if position(needle in definition)=0 then raise exception 'Expected current rehearsal move guard'; end if;
 execute replace(definition,needle,'if p_step=3 and d.kind=''plan'' then');
end $$;
