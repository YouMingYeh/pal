-- Run after storing pal_dispatch_url (full /api/dispatch URL) and pal_cron_secret in Vault.
-- Keep the secret out of migration files, query output, and cron.job.command.
create extension if not exists pg_net with schema extensions;

do $$
begin
  if not exists (select 1 from vault.decrypted_secrets where name='pal_dispatch_url')
     or not exists (select 1 from vault.decrypted_secrets where name='pal_cron_secret') then
    raise exception 'Store pal_dispatch_url and pal_cron_secret in Supabase Vault first';
  end if;
  if not exists (select 1 from vault.decrypted_secrets where name='pal_dispatch_url' and decrypted_secret like 'https://%/api/dispatch') then
    raise exception 'pal_dispatch_url must be an HTTPS /api/dispatch endpoint';
  end if;
end $$;

select cron.schedule(
  'pal-recover-agent-jobs',
  '* * * * *',
  $cron$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='pal_dispatch_url'),
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='pal_cron_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000
  );
  $cron$
);
