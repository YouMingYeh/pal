-- Supabase grants functions directly to client roles through default privileges.
-- Revoking PUBLIC alone leaves those direct grants in place.
revoke all on function
  public.claim_agent_jobs(integer),
  public.complete_agent_job(uuid,integer,text,text),
  public.fail_agent_job(uuid,integer,text),
  public.create_reminder(uuid,uuid,text,timestamptz,text,text)
from public, anon, authenticated;
grant execute on function
  public.claim_agent_jobs(integer),
  public.complete_agent_job(uuid,integer,text,text),
  public.fail_agent_job(uuid,integer,text),
  public.create_reminder(uuid,uuid,text,timestamptz,text,text)
to service_role;

revoke all on function
  public.create_group(text), private.create_group(text),
  public.join_group(uuid), private.join_group(uuid),
  public.send_message(uuid,text,uuid), private.send_message(uuid,text,uuid),
  private.my_group_ids()
from public, anon, authenticated, service_role;
grant execute on function
  public.create_group(text), private.create_group(text),
  public.join_group(uuid), private.join_group(uuid),
  public.send_message(uuid,text,uuid), private.send_message(uuid,text,uuid),
  private.my_group_ids()
to authenticated;

revoke all on function private.deliver_due_reminders() from public, anon, authenticated, service_role;
revoke all on schema private from public, anon;
