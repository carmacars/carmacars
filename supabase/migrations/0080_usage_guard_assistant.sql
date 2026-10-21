-- 0080_usage_guard_assistant.sql
-- The owner's requests of October 21, 2026 (docs/changes/2026-10-21-usage-guard-and-assistant.md):
--   A. Usage guard. "I don't want to be paying a lot if the free stuff that's included in my plan runs out. Give me an
--      alert when the included usage for the server and AI and anything else is finished, and it asks me to confirm
--      before we resume paying for usage. Tools should not break but show that they are temporarily unavailable until
--      the next day due to usage limits."
--        1. usage_services: every metered service with its included allowance (Admin-editable), its period, how it is
--           measured and what happens when it is used up (pause, hold, alert only). usage_readings: one figure per
--           service, day and source (the app's own record, Cloudflare's analytics, a figure an Admin typed), so the
--           30-day history and each period's use come from one ledger. usage_decisions: "allow paid usage until the
--           end of today or this month, up to US$X" or "keep paused". usage_alerts: one row per service, level (80 or
--           100) and period, so each alert is shown and emailed once.
--        2. app.job_usage_refresh (pg_cron hourly, and the Worker's hourly job): measures what the database can see
--           (Workers AI neurons and image transformations from provider_calls, emails from the outbox and Supabase
--           Auth, the Claude assistant's dollars, the database size, file storage), keeps the Cloudflare figures the
--           Worker or the usage workflow reported (Worker requests and CPU, Workers AI neurons, R2 storage), works out
--           each service's state, opens the 80% and 100% alerts and emails them to the alert address (quiet hours,
--           at most usage_alert_max_emails a day), and retries the photo backgrounds that waited for the allowance.
--        3. Paused by default: app.settings() now reads the included Workers AI neurons and Resend emails as the
--           ceiling of the existing daily gates (live chat, listing copy, search copy, Turo email reading, vision),
--           plus the neurons a paid-usage decision allows today. Nothing else changes in those features: they
--           already wait for the next day when the gate is closed. Core website requests and CPU, the database and
--           storage are never paused: they alert, with the estimated overage cost.
--   B. Staff assistant. A chat panel in every staff portal that reads live data and proposes changes as cards; a
--      change runs only after Confirm, through the same door functions the screens use, as the signed-in person
--      (app.assistant_propose, app.assistant_confirm). Every action is in assistant_actions and the audit log
--      ("via assistant"), and every audit row written while it runs carries request_id 'via assistant'.
-- No applied migration is edited. Functions it changes are wrapped (renamed _pre0080 and called from a new function of
-- the same name).

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists usage_alert_max_emails integer not null default 4 check (usage_alert_max_emails between 0 and 20),
  add column if not exists assistant_enabled boolean not null default true,
  add column if not exists assistant_daily_neurons integer not null default 3000 check (assistant_daily_neurons between 0 and 1000000),
  add column if not exists assistant_claude_model text not null default 'claude-haiku-4-5' check (assistant_claude_model ~ '^[a-z0-9][a-z0-9.@:_-]{2,80}$'),
  add column if not exists assistant_claude_input_usd_per_m numeric(8,3) not null default 1 check (assistant_claude_input_usd_per_m between 0 and 200),
  add column if not exists assistant_claude_output_usd_per_m numeric(8,3) not null default 5 check (assistant_claude_output_usd_per_m between 0 and 500);
comment on column program_settings.usage_alert_max_emails is 'Usage guard (0080): at most this many usage alert emails a day (each service, level and period emails once; the rest show on Admin > To do).';
comment on column program_settings.assistant_enabled is 'Staff assistant (0080): the chat panel in the staff portals. Off: the button is hidden.';
comment on column program_settings.assistant_daily_neurons is 'Staff assistant: the Workers AI neurons it may use a Toronto day (its share of the included 10,000). Then it rests until tomorrow.';
comment on column program_settings.assistant_claude_model is 'Staff assistant: the Claude model used when ANTHROPIC_API_KEY is set in the Worker (claude-haiku-4-5 by default). Claude is billed in dollars and asks before spending (Settings > Usage).';
comment on column program_settings.assistant_claude_input_usd_per_m is 'Staff assistant: the Claude price per million input tokens, in US dollars, to count its cost. Check it against Anthropic''s price list.';
comment on column program_settings.assistant_claude_output_usd_per_m is 'Staff assistant: the Claude price per million output tokens, in US dollars.';

-- provider_calls (0022, 0032): the assistant's Claude calls are counted in micro-dollars (unit microusd, cost 0 so the
-- photo budget of 0032 is not spent by them)
alter table provider_calls drop constraint if exists provider_calls_unit_check;
alter table provider_calls add constraint provider_calls_unit_check check (unit in ('neurons', 'transformations', 'requests', 'microusd'));

-- ================================================================ 2. the ledger
create table usage_services (
  service           text primary key check (service ~ '^[a-z][a-z0-9_]{2,40}$'),
  label             text not null,
  provider          text not null,
  unit              text not null check (unit in ('neurons', 'requests', 'cpu_ms', 'transformations', 'emails', 'bytes', 'microusd', 'minutes')),
  period            text not null check (period in ('day', 'month', 'size')),
  included          numeric not null check (included >= 0),
  unlimited         boolean not null default false,
  warn_bps          integer not null default 8000 check (warn_bps between 1000 and 9900),
  pause_mode        text not null check (pause_mode in ('pause', 'hold', 'alert')),
  usd_per_unit      numeric,
  price_text        text not null,
  upgrade_text      text,
  measured_by       text not null,
  when_used_up      text not null,
  enabled           boolean not null default true,
  sort              integer not null,
  -- the last refresh (app.usage_refresh_service)
  used              numeric not null default 0,
  period_start      date,
  state             text not null default 'ok' check (state in ('ok', 'warn', 'used_up', 'paused', 'paid', 'held', 'over', 'free')),
  paid_extra        numeric not null default 0,
  paid_extra_on     date,
  measured_at       timestamptz,
  updated_at        timestamptz not null default now()
);
comment on table usage_services is 'Usage guard (0080): each metered service, its included allowance (Admin-editable in Settings > Usage), period, how it is measured and what pauses when it is used up. The used, state and paid_extra columns are the last refresh.';

create table usage_readings (
  service     text not null references usage_services (service) on delete cascade,
  day         date not null,
  source      text not null check (source in ('app', 'cloudflare', 'supabase', 'manual')),
  used        numeric not null check (used >= 0),
  measured_at timestamptz not null default now(),
  measured_by uuid references users (id),
  primary key (service, day, source)
);
create index usage_readings_day_idx on usage_readings (day desc);
comment on table usage_readings is 'Usage guard (0080): one figure per service, Toronto day and source. For a daily or monthly service it is the day''s use; for a size (database, storage) the size that day. Where two sources report a day, the larger counts.';

create table usage_decisions (
  id          uuid primary key default gen_random_uuid(),
  service     text not null references usage_services (service) on delete cascade,
  decision    text not null check (decision in ('allow', 'keep_paused')),
  until_kind  text not null check (until_kind in ('day', 'month')),
  starts_on   date not null,
  ends_on     date not null,
  cap_usd     numeric(10,2) check (cap_usd > 0 and cap_usd <= 1000),
  decided_by  uuid not null references users (id),
  decided_at  timestamptz not null default clock_timestamp(),
  note        text check (length(note) <= 300),
  check (ends_on >= starts_on),
  check (decision = 'keep_paused' or cap_usd is not null)
);
create index usage_decisions_service_idx on usage_decisions (service, decided_at desc);
comment on table usage_decisions is 'Usage guard (0080): an Admin''s answer once an included allowance is used up: allow paid usage until the end of today or this month, up to cap_usd, or keep it paused. Nobody answering means paused.';

create table usage_alerts (
  id           uuid primary key default gen_random_uuid(),
  service      text not null references usage_services (service) on delete cascade,
  period_start date not null,
  level        smallint not null check (level in (80, 100)),
  used         numeric not null,
  included     numeric not null,
  created_at   timestamptz not null default now(),
  emailed_at   timestamptz,
  email_note   text,
  dismissed_at timestamptz,
  dismissed_by uuid references users (id),
  unique (service, period_start, level)
);
comment on table usage_alerts is 'Usage guard (0080): one alert per service, level (80% or 100% of the included allowance) and period: one card on Admin > To do and one email to the alert address.';

create table assistant_actions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users (id),
  portal      text not null check (portal in ('admin', 'va', 'field')),
  tool        text not null check (tool ~ '^[a-z_]{3,40}$'),
  call        text not null check (call in ('admin_do', 'va_do', 'field_do', 'ops_do')),
  name        text not null check (name ~ '^[a-z_0-9]{3,60}$'),
  args        jsonb not null default '{}'::jsonb,
  summary     text not null check (length(summary) between 3 and 600),
  status      text not null default 'proposed' check (status in ('proposed', 'done', 'failed', 'cancelled', 'expired')),
  result      jsonb,
  error       text,
  created_at  timestamptz not null default now(),
  decided_at  timestamptz
);
create index assistant_actions_user_idx on assistant_actions (user_id, created_at desc);
comment on table assistant_actions is 'Staff assistant (0080): every change the assistant proposed, as the card the staff member saw. It runs only on Confirm, through the same door function as the screens, as that person.';

