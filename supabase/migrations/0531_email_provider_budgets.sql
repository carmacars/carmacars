-- 0531: the owner's email budget: 300 a day, 200 through the Cloudflare email binding (first) and 100 through Resend (after).
-- The claim (0222) already counts Resend's emails against the daily cap and lets Cloudflare's go past it; these two settings let
-- the send-outbox Edge Function stop Cloudflare at its budget and hold the rest for tomorrow once both budgets are used.
alter table program_settings
  add column if not exists notify_cf_daily_budget integer not null default 200 check (notify_cf_daily_budget >= 0),
  add column if not exists notify_resend_daily_budget integer not null default 100 check (notify_resend_daily_budget >= 0);
comment on column program_settings.notify_cf_daily_budget is 'Emails a day through the Cloudflare email binding, which sends first (0531).';
comment on column program_settings.notify_resend_daily_budget is 'Emails a day through Resend, used after the Cloudflare budget (0531). The daily cap and the Resend free plan still apply.';

create or replace function public.server_email_budgets() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('cf_budget', s.notify_cf_daily_budget, 'resend_budget', s.notify_resend_daily_budget,
    'cf_used', (select count(*) from notification_outbox o where o.status = 'sent' and o.provider_id like 'cf:%' and o.sent_at >= app.local_midnight(app.local_date(now()))),
    'resend_used', (select count(*) from notification_outbox o where o.sent_at >= app.local_midnight(app.local_date(now()))
                      and ((o.status = 'sent' and coalesce(o.provider_id, '') not like 'cf:%') or o.status = 'sending' and coalesce(o.provider_id, '') not like 'cf:%')),
    'midnight', app.local_midnight(app.local_date(now()) + 1))
  from app.settings() s
$$;
revoke all on function public.server_email_budgets() from public, anon, authenticated;
grant execute on function public.server_email_budgets() to service_role;
