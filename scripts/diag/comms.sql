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
  -- r50 hotfix 2 (comms): who sends email today, the text pause, auto-replies, and calls by staff member (an id hash,
  -- never a name or number: these logs are public; digits in errors are masked)
  'emails_today_by_provider', (select jsonb_agg(r) from (select split_part(coalesce(provider_id, ''), ':', 1) prov, status, count(*) n, max(coalesce(sent_at, updated_at)) last
       from notification_outbox where created_at > now() - interval '20 hours' group by 1, 2 order by 3 desc limit 12) r),
  'email_usage_now', (select app.email_usage(now())),
  'ses_try_now', (select jsonb_build_object('left', app.ses_email_left(now()), 'try', app.ses_email_try(now()))),
  'text_pause', (select to_jsonb(s) - 'id' - 'quo_error' || jsonb_build_object('quo_error', regexp_replace(coalesce(s.quo_error, ''), '[0-9]{4,}', '#', 'g')) from phone_provider_state s limit 1),
  'texts_waiting_why', (select jsonb_agg(r) from (select status, kind, left(regexp_replace(coalesce(status_reason, last_error, ''), '[0-9]{4,}', '#', 'g'), 120) why, count(*) n, min(created_at) oldest
       from phone_outbox where status not in ('sent', 'skipped') and created_at > now() - interval '5 days' group by 1, 2, 3 order by 4 desc limit 12) r),
  'auto_replies_7d', (select jsonb_agg(r) from (select channel, status, left(coalesce(reason, ''), 100) why, count(*) n, max(created_at) last
       from auto_replies where created_at > now() - interval '7 days' group by 1, 2, 3 order by 4 desc limit 25) r),
  'auto_reply_settings', (select jsonb_object_agg(k, v) from jsonb_each(to_jsonb((select p from program_settings p limit 1))) e(k, v) where k like 'auto_reply_%' and k not like '%token%' and k not like '%text%'),
  'inbound_texts_by_day', (select jsonb_agg(r) from (select (received_at at time zone 'America/Toronto')::date d, split_part(type, '.', 1) || '.' || split_part(type, '.', 2) t, count(*) n
       from phone_webhook_log where received_at > now() - interval '7 days' and type like 'message.%' group by 1, 2 order by 1, 2) r),
  'calls_by_staff_7d', (select jsonb_agg(r) from (select left(md5(c.staff_user_id::text), 8) staff, (select string_agg(ur.role::text, ',') from user_roles ur where ur.user_id = c.staff_user_id) roles,
       c.via, c.status, left(regexp_replace(coalesce(c.error, c.outcome, ''), '[0-9]{4,}', '#', 'g'), 140) e, count(*) n, max(c.started_at) last
       from outbound_calls c where c.started_at > now() - interval '7 days' group by 1, 2, 3, 4, 5 order by 7 desc limit 40) r),
  'voice_presence_rows', (select jsonb_agg(jsonb_build_object('staff', left(md5(v.user_id::text), 8), 'online', v.online, 'seen', v.seen_at)) from voice_presence v),
  -- only the switches and the ring time: never a number or the message text
  'voice_settings', (select jsonb_build_object('calls', v -> 'calls', 'inbound', v -> 'inbound', 'own_mobile', v -> 'own_mobile', 'seconds', v -> 'seconds') from app.server_voice_settings() v),
  'push_outbox_7d', (select jsonb_agg(r) from (select status, left(coalesce(last_error, ''), 120) e, count(*) n from push_outbox where created_at > now() - interval '7 days' group by 1, 2 order by 3 desc limit 12) r)
) as d;
