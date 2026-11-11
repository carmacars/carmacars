-- 1750_r35_email_cloudflare_first.sql
-- Release 35 (docs/changes/2026-11-11-cloudflare-email-first.md). The owner, again: Cloudflare email must actually work.
-- Live on 2026-11-11 Cloudflare Email Service had sent 426 emails this month, yet Admin > Settings > Usage said "Cloudflare
-- Email Service is not sending ... not set up yet" with the old 4 setup steps, and emails were held by an hourly pace
-- (43 an hour) and a daily cap (300), with about 2,574 Cloudflare emails left in the month.
--   1. Status from what Cloudflare did: sending whenever an outbox email went through Cloudflare (provider_id 'cf:') in
--      the last 48 hours. Only with no such send and the binding missing or refusing is there a problem, with the real
--      reason (the last Cloudflare error the sender recorded). The provider row (email_provider_state) is made sure to
--      exist: without it the old status read "absent" while the counts said Cloudflare sent (the live mismatch).
--   2. The owner's rule (2026-11-11, final): Cloudflare first, with a daily budget. Each Toronto day the outbox sends
--      through Cloudflare until the day's budget (cf_email_daily_budget, new Program setting, 100: the free 3,000 a month
--      spread over the month) is used, never taking the month past cf_email_monthly_included (3,000). Then Resend's free
--      plan (notify_resend_daily_budget, 100 a day). When both are used, the emails are held by priority as before
--      (booking, payment and sign-in emails first: the class limits of 0018). No hourly pace within those budgets (0583's
--      43 an hour and 0530's spreading of the low classes are gone) and never a paid send on either. Within Cloudflare's
--      budget Resend is used only after a Cloudflare error (Cloudflare rests 15 minutes).
--   3. Every email the sender sends through Resend after a Cloudflare error is marked so (status_reason), so "why did
--      this go through Resend" has an answer per email.
--   4. The emails held by the pace or the old caps are queued again now (app.email_release_held); the claim holds by
--      priority what today's budgets cannot send.
-- No applied migration is edited: functions are replaced, wrapped (renamed _pre1750) or patched in place.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '1750: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ settings
alter table program_settings
  add column if not exists cf_email_daily_budget integer not null default 100 check (cf_email_daily_budget >= 0);
comment on column program_settings.cf_email_daily_budget is 'Emails a Toronto day through Cloudflare Email Service, first (1750): 100, the free 3,000 a month spread over the month. Never past cf_email_monthly_included in the month. Then Resend''s free plan (notify_resend_daily_budget).';
comment on column program_settings.cf_email_monthly_included is 'Cloudflare emails a month included in Workers Paid (0222): never exceeded, nothing is paid (1750).';
comment on column program_settings.notify_cf_daily_budget is 'Not used since 1750: Cloudflare''s day is cf_email_daily_budget.';
comment on column program_settings.notify_daily_cap is 'Upper limit of Resend''s part of a day (1750: Cloudflare''s day is cf_email_daily_budget, on top).';
comment on column program_settings.notify_resend_daily_budget is 'Emails a day through Resend''s free plan, after Cloudflare''s day (1750). When both are used the class limits hold the emails by priority.';

-- the provider row is a singleton the sender writes; make sure it is there (an upsert from now on)
insert into email_provider_state default values on conflict do nothing;
create or replace function app.server_cf_email_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  insert into email_provider_state default values on conflict do nothing;
  if coalesce((p ->> 'ok')::boolean, false) then
    update email_provider_state set cf_ok_at = now(), updated_at = now() where id;
  else
    update email_provider_state set cf_failed_at = now(), cf_error = left(p ->> 'error', 300), updated_at = now() where id;
  end if;
  return (select to_jsonb(e) - 'id' from email_provider_state e limit 1);
end $$;

-- ================================================================ 1. the status
-- the month's Cloudflare emails so far
create or replace function app.cf_emails_month(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select app.cf_emails_between(app.local_midnight(app.month_start(app.local_date(p_now))), p_now + interval '1 second')
$$;

-- the last Cloudflare error the sender recorded: the provider row's while it is newer than the last success, else the
-- latest email that went through Resend after a Cloudflare error (status_reason of app.outbox_note_cf_fallback)
create or replace function app.cf_email_last_error() returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select nullif(btrim(e.cf_error), '') from email_provider_state e where e.cf_failed_at is not null and e.cf_failed_at > coalesce(e.cf_ok_at, '-infinity'::timestamptz) limit 1),
    (select regexp_replace(o.status_reason, '^sent through Resend after a Cloudflare error: ', '') from notification_outbox o
      where o.status = 'sent' and o.status_reason like 'sent through Resend after a Cloudflare error:%' order by o.sent_at desc limit 1))
