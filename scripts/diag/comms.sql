-- r48 CM: read only. The state of email (SES, Resend), texts (Quo) and calls (Twilio), and phone alerts, for the comms check.
select jsonb_build_object(
  'email_state', (select to_jsonb(e) - 'id' from email_provider_state e limit 1),
  'email_settings', (select jsonb_build_object('ses_enabled', s ->> 'email_ses_enabled', 'ses_daily_max', s ->> 'email_ses_daily_max', 'cf_enabled', s ->> 'email_cloudflare_enabled',
       'production_ready', s ->> 'email_production_ready', 'resend_budget', s ->> 'notify_resend_daily_budget') from (select to_jsonb(p) s from program_settings p limit 1) x),
  'emails_3d', (select jsonb_agg(r) from (select status, split_part(coalesce(provider_id, ''), ':', 1) prov, left(coalesce(status_reason, ''), 90) why, count(*) n
       from notification_outbox where created_at > now() - interval '3 days' group by 1, 2, 3 order by 4 desc limit 25) r),
  'emails_by_day', (select jsonb_agg(r) from (select (sent_at at time zone 'America/Toronto')::date d, split_part(coalesce(provider_id, ''), ':', 1) prov, count(*) n
       from notification_outbox where status = 'sent' and sent_at > now() - interval '8 days' group by 1, 2 order by 1, 2) r),
  'email_failed_errors', (select jsonb_agg(r) from (select left(coalesce(last_error, status_reason, ''), 160) e, count(*) n, max(updated_at) last
       from notification_outbox where status = 'failed' and updated_at > now() - interval '5 days' group by 1 order by 2 desc limit 10) r),
  'texts_3d', (select jsonb_agg(r) from (select status, kind, left(coalesce(last_error, status_reason, ''), 140) e, count(*) n, max(updated_at) last
       from phone_outbox where created_at > now() - interval '4 days' group by 1, 2, 3 order by 4 desc limit 25) r),
  'texts_waiting', (select jsonb_build_object('queued', count(*), 'oldest', min(created_at)) from phone_outbox where status in ('queued', 'sending')),
  'texts_sent_by_day', (select jsonb_agg(r) from (select (sent_at at time zone 'America/Toronto')::date d, count(*) n from phone_outbox where status = 'sent' and sent_at > now() - interval '8 days' group by 1 order by 1) r),
  'calls_5d', (select jsonb_agg(r) from (select status, left(coalesce(error, outcome, ''), 160) e, count(*) n, max(started_at) last
       from outbound_calls where started_at > now() - interval '6 days' group by 1, 2 order by 3 desc limit 20) r),
  'calls_ok_by_day', (select jsonb_agg(r) from (select (started_at at time zone 'America/Toronto')::date d, status, count(*) n from outbound_calls where started_at > now() - interval '10 days' group by 1, 2 order by 1, 2) r),
  'voice_presence', (select jsonb_build_object('rows', count(*)) from voice_presence),
  'webhooks_3d', (select jsonb_agg(r) from (select split_part(type, '.', 1) t, left(coalesce(result, 'none'), 80) res, count(*) n, max(received_at) last
       from phone_webhook_log where received_at > now() - interval '3 days' group by 1, 2 order by 3 desc limit 15) r),
  'push', (select jsonb_build_object('subs', count(*), 'staff_users_with_subs', count(distinct ps.user_id) filter (where ps.portal in ('staff', 'admin', 'field')),
       'refusing', count(*) filter (where ps.refusals > 0), 'errors', jsonb_agg(distinct left(ps.last_error, 120)) filter (where ps.last_error is not null)) from push_subscriptions ps),
  'push_outbox_7d', (select jsonb_agg(r) from (select status, left(coalesce(last_error, ''), 120) e, count(*) n from push_outbox where created_at > now() - interval '7 days' group by 1, 2 order by 3 desc limit 12) r)
) as d;
