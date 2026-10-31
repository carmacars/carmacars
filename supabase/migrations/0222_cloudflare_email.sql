-- 0222: Cloudflare Email Service first for the outbox, Resend after (docs/changes/2026-11-03-cloudflare-email.md).
-- The owner, Release 23: Workers Paid includes 3,000 emails a month through Cloudflare Email Service (then US$0.35 per
-- 1,000); the outbox (send-outbox) sends through Cloudflare first and falls back to Resend when Cloudflare fails or its
-- month's included sends are used; the sign-in emails of Supabase Auth stay on Resend.
--
-- 1. app.cf_email_try() (the sender tries Cloudflare): Program settings cf_email_enabled (on), fewer Cloudflare sends this month than
--    cf_email_monthly_included (3,000), and no Cloudflare failure in the last 15 minutes (email_provider_state, written by
--    public.server_cf_email_result from the Edge Function). An email sent by Cloudflare keeps provider_id 'cf:<id>' and
--    its message row says provider 'cloudflare'. app.cf_email_available(): it may try and it sent in the last day.
-- 2. Resend's daily and monthly limits (0018: the holds until midnight, the priority classes) count Resend's sends only,
--    and hold nothing while Cloudflare is available (it sends, 1): "held until midnight" applies only when both are unavailable.
-- 3. Settings > Usage: "Emails this month (Cloudflare)", the month's Cloudflare sends against the 3,000 included; the
--    Resend figures count Resend's sends only.
-- No applied migration is edited.

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
    raise exception '0222: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

alter table program_settings
  add column if not exists cf_email_enabled boolean not null default true,
  add column if not exists cf_email_monthly_included integer not null default 3000 check (cf_email_monthly_included >= 0);
comment on column program_settings.cf_email_enabled is 'The outbox sends through Cloudflare Email Service first, then Resend (0222). Needs the Worker''s EMAIL binding.';
comment on column program_settings.cf_email_monthly_included is 'Cloudflare emails a month included in Workers Paid (0222); past it the outbox uses Resend.';

create table if not exists email_provider_state (
  id boolean primary key default true check (id),
  cf_failed_at timestamptz,
  cf_error text,
  cf_ok_at timestamptz,
  updated_at timestamptz not null default now()
);
insert into email_provider_state default values on conflict do nothing;
comment on table email_provider_state is 'The outbox''s email providers (0222): Cloudflare''s last refusal (it rests 15 minutes) and last send.';
alter table email_provider_state enable row level security;
revoke all on email_provider_state from anon, authenticated;
grant select on email_provider_state to authenticated;
grant all on email_provider_state to service_role;
drop policy if exists admin_all on email_provider_state;
create policy admin_all on email_provider_state for select to authenticated using (app.is_admin());
drop trigger if exists audit_email_provider_state on email_provider_state;
create trigger audit_email_provider_state after insert or update or delete on email_provider_state for each row execute function app.audit_row();

-- an outbox email sent by Cloudflare (provider_id 'cf:<id>')
create or replace function app.cf_emails_between(p_from timestamptz, p_to timestamptz) returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from notification_outbox o
   where o.status in ('sent', 'sending') and coalesce(o.provider_id, '') like 'cf:%' and o.sent_at >= p_from and o.sent_at < p_to
$$;

-- the sender tries Cloudflare: switched on, under the month's included emails, no refusal in the last 15 minutes
create or replace function app.cf_email_try(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(s.cf_email_enabled, false)
     and app.cf_emails_between(app.local_midnight(app.month_start(app.local_date(p_now))), p_now + interval '1 second') < s.cf_email_monthly_included
     and not coalesce((select e.cf_failed_at > p_now - interval '15 minutes' from email_provider_state e limit 1), false)
    from app.settings(app.local_date(p_now)) s
$$;
-- Resend's limits are lifted only while Cloudflare is known to send: it may try, and it sent in the last day (before its
-- first send, as when the Worker has no EMAIL binding yet, the limits of 0018 hold as before)
create or replace function app.cf_email_available(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.cf_email_try(p_now) and coalesce((select e.cf_ok_at > p_now - interval '1 day' from email_provider_state e limit 1), false)
$$;

create or replace function app.server_cf_email_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce((p ->> 'ok')::boolean, false) then
    update email_provider_state set cf_ok_at = now(), updated_at = now() where id;
  else
    update email_provider_state set cf_failed_at = now(), cf_error = left(p ->> 'error', 300), updated_at = now() where id;
  end if;
  return (select to_jsonb(e) - 'id' from email_provider_state e limit 1);
end $$;
create or replace function public.server_cf_email_result(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_cf_email_result(p) $$;

-- ================================================================ 2. Resend's limits count Resend only, and hold nothing while Cloudflare sends
select pg_temp.patch_fn('app.outbox_sent_today(timestamptz)'::regprocedure,
  $o$where (status = 'sent' and sent_at >= app.local_midnight(app.local_date(p_now))) or status = 'sending')$o$,
  $n$where ((status = 'sent' and sent_at >= app.local_midnight(app.local_date(p_now))) or status = 'sending') and coalesce(provider_id, '') not like 'cf:%')$n$);
