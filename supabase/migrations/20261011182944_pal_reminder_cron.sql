create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

-- shortcut: delivery is a chat message, add APNs when signing credentials are available.
select cron.schedule('pal-deliver-reminders','* * * * *','select private.deliver_due_reminders()');
