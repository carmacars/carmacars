-- 2630_r42_ses_events.sql
-- Release 42 (docs/changes/2026-11-12-r42-ses-events.md). Amazon SES reports a permanent bounce or a complaint through
-- Amazon SNS to /api/ses/events (web/src/lib/ses-sns.ts); the route calls this wrapper, which is the existing
-- app.outbox_record_bounce (0018): the address is suppressed for every email (email_suppressions, scope all, reason bounce or
-- complaint), the email's outbox row is failed and what still waits for that address is not sent. No new table, column or
-- reason. Server only, like the sender's other functions.
create or replace function public.server_outbox_record_bounce(p_provider_id text, p_kind text, p_detail text default null, p_email text default null)
returns uuid language sql security definer set search_path = public, app as $$
  -- a validly signed SNS message can come from anyone's topic: only an email we sent (provider id ses:<id>) to that address counts
  select case when exists (select 1 from notification_outbox o where o.provider_id = p_provider_id and p_provider_id like 'ses:%'
                              and lower(btrim(o.to_address)) = lower(btrim(p_email)))
              then app.outbox_record_bounce(p_provider_id, p_kind, p_detail, p_email) end
$$;
revoke all on function public.server_outbox_record_bounce(text, text, text, text) from public, anon, authenticated;
grant execute on function public.server_outbox_record_bounce(text, text, text, text) to service_role;