do $$
declare t text;
begin
  foreach t in array array['usage_services', 'usage_readings', 'usage_decisions', 'usage_alerts', 'assistant_actions'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;
create trigger audit_usage_services after insert or update of included, warn_bps, enabled on usage_services for each row execute function app.audit_row();
create trigger audit_usage_decisions after insert or update or delete on usage_decisions for each row execute function app.audit_row();
create trigger audit_assistant_actions after insert or update or delete on assistant_actions for each row execute function app.audit_row();

-- every audit row written inside an assistant action carries it (app.assistant_confirm sets app.via for its transaction)
alter table audit_log alter column request_id set default nullif(current_setting('app.via', true), '');

-- the services, with the defaults of the plans in use on October 21, 2026
insert into usage_services (service, label, provider, unit, period, included, unlimited, pause_mode, usd_per_unit, price_text, upgrade_text, measured_by, when_used_up, sort, enabled) values
  ('workers_ai', 'Workers AI (assistant, live chat, copy, email reading)', 'Cloudflare', 'neurons', 'day', 10000, false, 'pause', 0.000011,
   'About US$0.011 per 1,000 neurons. A busy day above the allowance costs cents.', null,
   'Every AI call the app makes is recorded with its neurons (provider_calls); Cloudflare''s own count is used too when the Worker or the usage workflow reports it (the larger counts).',
   'Paused until tomorrow: the live chat goes to a person, listing and search copy wait (the template text stays), Turo emails are read by the rules only, the staff assistant rests. Allow paid usage to continue today.', 10, true),
  ('workers_requests', 'Website requests (Cloudflare Worker)', 'Cloudflare', 'requests', 'month', 10000000, false, 'alert', 0.0000003,
   'US$0.30 per million requests above the allowance.', null,
   'Cloudflare''s analytics (workersInvocationsAdaptive), reported every hour by the usage workflow, or by the Worker when it has an analytics token.',
   'Never paused: pausing would stop bookings. You get the alert with the estimated cost, usually cents to a few dollars.', 20, true),
  ('workers_cpu', 'Website CPU time (Cloudflare Worker)', 'Cloudflare', 'cpu_ms', 'month', 30000000, false, 'alert', 0.00000002,
   'US$0.02 per million CPU milliseconds above the allowance.', null,
   'Cloudflare''s analytics (the CPU time of every invocation), reported every hour by the usage workflow, or by the Worker when it has an analytics token.',
   'Never paused: pausing would stop bookings. You get the alert with the estimated cost, usually cents.', 30, true),
  ('images', 'Image transformations (photo studio)', 'Cloudflare', 'transformations', 'month', 5000, false, 'pause', 0.0005,
   'US$0.50 per 1,000 unique transformations above the allowance.', null,
   'Every transformation the photo worker asks for is recorded (provider_calls).',
   'Paused until the allowance allows: a new photo keeps its original background on the site and the studio background is tried again later. Allow paid usage to continue this month.', 40, true),
  ('resend_day', 'Emails today (Resend)', 'Resend', 'emails', 'day', 100, false, 'hold', null,
   'Resend''s free plan cannot pay for extra emails.', 'Resend Pro (about US$20 a month, 50,000 emails a month, no daily limit). Upgrade in Resend, then raise the included numbers here.',
   'The outbox''s sent emails and Supabase Auth''s sign-in emails (the same Resend account).',
   'Held, never lost: booking, payment and sign-in emails still go first; digests and marketing wait for tomorrow (the priority classes of 0043).', 50, true),
  ('resend_month', 'Emails this month (Resend)', 'Resend', 'emails', 'month', 3000, false, 'hold', null,
   'Resend''s free plan cannot pay for extra emails.', 'Resend Pro (about US$20 a month, 50,000 emails a month). Upgrade in Resend, then raise the included numbers here.',
   'The outbox''s sent emails and Supabase Auth''s sign-in emails, added up over the month.',
   'Held until the month ends: the outbox stops (0018''s monthly cap). Upgrade Resend to keep sending.', 60, true),
  ('supabase_db', 'Database size (Supabase)', 'Supabase', 'bytes', 'size', 524288000, false, 'alert', null,
   'The free plan cannot pay for more.', 'Supabase Pro (US$25 a month: 8 GB database, 100 GB file storage, 250 GB egress).',
   'pg_database_size, every hour.',
   'Never blocked by us. Supabase makes a free database read only above its limit: clean up (the audit log, old events) or upgrade before then.', 70, true),
  ('supabase_storage', 'File storage (Supabase)', 'Supabase', 'bytes', 'size', 1073741824, false, 'alert', null,
   'The free plan cannot pay for more.', 'Supabase Pro (US$25 a month: 100 GB file storage).',
   'The size of every stored file (storage.objects), every hour.',
   'Never blocked by us. Clean up the largest buckets (old deploy reports first) or upgrade.', 80, true),
  ('supabase_egress', 'Data sent out (Supabase egress)', 'Supabase', 'bytes', 'month', 5368709120, false, 'alert', null,
   'The free plan cannot pay for more.', 'Supabase Pro (US$25 a month: 250 GB egress).',
   'Not readable from the database or Supabase''s API: an Admin enters the figure from the Supabase dashboard (Settings > Usage, Enter a figure).',
   'Never blocked by us. Supabase may slow a free project above its limit: upgrade if it keeps happening.', 90, true),
  ('r2_storage', 'Photo and document storage (Cloudflare R2)', 'Cloudflare', 'bytes', 'size', 10737418240, false, 'alert', 0.000000000015,
   'US$0.015 per GB a month above the allowance.', null,
   'Cloudflare''s analytics (r2StorageAdaptiveGroups), reported by the usage workflow.',
   'Never paused. The alert shows the estimated monthly cost.', 100, true),
  ('github_actions', 'GitHub Actions (tests, deploys, checks)', 'GitHub', 'minutes', 'month', 0, true, 'alert', null,
   'Free while the repository is public.', 'If the repository becomes private: 2,000 free minutes a month, then about US$0.008 a minute.',
   'Not metered while the repository is public.',
   'Nothing to pause.', 110, true),
  ('claude', 'Claude assistant (Anthropic)', 'Anthropic', 'microusd', 'day', 0, false, 'pause', 0.000001,
   'Anthropic bills per token: about US$0.002 to US$0.01 a question with the default model.', null,
   'Each Claude call is recorded with its tokens and cost (provider_calls, unit microusd), at the prices in Program settings.',
   'Paused: the included budget is US$0, so the assistant asks before spending anything. Allow paid usage to use it.', 120, false);

-- ================================================================ 3. periods, figures and states
create or replace function app.usage_period_start(p_period text, p_now timestamptz default now()) returns date
language sql stable set search_path = public, app as $$
  select case when p_period = 'day' then app.local_date(p_now) else date_trunc('month', app.local_date(p_now))::date end
$$;

create or replace function app.usage_resets_at(p_period text, p_now timestamptz default now()) returns timestamptz
language sql stable set search_path = public, app as $$
  select case p_period when 'day' then app.local_midnight(app.local_date(p_now) + 1)
                       when 'month' then app.local_midnight((date_trunc('month', app.local_date(p_now)) + interval '1 month')::date) end
$$;

-- The period's use: a day's or the month's total (each day the largest source), or the latest size.
create or replace function app.usage_used(p_service text, p_now timestamptz default now()) returns numeric
language plpgsql stable security definer set search_path = public, app as $$
declare
  s usage_services;
  v numeric;
begin
  select * into s from usage_services where service = p_service;
  if s.service is null then return 0; end if;
  if s.period = 'size' then
    select max(r.used) into v from usage_readings r
     where r.service = p_service and r.day = (select max(x.day) from usage_readings x where x.service = p_service and x.day <= app.local_date(p_now));
  else
    select sum(d.used) into v from (select max(r.used) as used from usage_readings r
       where r.service = p_service and r.day >= app.usage_period_start(s.period, p_now) and r.day <= app.local_date(p_now) group by r.day) d;
  end if;
  return coalesce(v, 0);
end $$;

create or replace function app.usage_fmt(p_unit text, p_value numeric) returns text
language sql immutable set search_path = public, app as $$
  select case p_unit
    when 'bytes' then case when p_value >= 1073741824 then to_char(round(p_value / 1073741824.0, 2), 'FM999,990.00') || ' GB'
                           else to_char(round(p_value / 1048576.0), 'FM999,999,990') || ' MB' end
    when 'microusd' then 'US$' || to_char(round(p_value / 1000000.0, 2), 'FM999,990.00')
    when 'cpu_ms' then to_char(round(p_value), 'FM999,999,999,990') || ' CPU ms'
    else to_char(round(p_value), 'FM999,999,999,990') || ' ' || p_unit end
$$;

create or replace function app.usage_usd(p numeric) returns text
language sql immutable as $$ select 'US$' || to_char(round(coalesce(p, 0), 2), 'FM999,990.00') $$;

-- The decision in force today (the latest one whose window holds today), or null.
create or replace function app.usage_decision(p_service text, p_now timestamptz default now()) returns usage_decisions
language sql stable security definer set search_path = public, app as $$
  select d.* from usage_decisions d
   where d.service = p_service and d.starts_on <= app.local_date(p_now) and d.ends_on >= app.local_date(p_now)
   order by d.decided_at desc limit 1
$$;

-- What paid usage has cost inside a decision's window: the use above the allowance at the paid rate.
create or replace function app.usage_paid_spent(p_service text, p_from date, p_to date, p_now timestamptz default now()) returns numeric
language plpgsql stable security definer set search_path = public, app as $$
declare
  s usage_services;
  v numeric := 0;
  d date;
begin
  select * into s from usage_services where service = p_service;
  if s.usd_per_unit is null then return 0; end if;
  if s.period = 'day' then
    for d in select generate_series(p_from, least(p_to, app.local_date(p_now)), interval '1 day')::date loop
      v := v + greatest(coalesce((select sum(x.used) from (select max(r.used) used from usage_readings r where r.service = p_service and r.day = d) x), 0) - s.included, 0);
    end loop;
  else
    v := greatest(app.usage_used(p_service, p_now) - s.included, 0);
  end if;
  return round(v * s.usd_per_unit, 4);
end $$;

-- One service's state now, in words and numbers (Admin > To do, Settings > Usage, the gates).
--   ok, warn (past warn_bps), free (unlimited), and once the allowance is used:
--   paused (pause_mode pause, no paid usage allowed, or its cap reached), paid (allowed and under the cap),
--   held (emails: held until the period ends), over (alert only: the estimated overage cost).
create or replace function app.usage_state(p_service text, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s usage_services;
  d usage_decisions;
  v_used numeric;
  v_state text;
  v_spent numeric := 0;
  v_over numeric := 0;
  v_share integer;
begin
  select * into s from usage_services where service = p_service;
  if s.service is null then raise exception 'Unknown service %', p_service using errcode = 'P0002'; end if;
  v_used := app.usage_used(p_service, p_now);
  d := app.usage_decision(p_service, p_now);
  if d.id is not null and d.decision = 'allow' then v_spent := app.usage_paid_spent(p_service, d.starts_on, d.ends_on, p_now); end if;
  if s.usd_per_unit is not null then v_over := round(greatest(v_used - s.included, 0) * s.usd_per_unit, 4); end if;
  v_share := case when s.unlimited then 0 when s.included > 0 then least(round(v_used * 10000.0 / s.included), 99999)::integer when v_used > 0 then 10000 else 0 end;
  v_state := case
    when s.unlimited then 'free'
    when s.included > 0 and v_used < s.included * s.warn_bps / 10000.0 then 'ok'
    when s.included > 0 and v_used < s.included then 'warn'
    when s.pause_mode = 'hold' then 'held'
    when s.pause_mode = 'alert' then 'over'
    when d.id is not null and d.decision = 'allow' and v_spent < d.cap_usd then 'paid'
    else 'paused' end;
  -- the Claude assistant before its first call: nothing used, nothing to say
  if s.service = 'claude' and not s.enabled then v_state := 'ok'; end if;
  return jsonb_build_object(
    'service', s.service, 'label', s.label, 'provider', s.provider, 'unit', s.unit, 'period', s.period,
    'used', v_used, 'included', s.included, 'unlimited', s.unlimited, 'share_bps', v_share, 'warn_bps', s.warn_bps,
    'used_text', app.usage_fmt(s.unit, v_used), 'included_text', case when s.unlimited then 'no limit' else app.usage_fmt(s.unit, s.included) end,
    'period_start', app.usage_period_start(s.period, p_now), 'resets_at', app.usage_resets_at(s.period, p_now),
    'state', v_state, 'paused', v_state in ('paused', 'held'), 'pause_mode', s.pause_mode, 'enabled', s.enabled,
    'decision', case when d.id is not null then jsonb_build_object('id', d.id, 'decision', d.decision, 'until', d.until_kind, 'ends_on', d.ends_on,
                                                                  'cap_usd', d.cap_usd, 'spent_usd', v_spent, 'decided_at', d.decided_at,
                                                                  'by', (select u.full_name from users u where u.id = d.decided_by)) end,
    'overage_usd', v_over, 'usd_per_unit', s.usd_per_unit, 'price_text', s.price_text, 'upgrade_text', s.upgrade_text,
    'measured_by', s.measured_by, 'when_used_up', s.when_used_up, 'measured_at', s.measured_at,
    'sources', coalesce((select jsonb_agg(distinct r.source) from usage_readings r where r.service = s.service and r.day >= app.local_date(p_now) - 2), '[]'::jsonb));
end $$;

-- ================================================================ 4. measuring what the database can see
create or replace function app.usage_put(p_service text, p_day date, p_source text, p_used numeric, p_by uuid default null) returns void
language sql security definer set search_path = public, app as $$
  insert into usage_readings (service, day, source, used, measured_at, measured_by)
  values (p_service, p_day, p_source, greatest(coalesce(p_used, 0), 0), now(), p_by)
  on conflict (service, day, source) do update set used = excluded.used, measured_at = excluded.measured_at, measured_by = excluded.measured_by
$$;

-- The day's emails that count against Resend: the outbox's sent ones and Supabase Auth's (0043).
create or replace function app.usage_emails_on(p_day date, p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select (select count(*)::integer from notification_outbox o
           where o.status = 'sent' and o.sent_at >= app.local_midnight(p_day) and o.sent_at < app.local_midnight(p_day + 1))
       + app.auth_emails_today(least(p_now, app.local_midnight(p_day + 1) - interval '1 microsecond'))
$$;

-- Today's and yesterday's figures of one service from the app's own records (the source 'app'); sizes today.
create or replace function app.usage_measure(p_service text, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  d date;
  v numeric;
begin
  if p_service in ('workers_ai', 'images', 'claude', 'resend_day', 'resend_month') then
    foreach d in array array[app.local_date(p_now) - 1, app.local_date(p_now)] loop
      if p_service in ('resend_day', 'resend_month') then
        v := app.usage_emails_on(d, p_now);
      else
        select coalesce(sum(c.units), 0) into v from provider_calls c
         where c.created_at >= app.local_midnight(d) and c.created_at < app.local_midnight(d + 1)
           and c.unit = case p_service when 'workers_ai' then 'neurons' when 'images' then 'transformations' else 'microusd' end
           and (p_service <> 'claude' or c.provider like 'anthropic%');
      end if;
      perform app.usage_put(p_service, d, 'app', v);
    end loop;
  elsif p_service = 'supabase_db' then
    perform app.usage_put(p_service, app.local_date(p_now), 'app', pg_database_size(current_database()));
  elsif p_service = 'supabase_storage' then
    v := 0;
    if to_regclass('storage.objects') is not null then
      begin
        execute $q$select coalesce(sum(nullif(metadata ->> 'size', '')::numeric), 0) from storage.objects$q$ into v;
      exception when others then v := 0;
      end;
    end if;
    perform app.usage_put(p_service, app.local_date(p_now), 'app', v);
  end if;
  update usage_services set measured_at = p_now where service = p_service and p_service in ('workers_ai', 'images', 'claude', 'resend_day', 'resend_month', 'supabase_db', 'supabase_storage');
end $$;

-- Figures from outside the database: Cloudflare's analytics (the Worker's hourly job when it has an analytics token, or
-- the usage workflow), or Supabase. p: {source: cloudflare | supabase, days: [{day, values: {service: number}}]}.
-- Unknown services and negative numbers are refused; a day outside the last 40 is ignored.
create or replace function app.usage_record_external(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_source text := coalesce(p ->> 'source', '');
  x jsonb;
  k text;
  v text;
  d date;
  n integer := 0;
begin
  if v_source not in ('cloudflare', 'supabase') then raise exception 'Unknown source %', v_source using errcode = '22023'; end if;
  for x in select * from jsonb_array_elements(coalesce(p -> 'days', '[]'::jsonb)) loop
    d := nullif(x ->> 'day', '')::date;
    if d is null or d < app.today() - 40 or d > app.today() + 1 then continue; end if;
    for k, v in select * from jsonb_each_text(coalesce(x -> 'values', '{}'::jsonb)) loop
      if not exists (select 1 from usage_services s where s.service = k) then raise exception 'Unknown service %', k using errcode = '22023'; end if;
      if v !~ '^\d+(\.\d+)?$' then raise exception 'Not a number for %: %', k, v using errcode = '22023'; end if;
      perform app.usage_put(k, d, v_source, v::numeric);
      update usage_services set measured_at = now() where service = k;
      n := n + 1;
    end loop;
  end loop;
  return jsonb_build_object('ok', true, 'recorded', n, 'refresh', app.job_usage_refresh());
end $$;

-- ================================================================ 5. the gates: what paid usage allows today
-- The paid allowance a decision gives today, in the service's units (Workers AI: neurons on top of the included ones).
create or replace function app.usage_apply(p_service text, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  s usage_services;
  d usage_decisions;
  v_extra numeric := 0;
  v_before numeric := 0;
begin
  select * into s from usage_services where service = p_service for update;
  if s.service is null then return; end if;
  d := app.usage_decision(p_service, p_now);
  if d.id is not null and d.decision = 'allow' and s.usd_per_unit > 0 then
    -- what the window spent before today; today may use the rest of the cap
    if s.period = 'day' and d.starts_on < app.local_date(p_now) then
      v_before := app.usage_paid_spent(p_service, d.starts_on, app.local_date(p_now) - 1, p_now);
    end if;
    v_extra := floor(greatest(d.cap_usd - v_before, 0) / s.usd_per_unit);
  end if;
  update usage_services set paid_extra = v_extra, paid_extra_on = app.local_date(p_now), updated_at = now() where service = p_service;
end $$;

-- app.settings() (0001) with the usage guard on top: the daily Workers AI gates (live chat, listing copy, search copy,
-- Turo email reading, vision; 0032, 0042, 0060, 0061, 0063) stop at the included neurons unless paid usage is allowed
-- today, and the email caps never exceed Resend's included emails. Stored settings are untouched (Admin edits read the
-- table itself).
alter function app.settings(date) rename to settings_base;
create or replace function app.settings(p_on date default (now() at time zone 'America/Toronto')::date)
returns program_settings language plpgsql stable security definer set search_path = public, app as $$
declare
  r program_settings := app.settings_base(p_on);
  v_ai numeric;
  v_extra integer := 0;
  v_day numeric;
  v_month numeric;
begin
  if r.id is null then return r; end if;
  select max(s.included) filter (where s.service = 'workers_ai'),
         coalesce(max(case when s.paid_extra_on = p_on then s.paid_extra end) filter (where s.service = 'workers_ai'), 0),
         max(s.included) filter (where s.service = 'resend_day'), max(s.included) filter (where s.service = 'resend_month')
    into v_ai, v_extra, v_day, v_month
    from usage_services s where s.service in ('workers_ai', 'resend_day', 'resend_month') and s.enabled;
  if v_ai is not null then
    r.chat_ai_total_daily_neurons := least(r.chat_ai_total_daily_neurons, v_ai)::integer + v_extra;
    r.listing_ai_daily_neurons := least(r.listing_ai_daily_neurons, v_ai)::integer + v_extra;
    if v_extra > 0 then
      r.chat_ai_daily_neurons := r.chat_ai_daily_neurons + v_extra;
      r.seo_ai_daily_neurons := r.seo_ai_daily_neurons + v_extra;
      r.ai_vision_daily_neurons := r.ai_vision_daily_neurons + v_extra;
      r.assistant_daily_neurons := r.assistant_daily_neurons + v_extra;
    end if;
  end if;
  if v_day is not null and v_day >= 1 then r.notify_daily_cap := least(r.notify_daily_cap, v_day)::integer; end if;
  if v_month is not null and v_month >= 1 then r.notify_monthly_cap := least(r.notify_monthly_cap, v_month)::integer; end if;
  return r;
end $$;

-- ================================================================ 6. refresh, alerts and emails
insert into notification_catalogue (code, audience, category, subject, preheader, has_email, priority, emitted_by, link_path)
values ('staff_usage_alert', 'staff_admin', 'transactional', '{{usage_title}}', '{{usage_used}} of {{usage_included}} used.', true, 3, 'app.job_usage_refresh (0080)', '/admin/settings/usage')
on conflict (code) do nothing;

create or replace function app.usage_alert_title(p_level integer, p_state jsonb) returns text
language sql immutable as $$
  with x as (select p_state || jsonb_build_object('label', regexp_replace(p_state ->> 'label', ' \(.*\)$', '')) as p_state)
  select case
    when p_level = 80 then format('%s at %s%% of the included allowance', p_state ->> 'label', round((p_state ->> 'share_bps')::numeric / 100))
    when p_state ->> 'pause_mode' = 'alert' then format('Included %s used up for %s: no pause, estimated cost %s', p_state ->> 'label',
                                                         case p_state ->> 'period' when 'day' then 'today' when 'month' then 'this month' else 'now' end,
                                                         app.usage_usd((p_state ->> 'overage_usd')::numeric))
    else format('Included %s used up for %s', p_state ->> 'label', case p_state ->> 'period' when 'day' then 'today' when 'month' then 'this month' else 'now' end) end
  from x
$$;

-- What a used-up allowance does and what to do, in a sentence for the email and the card.
create or replace function app.usage_effect(p_state jsonb) returns text
language sql stable security definer set search_path = public, app as $$
  select s.when_used_up from usage_services s where s.service = p_state ->> 'service'
$$;

-- One service: measure, store the state, open the alerts it has reached (once per period and level).
create or replace function app.usage_refresh_service(p_service text, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  st jsonb;
  s usage_services;
  v_start date;
begin
  perform app.usage_measure(p_service, p_now);
  perform app.usage_apply(p_service, p_now);
  st := app.usage_state(p_service, p_now);
  select * into s from usage_services where service = p_service;
  -- a size is alerted once a month
  v_start := date_trunc('month', app.local_date(p_now))::date;
  if s.period <> 'size' then v_start := (st ->> 'period_start')::date; end if;
  update usage_services set used = (st ->> 'used')::numeric, period_start = v_start, state = st ->> 'state', updated_at = now() where service = p_service;
  if s.enabled and not s.unlimited and (s.included > 0 or (st ->> 'used')::numeric > 0 or st ->> 'state' = 'paused') then
    if (st ->> 'share_bps')::integer >= s.warn_bps and s.included > 0 then
      insert into usage_alerts (service, period_start, level, used, included) values (p_service, v_start, 80, (st ->> 'used')::numeric, s.included)
      on conflict (service, period_start, level) do nothing;
    end if;
    if (st ->> 'used')::numeric >= s.included and (s.included > 0 or st ->> 'state' = 'paused') then
      insert into usage_alerts (service, period_start, level, used, included) values (p_service, v_start, 100, (st ->> 'used')::numeric, s.included)
      on conflict (service, period_start, level) do nothing;
      -- the 80% email is not needed once the 100% one goes
      update usage_alerts set emailed_at = coalesce(emailed_at, p_now), email_note = coalesce(email_note, 'covered by the 100% alert')
       where service = p_service and period_start = v_start and level = 80 and emailed_at is null;
    end if;
  end if;
  return st;
end $$;

-- The alert emails: to the alert address of Program settings, never in the quiet hours (they wait for the morning),
-- at most usage_alert_max_emails a day.
create or replace function app.usage_send_alerts(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_hour integer := app.local_hour(p_now);
  v_quiet boolean;
  v_sent integer := (select count(*) from usage_alerts where emailed_at >= app.local_midnight(app.local_date(p_now)) and email_note is null);
  a usage_alerts;
  n integer := 0;
begin
  v_quiet := case when ps.uptime_quiet_from_hour > ps.uptime_quiet_until_hour then v_hour >= ps.uptime_quiet_from_hour or v_hour < ps.uptime_quiet_until_hour
                  else v_hour >= ps.uptime_quiet_from_hour and v_hour < ps.uptime_quiet_until_hour end;
  if v_quiet then return 0; end if;
  for a in select * from usage_alerts where emailed_at is null and dismissed_at is null and created_at > p_now - interval '35 days' order by level desc, created_at loop
    if v_sent >= ps.usage_alert_max_emails then
      update usage_alerts set emailed_at = p_now, email_note = 'not emailed: the day''s usage alert emails were used (shown on Admin > To do)' where id = a.id;
      continue;
    end if;
    perform app.emit_event('staff_usage_alert', 'usage_alert', a.id, jsonb_build_object('service', a.service, 'level', a.level), 'staff_usage_alert:' || a.id);
    update usage_alerts set emailed_at = p_now where id = a.id;
    v_sent := v_sent + 1;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Photos whose studio background waited for the image allowance (features/listing/worker.ts: fallback "usage_paused"):
-- once transformations may be used again, each gets a new process_photo job (a few each hour).
create or replace function app.usage_retry_photos(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  j listing_jobs;
  n integer := 0;
begin
  if (app.usage_state('images', p_now) ->> 'paused')::boolean then return 0; end if;
  for j in select * from listing_jobs x
            where x.kind = 'process_photo' and x.status = 'succeeded' and x.output ->> 'fallback_reason' like 'usage_paused%'
              and coalesce((x.output ->> 'usage_retried')::boolean, false) = false
              and x.finished_at > p_now - interval '60 days'
            order by x.finished_at limit 10 loop
    insert into listing_jobs (intake_id, vehicle_id, kind, vehicle_photo_id, max_attempts, input)
    values (j.intake_id, j.vehicle_id, 'process_photo', j.vehicle_photo_id, j.max_attempts, jsonb_build_object('usage_retry', true))
    on conflict do nothing;
    update listing_jobs set output = output || '{"usage_retried": true}'::jsonb where id = j.id;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function app.job_usage_refresh(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s record;
  st jsonb;
  out jsonb := '{}'::jsonb;
begin
  for s in select service from usage_services order by sort loop
    st := app.usage_refresh_service(s.service, p_now);
    out := out || jsonb_build_object(s.service, st ->> 'state');
  end loop;
  return jsonb_build_object('states', out, 'emailed', app.usage_send_alerts(p_now), 'photos_retried', app.usage_retry_photos(p_now));
end $$;

-- The gate a feature asks before it spends (the staff assistant, the Claude provider, the photo worker): measured now.
-- Returns {ok, state, paused, resets_at, used, included, ...}. A closed gate opens the 100% alert at once.
create or replace function app.usage_gate(p_service text, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  st jsonb;
  ps program_settings := app.settings(app.local_date(p_now));
  v_mine numeric;
begin
  if p_service = 'claude' then update usage_services set enabled = true where service = 'claude' and not enabled; end if;
  st := app.usage_refresh_service(p_service, p_now);
  if p_service = 'workers_ai' then
    -- the assistant's own share of the day (assistant_daily_neurons, plus any paid allowance)
    select coalesce(sum(c.units), 0) into v_mine from provider_calls c
     where c.purpose = 'staff_assistant' and c.unit = 'neurons' and c.created_at >= app.local_midnight(app.local_date(p_now));
    st := st || jsonb_build_object('assistant_used', v_mine, 'assistant_cap', ps.assistant_daily_neurons,
                                   'all_cap', ps.chat_ai_total_daily_neurons);
    return st || jsonb_build_object('ok', not (st ->> 'paused')::boolean and v_mine < ps.assistant_daily_neurons
                                          and (st ->> 'used')::numeric < ps.chat_ai_total_daily_neurons);
  end if;
  return st || jsonb_build_object('ok', not (st ->> 'paused')::boolean);
end $$;

-- The assistant's own model calls (Workers AI neurons or Claude micro-dollars), recorded like the other AI calls.
create or replace function app.usage_call_record(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_unit text := coalesce(p ->> 'unit', 'neurons');
begin
  if v_unit not in ('neurons', 'microusd') then raise exception 'Unknown unit %', v_unit using errcode = '22023'; end if;
  insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit)
  values (left(coalesce(nullif(p ->> 'provider', ''), 'workers-ai'), 120), left(coalesce(nullif(p ->> 'purpose', ''), 'staff_assistant'), 60),
          coalesce((p ->> 'ok')::boolean, true), left(p ->> 'error', 300), greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0,
          greatest(coalesce((p ->> 'units')::numeric, 0), 0), v_unit);
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 7. the alert email's recipient and values
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0080;
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_to text;
begin
  if p_c.code = 'staff_usage_alert' then
    -- the alert address of Program settings (rent@carmacars.ca by default), as the site alerts (0062)
    v_to := lower(btrim((app.settings()).uptime_alert_email));
    return query select 'staff_admin'::text, (select u.id from users u where lower(u.email) = v_to limit 1), v_to,
                        coalesce((select u.full_name from users u where lower(u.email) = v_to limit 1), 'CarmaCars admin'), null::uuid, null::uuid, true;
    return;
  end if;
  return query select * from app.notification_recipients_pre0080(p_event, p_c);
end $$;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0080;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0080(p_code, p_event, p_to);
  a usage_alerts;
  st jsonb;
begin
  if p_code = 'staff_usage_alert' then
    select * into a from usage_alerts where id = p_event.entity_id;
    st := app.usage_state(a.service);
    x := x || jsonb_build_object(
      'usage_title', app.usage_alert_title(a.level, st),
      'service_label', st ->> 'label',
      'usage_used', st ->> 'used_text', 'usage_included', st ->> 'included_text',
      'usage_share', round((st ->> 'share_bps')::numeric / 100) || '%',
      'usage_period', case st ->> 'period' when 'day' then 'Today, Toronto time' when 'month' then 'This month' else 'Now (a size, not a period)' end,
      'usage_resets', coalesce(app.fmt_at((st ->> 'resets_at')::timestamptz), 'It does not reset: it is a size'),
      'usage_effect', case when a.level = 80 then 'Nothing changes yet. ' else '' end || app.usage_effect(st),
      'usage_cost', coalesce(st ->> 'upgrade_text', st ->> 'price_text') || case when (st ->> 'overage_usd')::numeric > 0
                      then ' Estimated so far: ' || app.usage_usd((st ->> 'overage_usd')::numeric) || '.' else '' end,
      'usage_advice', case when st ->> 'pause_mode' = 'pause' and a.level = 100 then 'Open Usage to allow paid usage until the end of today or this month, up to an amount you choose, or keep it paused. Nobody answering keeps it paused.'
                           when st ->> 'pause_mode' = 'pause' then 'Nothing to do yet. When it is used up the features pause and you are asked before anything is paid.'
                           when st ->> 'pause_mode' = 'hold' then 'Booking, payment and sign-in emails still go first; the others wait. To send more, upgrade the plan, then raise the included numbers in Settings > Usage.'
                           else 'Nothing is paused. ' || coalesce(st ->> 'upgrade_text', 'Check the figure in Settings > Usage.') end);
  end if;
  return x;
end $$;

-- ================================================================ 8. Admin: the To do cards, Settings > Usage, decisions
-- The cards of Admin > To do: open alerts of the current periods, and the emails held by the caps.
create or replace function app.usage_cards(p_user uuid, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  em jsonb;
begin
  perform app.assert_admin(p_user);
  em := app.email_usage(p_now);
  return jsonb_build_object(
    'cards', coalesce((select jsonb_agg(c order by (c ->> 'level')::integer desc, c ->> 'sort') from (
        select app.usage_state(a.service, p_now) || jsonb_build_object('alert_id', a.id, 'level', a.level, 'sort', lpad(s.sort::text, 4, '0'),
                 'title', app.usage_alert_title(a.level, app.usage_state(a.service, p_now)), 'emailed_at', a.emailed_at, 'email_note', a.email_note) c
          from usage_alerts a join usage_services s on s.service = a.service
         where a.dismissed_at is null and a.created_at > p_now - interval '35 days'
           and a.period_start = case when s.period = 'day' then app.local_date(p_now) else date_trunc('month', app.local_date(p_now))::date end
           and not (a.level = 80 and exists (select 1 from usage_alerts b where b.service = a.service and b.period_start = a.period_start and b.level = 100 and b.dismissed_at is null))) x), '[]'::jsonb),
    'emails_held', coalesce((em ->> 'held')::integer, 0), 'email', em);
end $$;

create or replace function app.usage_page(p_user uuid, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_user);
  return jsonb_build_object(
    'services', coalesce((select jsonb_agg(app.usage_state(s.service, p_now) || jsonb_build_object('history', coalesce((
        select jsonb_agg(jsonb_build_object('day', d.day, 'used', d.used) order by d.day) from (
          select r.day, max(r.used) used from usage_readings r where r.service = s.service and r.day > app.local_date(p_now) - 30 group by r.day) d), '[]'::jsonb),
        'decisions', coalesce((select jsonb_agg(jsonb_build_object('decision', d.decision, 'until', d.until_kind, 'starts_on', d.starts_on, 'ends_on', d.ends_on,
                                 'cap_usd', d.cap_usd, 'at', d.decided_at, 'by', (select u.full_name from users u where u.id = d.decided_by)) order by d.decided_at desc)
                                from (select * from usage_decisions d where d.service = s.service order by d.decided_at desc limit 5) d), '[]'::jsonb))
        order by s.sort) from usage_services s), '[]'::jsonb),
    'alerts', coalesce((select jsonb_agg(jsonb_build_object('service', a.service, 'level', a.level, 'period_start', a.period_start, 'at', a.created_at,
                                         'emailed_at', a.emailed_at, 'email_note', a.email_note) order by a.created_at desc)
                          from (select * from usage_alerts order by created_at desc limit 20) a), '[]'::jsonb),
    'alert_email', (app.settings()).uptime_alert_email,
    'cloudflare_at', (select max(r.measured_at) from usage_readings r where r.source = 'cloudflare'),
    'now', p_now);
end $$;

-- An Admin's answer once an allowance is used up. p: {service, decision: allow | keep_paused, until: day | month, cap_usd, note}.
create or replace function app.usage_decide(p_user uuid, p jsonb, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s usage_services;
  v_decision text := coalesce(p ->> 'decision', '');
  v_until text := coalesce(nullif(p ->> 'until', ''), 'day');
  v_cap numeric := nullif(p ->> 'cap_usd', '')::numeric;
  v_id uuid;
begin
  perform app.assert_admin(p_user);
  select * into s from usage_services where service = p ->> 'service';
  if s.service is null then raise exception 'Choose the service' using errcode = 'P0002'; end if;
  if s.pause_mode <> 'pause' then
    raise exception '%', case s.pause_mode when 'hold' then format('%s cannot pay for more on the free plan: %s', s.label, coalesce(s.upgrade_text, 'upgrade the plan'))
                                           else format('%s is never paused, so there is nothing to allow. %s', s.label, coalesce(s.upgrade_text, '')) end using errcode = '22023';
  end if;
  if v_decision not in ('allow', 'keep_paused') then raise exception 'Choose allow paid usage or keep paused' using errcode = '22023'; end if;
  if v_until not in ('day', 'month') then raise exception 'Choose until the end of today or this month' using errcode = '22023'; end if;
  if s.period = 'month' and v_until = 'day' then v_until := 'month'; end if;
  if v_decision = 'allow' and (v_cap is null or v_cap <= 0 or v_cap > 1000) then
    raise exception 'Enter the most it may cost, from US$0.01 to US$1,000' using errcode = '22023';
  end if;
  insert into usage_decisions (service, decision, until_kind, starts_on, ends_on, cap_usd, decided_by, note)
  values (s.service, v_decision, v_until, app.local_date(p_now),
          case when v_until = 'day' then app.local_date(p_now) else (date_trunc('month', app.local_date(p_now)) + interval '1 month - 1 day')::date end,
          case when v_decision = 'allow' then round(v_cap, 2) end, p_user, nullif(left(btrim(coalesce(p ->> 'note', '')), 300), ''))
  returning id into v_id;
  perform app.usage_apply(s.service, p_now);
  return app.usage_refresh_service(s.service, p_now) || jsonb_build_object('decision_id', v_id);
end $$;

-- An Admin edits an allowance: p {service, included, warn_bps}. Sizes and amounts in the service's unit.
create or replace function app.usage_service_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s usage_services;
  -- sizes may be typed in megabytes (included_mb), as the page shows them
  v_inc numeric := coalesce(nullif(p ->> 'included', '')::numeric, nullif(p ->> 'included_mb', '')::numeric * 1048576);
  v_warn integer := nullif(p ->> 'warn_bps', '')::integer;
begin
  perform app.assert_admin(p_user);
  select * into s from usage_services where service = p ->> 'service' for update;
  if s.service is null then raise exception 'Choose the service' using errcode = 'P0002'; end if;
  if s.unlimited then raise exception '% has no allowance to set', s.label using errcode = '22023'; end if;
  if v_inc is not null and (v_inc < 0 or v_inc > 1e15) then raise exception 'Enter the included amount as a number, 0 or more' using errcode = '22023'; end if;
  if v_warn is not null and (v_warn < 1000 or v_warn > 9900) then raise exception 'The early warning is between 10%% and 99%%' using errcode = '22023'; end if;
  update usage_services set included = coalesce(v_inc, included), warn_bps = coalesce(v_warn, warn_bps), updated_at = now() where service = s.service;
  return app.usage_refresh_service(s.service);
end $$;

-- A figure an Admin typed (Supabase egress from its dashboard, or a correction): p {service, day, used}.
create or replace function app.usage_reading_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s usage_services;
  v_day date := coalesce(nullif(p ->> 'day', '')::date, app.today());
  v_used numeric := coalesce(nullif(p ->> 'used', '')::numeric, nullif(p ->> 'used_mb', '')::numeric * 1048576);
begin
  perform app.assert_admin(p_user);
  select * into s from usage_services where service = p ->> 'service';
  if s.service is null then raise exception 'Choose the service' using errcode = 'P0002'; end if;
  if v_used is null or v_used < 0 then raise exception 'Enter the figure, 0 or more' using errcode = '22023'; end if;
  if v_day > app.today() or v_day < app.today() - 40 then raise exception 'The day is in the last 40 days' using errcode = '22023'; end if;
  perform app.usage_put(s.service, v_day, 'manual', v_used, p_user);
  return app.usage_refresh_service(s.service);
end $$;

create or replace function app.usage_alert_dismiss(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_user);
  update usage_alerts set dismissed_at = now(), dismissed_by = p_user where id = (p ->> 'id')::uuid and dismissed_at is null;
  if not found then raise exception 'Alert not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 9. the staff assistant: reads
-- The portal and what the person may see there. Admin: everything. Assistant (VA): by function. Field: cars and their
-- own work.
create or replace function app.assistant_who(p_user uuid, p_portal text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_fn text;
begin
  if p_user is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if p_portal = 'admin' then
    if not app.user_is_admin(p_user) then raise exception 'Only an Admin uses the Admin assistant' using errcode = '42501'; end if;
    return jsonb_build_object('portal', 'admin', 'fn', null);
  elsif p_portal = 'va' then
    if not exists (select 1 from staff_profiles sp join user_roles r on r.user_id = sp.user_id and r.role = 'va' join users u on u.id = sp.user_id and u.status = 'active'
                    where sp.user_id = p_user and sp.staff_type = 'va' and sp.is_active) then
      raise exception 'Only an assistant uses this portal''s assistant' using errcode = '42501';
    end if;
    v_fn := app.va_active_fn(p_user);
    return jsonb_build_object('portal', 'va', 'fn', v_fn);
  elsif p_portal = 'field' then
    if not app.user_is_field(p_user) then raise exception 'Only field staff use the field assistant' using errcode = '42501'; end if;
    return jsonb_build_object('portal', 'field', 'fn', null);
  end if;
  raise exception 'Unknown portal %', p_portal using errcode = '22023';
end $$;

-- Find things by a few words, within what the person may see. p {portal, kind, q}. kind: booking, renter, owner, car,
-- invoice, toll, car_now (who has the car now), owner_balance. At most 6 rows each, with the ids the actions need.
create or replace function app.assistant_find(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  w jsonb := app.assistant_who(p_user, coalesce(p ->> 'portal', ''));
  v_portal text := w ->> 'portal';
  v_fn text := w ->> 'fn';
  v_kind text := coalesce(p ->> 'kind', '');
  q text := left(btrim(coalesce(p ->> 'q', '')), 80);
  l text;
  n text;
  v_full boolean;
  v_rows jsonb;
  refuse text;
begin
  refuse := case
    when v_kind in ('booking') and v_portal = 'field' then 'Field staff see bookings through their jobs'
    when v_kind = 'renter' and not (v_portal = 'admin' or v_fn in ('cs', 'sales', 'finance')) then 'Renters are found by an Admin, customer service, sales or finance'
    when v_kind = 'owner' and not (v_portal = 'admin' or v_fn in ('finance', 'fleet')) then 'Owners are found by an Admin, finance or fleet'
    when v_kind in ('invoice', 'owner_balance', 'toll') and not (v_portal = 'admin' or v_fn = 'finance') then 'Invoices, owner balances and tolls are Finance work'
    when v_kind not in ('booking', 'renter', 'owner', 'car', 'invoice', 'toll', 'car_now', 'owner_balance') then 'Unknown search'
  end;
  if refuse is not null then raise exception '%', refuse using errcode = '42501'; end if;
  -- full names and contact details: Admin, customer service, sales and finance; others see first names
  v_full := v_portal = 'admin' or v_fn in ('cs', 'sales', 'finance');
  l := '%' || replace(replace(replace(lower(q), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  n := upper(regexp_replace(q, '[^A-Za-z0-9]', '', 'g'));

  if v_kind = 'booking' then
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rows from (
      select jsonb_build_object('booking_number', b.booking_number, 'id', b.id, 'status', b.status,
               'renter', case when v_full then r.legal_name else split_part(btrim(coalesce(r.legal_name, '')), ' ', 1) end,
               'car', app.vehicle_name(b.vehicle_id), 'vehicle_id', b.vehicle_id, 'pickup_at', b.pickup_at, 'return_at', b.return_at) x
        from bookings b left join renters r on r.id = b.renter_id left join vehicles v on v.id = b.vehicle_id
       where q <> '' and ((n <> '' and upper(regexp_replace(b.booking_number, '[^A-Za-z0-9]', '', 'g')) like '%' || n || '%')
              or lower(coalesce(r.legal_name, '')) like l or lower(coalesce(r.email, '')) like l
              or lower(concat_ws(' ', v.year::text, v.make, v.model)) like l or (n <> '' and upper(coalesce(v.plate, '')) like '%' || n || '%'))
       order by abs(extract(epoch from b.pickup_at - now())) limit 6) s;
  elsif v_kind = 'renter' then
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rows from (
      select jsonb_build_object('id', r.id, 'name', r.legal_name, 'email', r.email, 'mobile', r.mobile,
               'bookings', (select count(*) from bookings b where b.renter_id = r.id)) x
        from renters r
       where q <> '' and (lower(coalesce(r.legal_name, '')) like l or lower(coalesce(r.email, '')) like l
              or (length(regexp_replace(q, '\D', '', 'g')) >= 4 and regexp_replace(coalesce(r.mobile, ''), '\D', '', 'g') like '%' || regexp_replace(q, '\D', '', 'g') || '%'))
       order by r.created_at desc limit 6) s;
  elsif v_kind = 'owner' then
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rows from (
      select jsonb_build_object('id', o.id, 'name', o.legal_name, 'status', o.status,
               'email', case when v_portal = 'admin' or v_fn = 'finance' then o.email end, 'phone', case when v_portal = 'admin' or v_fn = 'finance' then o.phone end,
               'cars', (select count(*) from vehicles v where v.owner_id = o.id and v.status not in ('exited', 'declined'))) x
        from owners o
       where q <> '' and (lower(o.legal_name) like l or lower(coalesce(o.email, '')) like l or lower(coalesce(o.corporation_name, '')) like l)
       order by o.created_at desc limit 6) s;
  elsif v_kind = 'car' then
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rows from (
      select jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'status', v.status, 'fleet_number', v.fleet_number,
               'slug', (select l2.slug from vehicle_listings l2 where l2.vehicle_id = v.id), 'listing', (select l2.status from vehicle_listings l2 where l2.vehicle_id = v.id)) x
        from vehicles v
       where v.status not in ('exited', 'declined') and coalesce(v.is_sample, false) = false
         and (q = '' or lower(concat_ws(' ', v.year::text, v.make, v.model, v.trim, v.colour)) like l or lower(coalesce(v.fleet_number, '')) like l
              or (n <> '' and (upper(regexp_replace(coalesce(v.plate, ''), '[^A-Za-z0-9]', '', 'g')) like '%' || n || '%' or upper(coalesce(v.vin, '')) like '%' || n || '%')))
       order by v.make, v.model limit 6) s;
  elsif v_kind = 'car_now' then
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rows from (
      select jsonb_build_object('car', app.vehicle_name(v.id), 'vehicle_id', v.id, 'plate', v.plate, 'car_status', v.status,
               'booking_number', b.booking_number, 'renter', case when b.id is null then null when v_full then r.legal_name else split_part(btrim(coalesce(r.legal_name, '')), ' ', 1) end,
               'renter_mobile', case when v_full then r.mobile end, 'since', b.pickup_at, 'due_back', b.return_at,
               'late', b.id is not null and b.return_at < now()) x
        from vehicles v
        left join lateral (select * from bookings b2 where b2.vehicle_id = v.id and b2.status = 'on_rent' order by b2.pickup_at desc limit 1) b on true
        left join renters r on r.id = b.renter_id
       where v.status not in ('exited', 'declined') and coalesce(v.is_sample, false) = false
         and (lower(concat_ws(' ', v.year::text, v.make, v.model, v.colour)) like l or lower(coalesce(v.fleet_number, '')) like l
              or (n <> '' and upper(regexp_replace(coalesce(v.plate, ''), '[^A-Za-z0-9]', '', 'g')) like '%' || n || '%'))
       order by v.make, v.model limit 6) s;
  elsif v_kind = 'invoice' then
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rows from (
      select jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'owner', o.legal_name, 'owner_id', o.id, 'status', i.status,
               'total_cents', i.total_cents, 'balance_cents', i.balance_cents, 'due_on', i.due_on) x
        from owner_invoices i join owners o on o.id = i.owner_id
       where q <> '' and ((n <> '' and upper(regexp_replace(i.invoice_number, '[^A-Za-z0-9]', '', 'g')) like '%' || n || '%') or lower(o.legal_name) like l)
       order by i.created_at desc limit 6) s;
  elsif v_kind = 'owner_balance' then
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rows from (
      select jsonb_build_object('owner_id', o.id, 'owner', o.legal_name,
               'balance_cents', (select coalesce(sum(i.balance_cents), 0) from owner_invoices i where i.owner_id = o.id and i.balance_cents > 0
                                   and i.status not in ('draft', 'void', 'paid', 'deducted')),
               'open_invoices', coalesce((select jsonb_agg(jsonb_build_object('invoice_number', i.invoice_number, 'status', i.status, 'balance_cents', i.balance_cents, 'due_on', i.due_on) order by i.due_on)
                                   from owner_invoices i where i.owner_id = o.id and i.balance_cents > 0 and i.status not in ('draft', 'void', 'paid', 'deducted')), '[]'::jsonb)) x
        from owners o
       where q <> '' and (lower(o.legal_name) like l or lower(coalesce(o.email, '')) like l or lower(coalesce(o.corporation_name, '')) like l)
       order by o.legal_name limit 6) s;
  elsif v_kind = 'toll' then
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rows from (
      select jsonb_build_object('id', t.id, 'notice_number', t.notice_number, 'kind', t.kind, 'authority', t.authority, 'plate', t.plate,
               'occurred_at', t.occurred_at, 'amount_cents', t.amount_cents, 'status', t.status, 'matched_to', t.matched_to,
               'booking_number', (select b.booking_number from bookings b where b.id = t.booking_id), 'match_confidence', t.match_confidence) x
        from toll_tickets t
       where t.status = 'logged' and (q = '' or lower(coalesce(t.notice_number, '')) like l or (n <> '' and upper(coalesce(t.plate, '')) like '%' || n || '%'))
       order by t.occurred_at desc limit 6) s;
  end if;
  return jsonb_build_object('kind', v_kind, 'q', q, 'rows', v_rows, 'count', jsonb_array_length(v_rows));
end $$;

-- ================================================================ 10. the staff assistant: actions
-- The changes the assistant may propose, and the door each goes through: the same door and function as the screen.
create or replace function app.assistant_action_door(p_tool text, p_portal text, p_name text) returns text
language sql immutable as $$
  select case
    when p_tool = 'record_payment' and p_name = 'manual_payment_record' then 'ops_do'
    when p_tool = 'add_rental' and p_name = 'manual_rental_create' then 'ops_do'
    when p_tool = 'set_rates' and p_name = 'rate_card_save' then 'ops_do'
    when p_tool = 'create_task' and p_name = 'task_create' and p_portal in ('admin', 'va') then 'ops_do'
    when p_tool = 'send_payment_link' and p_name = 'owner_invoice_resend' and p_portal in ('admin', 'va') then 'ops_do'
    when p_tool in ('publish_car', 'send_payment_link', 'confirm_toll') and p_portal in ('admin', 'va')
         and ((p_tool = 'publish_car' and p_name = 'listing_publish_now') or (p_tool = 'send_payment_link' and p_name = 'resend_offer')
              or (p_tool = 'confirm_toll' and p_name = 'toll_confirm'))
      then case p_portal when 'admin' then 'admin_do' else 'va_do' end
  end
$$;

-- A proposed change: stored as the card the person sees, nothing runs. p {portal, tool, name, args, summary}.
create or replace function app.assistant_propose(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  w jsonb := app.assistant_who(p_user, coalesce(p ->> 'portal', ''));
  v_call text := app.assistant_action_door(p ->> 'tool', w ->> 'portal', p ->> 'name');
  v_id uuid;
begin
  if v_call is null then raise exception 'The assistant cannot do that here: use the screen' using errcode = '42501'; end if;
  if jsonb_typeof(coalesce(p -> 'args', '{}'::jsonb)) <> 'object' then raise exception 'The details are not readable' using errcode = '22023'; end if;
  -- an assistant's function travels with the action, as the screens send it
  insert into assistant_actions (user_id, portal, tool, call, name, args, summary)
  values (p_user, w ->> 'portal', p ->> 'tool', v_call, p ->> 'name',
          (coalesce(p -> 'args', '{}'::jsonb) - '_va') || case when w ->> 'fn' is not null then jsonb_build_object('_va', w ->> 'fn') else '{}'::jsonb end,
          left(btrim(coalesce(p ->> 'summary', '')), 600))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'summary', left(btrim(coalesce(p ->> 'summary', '')), 600), 'status', 'proposed');
end $$;

-- Confirm: the stored action runs through the door, as the person, with the same checks as the screen. The audit log
-- gets the action (actor: the person, note "via assistant") and every row it writes is marked request_id 'via assistant'.
create or replace function app.assistant_confirm(p_user uuid, p_aal text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a assistant_actions;
  v_out jsonb;
  v_err text;
begin
  select * into a from assistant_actions where id = nullif(p ->> 'id', '')::uuid for update;
  if a.id is null or a.user_id <> p_user then raise exception 'Action not found' using errcode = 'P0002'; end if;
  if a.status <> 'proposed' then raise exception 'This action was already %', case a.status when 'done' then 'done' when 'cancelled' then 'cancelled' else a.status end using errcode = '22023'; end if;
  if a.created_at < now() - interval '30 minutes' then
    update assistant_actions set status = 'expired', decided_at = now() where id = a.id;
    return jsonb_build_object('ok', false, 'error', 'This card is more than 30 minutes old. Ask again so the details are fresh.');
  end if;
  -- the person's role may have changed since the card was made
  perform app.assistant_who(p_user, a.portal);
  perform set_config('app.via', 'via assistant', true);
  begin
    v_out := app.door(p_user, p_aal, a.call, a.name, a.args);
  exception when others then
    v_err := regexp_replace(sqlerrm, '^.*?ERROR:\s*', '');
  end;
  if v_err is not null then
    update assistant_actions set status = 'failed', error = left(v_err, 500), decided_at = now() where id = a.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_user, 'assistant_action_failed', 'assistant_actions', a.id::text, jsonb_build_object('tool', a.tool, 'door', a.call, 'name', a.name, 'summary', a.summary, 'error', left(v_err, 500), 'note', 'via assistant'));
    perform set_config('app.via', '', true);
    return jsonb_build_object('ok', false, 'error', v_err, 'id', a.id);
  end if;
  update assistant_actions set status = 'done', result = v_out, decided_at = now() where id = a.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_user, 'assistant_action', 'assistant_actions', a.id::text, jsonb_build_object('tool', a.tool, 'door', a.call, 'name', a.name, 'summary', a.summary, 'args', a.args - '_va', 'note', 'via assistant'));
  perform set_config('app.via', '', true);
  return jsonb_build_object('ok', true, 'id', a.id, 'result', v_out);
end $$;

create or replace function app.assistant_cancel(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  update assistant_actions set status = 'cancelled', decided_at = now() where id = nullif(p ->> 'id', '')::uuid and user_id = p_user and status = 'proposed';
  if not found then raise exception 'Action not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- A task by hand (the assistant's "create a task"): p {title, detail, queue, due_at, priority, booking, vehicle, _va}.
-- An Admin files it in any queue; an assistant in their own function's queue or the Admins'.
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description)
values ('staff_task', 'admin', 'A task from staff', 'normal', 'none', null, 'A task a staff member added by hand (the assistant, 0080). Done when they mark it done.')
on conflict (task_type) do nothing;

create or replace function app.task_create(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_admin boolean := app.user_is_admin(p_user);
  v_fn text;
  v_queue text := coalesce(nullif(p ->> 'queue', ''), 'admin');
  v_title text := nullif(btrim(coalesce(p ->> 'title', '')), '');
  v_priority text := coalesce(nullif(p ->> 'priority', ''), 'normal');
  v_due timestamptz := nullif(p ->> 'due_at', '')::timestamptz;
  v_booking uuid;
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_id uuid;
begin
  if not v_admin then
    if not app.user_is_staff(p_user) then raise exception 'Tasks are added by an Admin or an assistant' using errcode = '42501'; end if;
    v_fn := app.va_active_fn(p_user);
    if v_queue not in (v_fn, 'admin') then raise exception 'Add the task to your own queue (%) or the Admins''', v_fn using errcode = '42501'; end if;
  end if;
  if v_queue not in ('finance', 'fleet', 'cs', 'sales', 'admin') then raise exception 'Choose the queue: finance, fleet, cs, sales or admin' using errcode = '22023'; end if;
  if v_title is null or length(v_title) < 3 then raise exception 'Give the task a title' using errcode = '22023'; end if;
  if v_priority not in ('low', 'normal', 'high', 'urgent') then raise exception 'Choose the priority' using errcode = '22023'; end if;
  if v_due is not null and v_due < now() - interval '1 hour' then raise exception 'The due time is in the past' using errcode = '22023'; end if;
  if nullif(p ->> 'booking', '') is not null then
    select id into v_booking from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking';
    if v_booking is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  end if;
  v_id := app.raise_task(p_type => 'staff_task', p_title => left(v_title, 200), p_detail => nullif(left(btrim(coalesce(p ->> 'detail', '')), 2000), ''),
                         p_booking => v_booking, p_vehicle => v_vehicle, p_due_at => v_due, p_priority => v_priority, p_queue => v_queue, p_created_by => p_user);
  return jsonb_build_object('id', v_id, 'queue', v_queue);
end $$;

-- ================================================================ 11. the doors
create or replace function app.ops80(p_user uuid, p_aal text, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'usage_cards' then return app.usage_cards(p_user);
  when 'usage' then return app.usage_page(p_user);
  when 'usage_gate' then
    perform app.assistant_who(p_user, coalesce(p ->> 'portal', case when app.user_is_admin(p_user) then 'admin' when app.user_is_field(p_user) then 'field' else 'va' end));
    if coalesce(p ->> 'service', '') not in ('workers_ai', 'claude', 'images') then raise exception 'Unknown service' using errcode = '22023'; end if;
    -- with what the assistant needs to run: on or off, and the Claude model and prices of Program settings
    return app.usage_gate(p ->> 'service') || (select jsonb_build_object('assistant_enabled', s.assistant_enabled, 'claude_model', s.assistant_claude_model,
             'claude_in_usd_per_m', s.assistant_claude_input_usd_per_m, 'claude_out_usd_per_m', s.assistant_claude_output_usd_per_m) from (select (app.settings()).*) s);
  when 'usage_decide' then return app.usage_decide(p_user, p);
  when 'usage_service_save' then return app.usage_service_save(p_user, p);
  when 'usage_reading_save' then return app.usage_reading_save(p_user, p);
  when 'usage_alert_dismiss' then return app.usage_alert_dismiss(p_user, p);
  when 'assistant_find' then return app.assistant_find(p_user, p);
  when 'assistant_propose' then return app.assistant_propose(p_user, p);
  when 'assistant_confirm' then return app.assistant_confirm(p_user, p_aal, p);
  when 'assistant_cancel' then return app.assistant_cancel(p_user, p);
  when 'task_create' then return app.task_create(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0080;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'ops_read' and p_name in ('usage_cards', 'usage_gate', 'assistant_find'))
     or (p_call = 'admin_read' and p_name = 'usage')
     or (p_call = 'admin_do' and p_name in ('usage_decide', 'usage_service_save', 'usage_reading_save', 'usage_alert_dismiss'))
     or (p_call = 'ops_do' and p_name in ('assistant_propose', 'assistant_confirm', 'assistant_cancel', 'task_create')) then
    perform app.door_begin(p_user, p_aal);
    -- an assistant's chosen function (the switcher, 0033), as the door of 0031 reads it
    if coalesce(p ->> '_va', '') <> '' then perform set_config('app.va_active', p ->> '_va', true); end if;
    return app.ops80(p_user, p_aal, p_call, p_name, case when p_name = 'assistant_propose' then coalesce(p, '{}'::jsonb) else coalesce(p, '{}'::jsonb) - '_va' end);
  end if;
  return app.door_pre0080(p_user, p_aal, p_call, p_name, p);
end $$;

-- the jobs and the app's own calls (service role)
create or replace function public.server_usage_refresh() returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.job_usage_refresh() $$;
create or replace function public.server_usage_record(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.usage_record_external(p) $$;
create or replace function public.server_usage_gate(p_service text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.usage_gate(p_service) $$;
create or replace function public.server_usage_call(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.usage_call_record(p) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['usage_period_start', 'usage_resets_at', 'usage_used', 'usage_fmt', 'usage_usd', 'usage_decision', 'usage_paid_spent',
              'usage_state', 'usage_put', 'usage_emails_on', 'usage_measure', 'usage_record_external', 'usage_apply', 'usage_alert_title', 'usage_effect',
              'usage_refresh_service', 'usage_send_alerts', 'usage_retry_photos', 'job_usage_refresh', 'usage_gate', 'usage_call_record', 'notification_recipients_pre0080',
              'ntf_payload_pre0080', 'usage_cards', 'usage_page', 'usage_decide', 'usage_service_save', 'usage_reading_save', 'usage_alert_dismiss', 'assistant_who',
              'assistant_find', 'assistant_action_door', 'assistant_propose', 'assistant_confirm', 'assistant_cancel', 'task_create', 'ops80', 'door_pre0080', 'door']))
        or (n.nspname = 'public' and p.proname = any (array['server_usage_refresh', 'server_usage_record', 'server_usage_gate', 'server_usage_call']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- app.settings keeps the grants it had (0001): row-level security policies call it as the signed-in user
revoke all on function app.settings(date) from public, anon;
grant execute on function app.settings(date) to authenticated, service_role;
grant execute on function app.settings_base(date) to authenticated, service_role;

-- ================================================================ 12. the schedule
do $$
begin
  if to_regclass('cron.job') is not null then
    -- the usage guard, every hour (the Worker's job adds Cloudflare's figures when it has a token)
    perform cron.schedule('carmacars-usage', '11 * * * *', 'select app.job_usage_refresh()');
  end if;
end $$;

-- the first figures, so Settings > Usage is not empty after the deploy (no alert email: they wait for the job)
do $$ begin perform app.usage_measure(s.service) from usage_services s; end $$;

-- CATALOGUE 0080 START (generated by supabase/seed/0080_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('staff_usage_alert', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', '{{usage_title}}', '{{usage_used}} of {{usage_included}} used. {{usage_effect}}', 'Immediate', 'Usage guard (every hour, from the database): a metered service (Workers AI, Worker requests and CPU, image transformations, Resend emails, the Supabase database, file storage and egress, R2 storage, the Claude assistant) reached 80% of its included allowance for the period, or used all of it. Sent to the alert address in Program settings (uptime_alert_email), once per service, level and period, never from uptime_quiet_from_hour to uptime_quiet_until_hour (it waits for the morning). The same alert shows on Admin > To do.', null, '/admin/settings/usage', '[{"name":"company_address","type":"string","global":true},{"name":"service_label","type":"string"},{"name":"usage_advice","type":"string"},{"name":"usage_cost","type":"string"},{"name":"usage_effect","type":"string"},{"name":"usage_included","type":"string"},{"name":"usage_period","type":"string"},{"name":"usage_resets","type":"string"},{"name":"usage_share","type":"string"},{"name":"usage_title","type":"string"},{"name":"usage_used","type":"string"}]'::jsonb, 'templates/staff_usage_alert.html', 'templates/staff_usage_alert.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0080 END
