-- 1501_r35c_email_capacity.sql
-- Release 35, part C (item 8): "N of 100 emails used today". Why 100: the day's cap (app.email_day_cap, 0900) counts
-- Cloudflare Email Service's budget (notify_cf_daily_budget, 200) only once Cloudflare has sent (cf_email_counted: switched
-- on, a success recorded, the Worker's EMAIL binding not reported missing since). Until then the cap is Resend's own
-- budget (notify_resend_daily_budget, 100: Resend's free plan). The sending cap stays the truth (the claim must not pick
-- emails no provider can send), but every read now also carries:
--   capacity     the combined capacity: Cloudflare's budget plus Resend's, never above notify_daily_cap
--   limited_by   why the sending cap is what it is: 'combined' (both send), 'resend_only' (Cloudflare not counted) or
--                'setting' (notify_daily_cap is lower than the providers together)
--   cf_reason    in plain words, why Cloudflare is not counted (off, no binding, refused with its error, never sent)
-- so every page words the figure the same way (web: features/usage/model.ts emailCapLabel).
-- No applied migration is edited: app.email_pace and app.booking_conversation are wrapped.
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

comment on column program_settings.notify_daily_cap is 'Emails a day, every provider together: the upper limit (0583: 300). The day''s capacity is Cloudflare''s budget plus Resend''s, never above this; Cloudflare''s part counts once Cloudflare Email Service has sent (1501).';

-- why Cloudflare's budget is not in today's cap, in plain words (null when it is)
create function app.email_cf_reason(p_now timestamptz default now()) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when app.cf_email_counted(p_now) then null
    when not coalesce((app.settings_base(app.local_date(p_now))).cf_email_enabled, false) then 'Cloudflare Email Service is turned off in Program settings'
    when coalesce(e.cf_error, '') ilike '%binding%' then 'the site has no Cloudflare EMAIL binding yet (the deploy adds it when the repository variable CF_EMAIL_BINDING is 1)'
    when e.cf_failed_at is not null then 'Cloudflare refused the last email' || coalesce(': ' || nullif(left(e.cf_error, 120), ''), '')
    else 'Cloudflare Email Service has not sent an email yet' end
    from (select 1) one left join email_provider_state e on true
   limit 1
$$;

create function app.email_capacity(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('capacity', least(s.notify_daily_cap, s.notify_cf_daily_budget + s.notify_resend_daily_budget),
    'limited_by', case when app.cf_email_counted(p_now) then case when s.notify_daily_cap < s.notify_cf_daily_budget + s.notify_resend_daily_budget then 'setting' else 'combined' end
                       when s.notify_daily_cap < s.notify_resend_daily_budget then 'setting' else 'resend_only' end,
    'setting', s.notify_daily_cap, 'cf_reason', app.email_cf_reason(p_now))
    from app.settings_base(app.local_date(p_now)) s
$$;

alter function app.email_pace(timestamptz) rename to email_pace_pre1501;
create function app.email_pace(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.email_pace_pre1501(p_now) || app.email_capacity(p_now)
$$;
select pg_temp.copy_grants('app.email_pace(timestamptz)'::regprocedure, 'app.email_pace_pre1501(timestamptz)'::regprocedure);

alter function app.booking_conversation(uuid, jsonb) rename to booking_conversation_pre1501;
create function app.booking_conversation(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.booking_conversation_pre1501(p_by, p);
begin
  if x is null or not (x ? 'usage') then return x; end if;
  return jsonb_set(x, '{usage}', (x -> 'usage') || app.email_capacity(now()));
end $$;
select pg_temp.copy_grants('app.booking_conversation(uuid, jsonb)'::regprocedure, 'app.booking_conversation_pre1501(uuid, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('email_cf_reason', 'email_capacity') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