$$;

-- ok whenever Cloudflare sent in the last 48 hours; else the state of 0320/0900 (ok after a success with no refusal
-- since, off, absent, failing), with the reason in plain words and the last error
alter function app.cf_email_setup(timestamptz) rename to cf_email_setup_pre1750;
create function app.cf_email_setup(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b jsonb := app.cf_email_setup_pre1750(p_now);
  s program_settings := app.settings_base(app.local_date(p_now));
  v_48 integer := app.cf_emails_between(p_now - interval '48 hours', p_now + interval '1 second');
  v_last timestamptz := (select max(o.sent_at) from notification_outbox o where o.status in ('sent', 'sending') and o.provider_id like 'cf:%' and o.sent_at <= p_now + interval '1 second');
  v_err text := app.cf_email_last_error();
  v_state text;
begin
  v_state := case
    when not coalesce(s.cf_email_enabled, false) then 'off'
    when v_48 > 0 then 'ok'
    when b ->> 'state' = 'ok' then 'ok'
    when v_err is null or v_err ilike '%binding%' then 'absent'
    else 'failing' end;
  return b || jsonb_build_object('state', v_state, 'enabled', coalesce(s.cf_email_enabled, false), 'sent_48h', v_48, 'last_sent_at', v_last,
    'error', v_err, 'included', s.cf_email_monthly_included, 'sent_month', app.cf_emails_month(p_now),
    'reason', case v_state
      when 'ok' then null
      when 'off' then 'Cloudflare Email Service is turned off in Program settings'
      when 'absent' then case when v_err is not null then 'the site''s Worker has no Cloudflare EMAIL binding (Cloudflare said: ' || left(v_err, 160) || ')'
                              else 'no email went through Cloudflare in the last 48 hours and it reported no error' end
      else 'Cloudflare refused the last email' || coalesce(': ' || left(v_err, 160), '') end);
end $$;
select pg_temp.copy_grants('app.cf_email_setup(timestamptz)'::regprocedure, 'app.cf_email_setup_pre1750(timestamptz)'::regprocedure);

create or replace function app.cf_email_counted(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.cf_email_setup(p_now) ->> 'state' = 'ok'
$$;

create or replace function app.email_cf_reason(p_now timestamptz default now()) returns text
language sql stable security definer set search_path = public, app as $$
  select app.cf_email_setup(p_now) ->> 'reason'
$$;

-- ================================================================ 2. Cloudflare first, with a daily budget
-- what Cloudflare may still send today: the day's budget less today's sends, never past the month's included emails
create or replace function app.cf_email_left(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select case when not coalesce(s.cf_email_enabled, false) then 0
              else greatest(0, least(s.cf_email_daily_budget - app.cf_emails_between(app.local_midnight(app.local_date(p_now)), p_now + interval '1 second'),
                                     s.cf_email_monthly_included - app.cf_emails_month(p_now))) end::integer
    from app.settings_base(app.local_date(p_now)) s
$$;
-- may the sender try Cloudflare now: budget left today (and in the month), no refusal in the last 15 minutes
create or replace function app.cf_email_try(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.cf_email_left(p_now) > 0
     and not coalesce((select e.cf_failed_at > p_now - interval '15 minutes' from email_provider_state e limit 1), false)
$$;
-- the claim of 0018 lifts Resend's limits only while Cloudflare may send
create or replace function app.cf_email_available(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.cf_email_try(p_now)
$$;
-- held by Resend's limits: back in 15 minutes while Cloudflare has budget left today (it rests 15 minutes), else midnight
create or replace function app.email_hold_until(p_now timestamptz, p_midnight timestamptz) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select case when app.cf_email_left(p_now) > 0 then least(p_midnight, p_now + interval '15 minutes') else p_midnight end
$$;
-- the day's cap: today's Cloudflare sends plus Resend's part (the claim's Resend count holds the rest by class)
create or replace function app.email_day_cap(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select (app.cf_emails_between(app.local_midnight(app.local_date(p_now)), p_now + interval '1 second') + app.cf_email_left(p_now)
          + greatest(0, least(s.notify_daily_cap, s.notify_resend_daily_budget)))::integer
    from app.settings_base(app.local_date(p_now)) s
$$;

-- the claim of 0583: while Cloudflare may send, at most what it has left (the rest waits a minute for Resend's turn);
-- no hourly pace in either case
select pg_temp.patch_fn('app.outbox_claim_pre0601(integer, timestamptz)'::regprocedure,
  E'  v_day_left := v_cap - app.emails_since(',
  E'  -- 1750: Cloudflare\'s turn: no hourly pace, no more than its budget left today\n'
  || E'  if app.cf_email_try(p_now) then\n    return query select * from app.outbox_claim_pre0583(least(coalesce(p_limit, 20), app.cf_email_left(p_now)), p_now);\n    return;\n  end if;\n'
  || E'  v_day_left := v_cap - app.emails_since(');
select pg_temp.patch_fn('app.outbox_claim_pre0601(integer, timestamptz)'::regprocedure,
  E'  v_hour_left := greatest(0, (ceil(v_cap / 24.0)::integer + 30) - app.emails_since(p_now - interval \'1 hour\', p_now)) + app.outbox_urgent_waiting(p_now);',
  E'  v_hour_left := 1000000000; -- 1750: no hourly pace within the budgets');
-- the pacing of 0530 (low classes spread across the day): gone, the class limits of 0018 keep the priorities
select pg_temp.patch_fn('app.outbox_claim_pre0583(integer, timestamptz)'::regprocedure,
  E'v_allow integer := ceil(s.notify_daily_cap * 0.5 * least(1, v_frac + 0.04))::integer;',
  E'v_allow integer := 1000000000; -- 1750: no pacing within the budgets');
-- the portal warning "Email use is at N% of today's limit": Resend's count, so not while Cloudflare sends
select pg_temp.patch_fn('app.outbox_claim_pre0530(integer, timestamptz)'::regprocedure,
  E'if v_used >= v_warn then',
  E'if v_used >= v_warn and not app.cf_email_try(p_now) then');

-- the sender's budgets: Cloudflare's left today (cf_left), Resend's day
create or replace function public.server_email_budgets() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with x as (
    select s, (select count(*)::integer from notification_outbox o where o.status = 'sent' and o.provider_id like 'cf:%' and o.sent_at >= app.local_midnight(app.local_date(now()))) cf_used,
           app.cf_email_left(now()) cf_left
      from app.settings() s)
  select jsonb_build_object('cf_budget', x.cf_used + x.cf_left, 'cf_used', x.cf_used, 'cf_left', x.cf_left,
    'resend_budget', (x.s).notify_resend_daily_budget,
    'resend_used', (select count(*) from notification_outbox o where o.sent_at >= app.local_midnight(app.local_date(now()))
                      and o.status in ('sent', 'sending') and coalesce(o.provider_id, '') not like 'cf:%'),
    'midnight', app.local_midnight(app.local_date(now()) + 1))
  from x
$$;

-- ================================================================ 3. why an email went through Resend
create or replace function app.outbox_note_cf_fallback(p_id uuid, p_error text) returns void
language sql security definer set search_path = public, app as $$
  update notification_outbox set status_reason = left('sent through Resend after a Cloudflare error: ' || coalesce(nullif(btrim(p_error), ''), 'no reason given'), 300)
   where id = p_id and status = 'sent' and coalesce(provider_id, '') not like 'cf:%'
$$;
create or replace function public.server_outbox_note_cf_fallback(p_id uuid, p_error text) returns void
language sql security definer set search_path = public, app as $$ select app.outbox_note_cf_fallback(p_id, p_error) $$;

-- ================================================================ Settings > Usage: today Cloudflare N of 100, Resend M of 100, the month of 3,000
create or replace function app.email_pace(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with d as (select app.local_midnight(app.local_date(p_now)) d0),
  st as (select app.cf_email_setup(p_now) c),
  s as (select x from app.settings_base(app.local_date(p_now)) x)
  select jsonb_build_object(
    'day_used', app.emails_since(d.d0, p_now),
    'cf_today', app.cf_emails_between(d.d0, p_now + interval '1 second'),
    'cf_day_budget', (s.x).cf_email_daily_budget,
    'resend_today', (select count(*)::integer from notification_outbox o where coalesce(o.channel, 'email') = 'email' and o.status = 'sent'
                       and o.sent_at >= d.d0 and o.sent_at <= p_now and coalesce(o.provider_id, '') not like 'cf:%'),
    'resend_day_budget', (s.x).notify_resend_daily_budget,
    'auth_today', app.auth_emails_today(p_now),
    'fallback_today', (select count(*)::integer from notification_outbox o where o.status = 'sent' and o.sent_at >= d.d0 and o.sent_at <= p_now
                         and o.status_reason like 'sent through Resend after a Cloudflare error:%'),
    'cf_month', app.cf_emails_month(p_now), 'cf_included', (s.x).cf_email_monthly_included,
    'cf_left', app.cf_email_left(p_now), 'cf_open', app.cf_email_try(p_now), 'day_cap', app.email_day_cap(p_now),
    'hour_used', app.emails_since(p_now - interval '1 hour', p_now),
    'waiting', (select count(*)::integer from notification_outbox o where o.status in ('queued', 'delayed') and coalesce(o.channel, 'email') = 'email' and o.send_after <= p_now),
    'held', (select count(*)::integer from notification_outbox o where o.status = 'delayed' and coalesce(o.channel, 'email') = 'email'
               and o.status_reason in ('daily email limit', 'monthly email limit', 'the day''s email budget is used', 'the email provider''s daily limit')),
    'cf_state', st.c ->> 'state', 'cf_counted', st.c ->> 'state' = 'ok', 'cf_ever_sent', app.cf_email_ever_sent(), 'cf_reason', st.c ->> 'reason',
    'limited_by', case when app.cf_email_try(p_now) then 'cloudflare' else 'resend' end)
    from d, st, s
$$;

-- the booking page's email box (0900, 1501): the same read
create or replace function app.email_capacity(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('capacity', app.email_day_cap(p_now), 'limited_by', case when app.cf_email_try(p_now) then 'cloudflare' else 'resend' end,
    'cf_reason', app.email_cf_reason(p_now))
$$;

-- Settings > Usage, the Cloudflare row's words
update usage_services set
  upgrade_text = 'Never paid: at most the day''s budget (Program settings, cf_email_daily_budget) and never past the month''s included emails.',
  when_used_up = 'The outbox goes on through Resend''s free plan; when that is used too, booking, payment and sign-in emails go first and the others wait.'
 where service = 'cf_email';

-- ================================================================ 4. release what only the pace or the caps held
create or replace function app.email_release_held(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  -- the claim holds again, by priority, what today's budgets cannot send
  update notification_outbox o set status = 'queued', status_reason = null, send_after = p_now
   where o.status = 'delayed' and coalesce(o.channel, 'email') = 'email' and o.send_after > p_now
     and o.status_reason in ('daily email limit', 'monthly email limit', 'paced across the day', 'the day''s email budget is used',
                             'waiting for Cloudflare email (Resend''s budget for today is used)', 'the email provider''s daily limit',
                             'the email provider''s monthly limit');
  get diagnostics n = row_count;
  return n;
end $$;
select app.email_release_held();

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('cf_emails_month', 'cf_email_left', 'cf_email_last_error', 'cf_email_counted', 'email_cf_reason', 'cf_email_try',
                                                        'cf_email_available', 'email_hold_until', 'email_day_cap', 'outbox_note_cf_fallback', 'email_capacity',
                                                        'email_release_held', 'cf_email_setup_pre1750', 'server_cf_email_result'))
               or (n.nspname = 'public' and p.proname in ('server_email_budgets', 'server_outbox_note_cf_fallback', 'server_cf_email_result')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