select pg_temp.patch_fn('app.usage_emails_on(date, timestamptz)'::regprocedure,
  $o$where o.status = 'sent' and o.sent_at >= app.local_midnight(p_day) and o.sent_at < app.local_midnight(p_day + 1))$o$,
  $n$where o.status = 'sent' and o.sent_at >= app.local_midnight(p_day) and o.sent_at < app.local_midnight(p_day + 1) and coalesce(o.provider_id, '') not like 'cf:%')$n$);
select pg_temp.patch_fn('app.outbox_claim_0018(integer, timestamptz)'::regprocedure,
  $o$   where o.status = 'sent' and o.sent_at >= app.local_midnight(app.month_start(v_today));$o$,
  $n$   where o.status = 'sent' and o.sent_at >= app.local_midnight(app.month_start(v_today)) and coalesce(o.provider_id, '') not like 'cf:%';$n$);
select pg_temp.patch_fn('app.outbox_claim_0018(integer, timestamptz)'::regprocedure,
  $o$    elsif v_count >= v_limit or v_month >= s.notify_monthly_cap$o$,
  $n$    elsif (not app.cf_email_available(p_now) and (v_count >= v_limit or v_month >= s.notify_monthly_cap))$n$);
select pg_temp.patch_fn('app.outbox_mark_sent(uuid, text, text, timestamptz)'::regprocedure,
  $o$          'resend', p_provider_id, 'sent', p_now)$o$,
  $n$          case when coalesce(p_provider_id, '') like 'cf:%' then 'cloudflare' else 'resend' end, p_provider_id, 'sent', p_now)$n$);

-- ================================================================ 3. Settings > Usage
insert into usage_services (service, label, provider, unit, period, included, unlimited, warn_bps, pause_mode, usd_per_unit, price_text, upgrade_text,
                            measured_by, when_used_up, enabled, sort)
values ('cf_email', 'Emails this month (Cloudflare Email Service)', 'Cloudflare', 'emails', 'month', 3000, false, 8000, 'alert', 0.00035,
        'Included in Workers Paid: 3,000 a month, then US$0.35 per 1,000.', 'Past the included emails the outbox sends through Resend (its free plan).',
        'The outbox''s emails sent through Cloudflare (provider cf:), each Toronto day.',
        'The outbox goes on through Resend; held until midnight only when Resend''s limits are used too.', true, 61)
on conflict (service) do nothing;
update usage_services set label = 'Emails today (Resend)', measured_by = 'The outbox''s emails sent through Resend and Supabase Auth''s sign-in emails (the same Resend account).'
 where service = 'resend_day';

alter function app.usage_measure(text, timestamptz) rename to usage_measure_pre0222;
create function app.usage_measure(p_service text, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare d date;
begin
  if p_service = 'cf_email' then
    foreach d in array array[app.local_date(p_now) - 1, app.local_date(p_now)] loop
      perform app.usage_put(p_service, d, 'app', app.cf_emails_between(app.local_midnight(d), app.local_midnight(d + 1)));
    end loop;
    update usage_services set measured_at = p_now where service = p_service;
    return;
  end if;
  perform app.usage_measure_pre0222(p_service, p_now);
end $$;
select pg_temp.copy_grants('app.usage_measure(text, timestamptz)'::regprocedure, 'app.usage_measure_pre0222(text, timestamptz)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('cf_emails_between', 'cf_email_try', 'cf_email_available', 'server_cf_email_result', 'usage_measure_pre0222'))
               or (n.nspname = 'public' and p.proname = 'server_cf_email_result') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
