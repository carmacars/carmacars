-- 2520_r41_marketing_everyone.sql
-- Release 41 (docs/changes/2026-11-12-r41-marketing-emails.md). The owner's instructions (November 12, 2026, approved by
-- his lawyer):
--   "If they unsubscribe then do not email them. However, if they have put their email anywhere on our website, then that
--    is grounds for us to be able to email them."
--   "Email addresses typed into forms that were not submitted do count."
--   "Make sure that you're increasing the quantity of emails that you're sending for marketing automatically for everybody."
--   "Every single person should also be emailed every single time we add a new vehicle to the fleet."
--
--   1. The marketing audience (marketing_contacts): every distinct address a person gave us on the site, from the
--      customer sources only: renters, customer accounts (no staff, owner or investor role, unless also a renter), renter
--      leads (app.sl_type 'renter', not spam, not a Turo guest, not added by staff, not do-not-contact) and forms left
--      unfinished (booking request, contact, chat, game, sign-up; never the owner application). The consent basis is
--      recorded per address: 'provided_on_site', with the sources. Rebuilt hourly by the job, so an address whose
--      every source was deleted (the 24-month capture purge, an account deleted) leaves the audience.
--   2. Consent (marketing_everyone_enabled, on): every marketing email may go to anyone who has not unsubscribed, without
--      the "send me deals" tick (app.has_marketing_consent). Unsubscribing is honoured at once, as before: the one-click
--      link (and the List-Unsubscribe header the sender sets) suppresses the address for every marketing email, and now
--      also marks the account with that address as unsubscribed. Bounces, complaints and manual suppressions stay out.
--   3. Two campaigns, each with its switch (on by default):
--        marketing_weekly       every week (marketing_weekly_dow, marketing_weekly_hour, Toronto time): the cars listed now
--                               with their prices, and the public promo codes running now
--        marketing_new_vehicle  once per car, when its listing goes live (published, bookable, never a sample car);
--                               cars listed before this migration are not announced
--      One row per person and campaign (marketing_campaign_sends): nobody gets the same campaign twice.
--   4. More marketing email automatically (marketing_auto_volume, on): the day's marketing allowance is the free email
--      capacity of the day (Cloudflare's daily budget, then Resend's free plan: app.email_day_cap) less a reserve for
--      booking, payment and sign-in email (marketing_transactional_reserve, or twice the recent daily average when that
--      is more), never below notify_marketing_daily_max. Campaign emails are queued at the marketing priority (class 5:
--      every other email goes first), in the marketing hours, paced across the window, at most one campaign email per
--      person a day; what does not fit waits for the next day. Never a paid send: the claim's budgets are unchanged.
-- No applied migration is edited: functions are wrapped (renamed _pre2520) or patched in place.
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

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists marketing_everyone_enabled boolean not null default true,
  add column if not exists marketing_weekly_enabled boolean not null default true,
  add column if not exists marketing_weekly_dow smallint not null default 4 check (marketing_weekly_dow between 1 and 7),
  add column if not exists marketing_weekly_hour smallint not null default 10 check (marketing_weekly_hour between 0 and 23),
  add column if not exists marketing_weekly_cars smallint not null default 6 check (marketing_weekly_cars between 1 and 12),
  add column if not exists marketing_new_vehicle_enabled boolean not null default true,
  add column if not exists marketing_auto_volume boolean not null default true,
  add column if not exists marketing_transactional_reserve integer not null default 60 check (marketing_transactional_reserve >= 0);
comment on column program_settings.marketing_everyone_enabled is 'Marketing emails go to everyone who gave us their email on the site (renters, accounts, leads, forms left unfinished) unless they unsubscribed (2520). Off: only those who ticked the marketing box.';
comment on column program_settings.marketing_weekly_enabled is 'The weekly email to the whole marketing audience: the cars listed now and the deals running now (2520).';
comment on column program_settings.marketing_weekly_dow is 'The weekly email: day of the week (1 Monday ... 7 Sunday), Toronto time.';
comment on column program_settings.marketing_weekly_hour is 'The weekly email: from this hour (Toronto time); it goes within the marketing hours.';
comment on column program_settings.marketing_weekly_cars is 'The weekly email: how many cars it shows (the newest listings first).';
comment on column program_settings.marketing_new_vehicle_enabled is 'Email the whole marketing audience once each time a new car is listed on the site (2520). Sample cars are never announced.';
comment on column program_settings.marketing_auto_volume is 'Raise the day''s marketing emails to the free email capacity left after the reserve for booking, payment and sign-in emails (2520). Off: notify_marketing_daily_max only.';
comment on column program_settings.marketing_transactional_reserve is 'Emails a day kept for booking, payment and sign-in emails before marketing may use the rest of the free capacity (at least; twice the recent daily average when that is more).';

-- cars listed before this migration are not announced as new
create function app.marketing_new_vehicle_since() returns timestamptz language sql immutable as $$ select null::timestamptz $$;
do $$
begin
  execute format('create or replace function app.marketing_new_vehicle_since() returns timestamptz language sql immutable as $f$ select %L::timestamptz $f$', now());
end $$;

-- ================================================================ 2. tables
create table marketing_contacts (
  email          text primary key check (email = lower(btrim(email)) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  first_name     text,
  user_id        uuid references users (id) on delete set null,
  renter_id      uuid references renters (id) on delete set null,
  sources        text[] not null check (cardinality(sources) > 0),
  first_source   text not null check (first_source in ('renter', 'account', 'lead', 'unfinished_form')),
  consent_basis  text not null default 'provided_on_site' check (consent_basis = 'provided_on_site'),
  rank           smallint not null default 3 check (rank between 1 and 3),
  first_seen_at  timestamptz not null,
  last_seen_at   timestamptz not null,
  refreshed_at   timestamptz not null default now()
);
create index marketing_contacts_user_idx on marketing_contacts (user_id) where user_id is not null;
create index marketing_contacts_renter_idx on marketing_contacts (renter_id) where renter_id is not null;
comment on table marketing_contacts is 'The marketing audience (2520): every address a person gave us on the site, with where it came from and the consent basis (provided on site). Rebuilt hourly from the sources; unsubscribed and bounced addresses stay here and are left out when sending.';

create table marketing_campaigns (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('weekly', 'new_vehicle')),
  code         text not null references notification_catalogue (code),
  vehicle_id   uuid references vehicles (id) on delete cascade,
  week_of      date,
  payload      jsonb not null default '{}'::jsonb,
  audience     integer not null default 0,
  status       text not null default 'sending' check (status in ('sending', 'done', 'stopped')),
  stop_reason  text,
  created_at   timestamptz not null default now(),
  finished_at  timestamptz,
  check ((kind = 'new_vehicle') = (vehicle_id is not null)),
  check ((kind = 'weekly') = (week_of is not null))
);
create unique index marketing_campaigns_vehicle_key on marketing_campaigns (vehicle_id) where kind = 'new_vehicle';
create unique index marketing_campaigns_week_key on marketing_campaigns (week_of) where kind = 'weekly';
create index marketing_campaigns_code_idx on marketing_campaigns (code);
create index marketing_campaigns_vehicle_idx on marketing_campaigns (vehicle_id) where vehicle_id is not null;
comment on table marketing_campaigns is 'Marketing campaigns (2520): the weekly email and one email per new car, each to the whole marketing audience, sent over the days within the free email budgets.';

create table marketing_campaign_sends (
  campaign_id  uuid not null references marketing_campaigns (id) on delete cascade,
  email        text not null,
  status       text not null default 'waiting' check (status in ('waiting', 'queued', 'skipped')),
  reason       text,
  event_id     bigint references app_events (id) on delete set null,
  created_at   timestamptz not null default now(),
  queued_at    timestamptz,
  primary key (campaign_id, email)
);
create index marketing_campaign_sends_waiting_idx on marketing_campaign_sends (campaign_id, created_at) where status = 'waiting';
create index marketing_campaign_sends_email_idx on marketing_campaign_sends (email, queued_at desc);
create index marketing_campaign_sends_event_idx on marketing_campaign_sends (event_id) where event_id is not null;
comment on table marketing_campaign_sends is 'One row per person and campaign (2520): waiting, queued (its event and outbox email) or skipped with the reason. Nobody gets the same campaign twice.';

-- the person-spacing check reads the marketing emails of one address
create index if not exists notification_outbox_marketing_to_idx on notification_outbox (to_address, created_at desc) where category = 'marketing';

do $$
declare t text;
begin
  foreach t in array array['marketing_contacts', 'marketing_campaigns', 'marketing_campaign_sends'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;
create trigger audit_marketing_campaigns after insert or update or delete on marketing_campaigns for each row execute function app.audit_row();

-- ================================================================ 3. consent: everyone who gave us their email, unless they unsubscribed
alter function app.has_marketing_consent(uuid, text) rename to has_marketing_consent_pre2520;
create function app.has_marketing_consent(p_user uuid, p_rule text default 'express') returns boolean
language sql stable security definer set search_path = public, app as $$
  select case when coalesce((app.settings()).marketing_everyone_enabled, false)
              -- the address itself is checked against the suppressions (unsubscribed, bounced, complained) by the caller
              then p_user is null or app.has_marketing_consent_pre2520(p_user, 'implied')
              else app.has_marketing_consent_pre2520(p_user, p_rule) end
$$;
select pg_temp.copy_grants('app.has_marketing_consent(uuid, text)'::regprocedure, 'app.has_marketing_consent_pre2520(uuid, text)'::regprocedure);
-- Texts are not part of it: the owner's rule is for email. A marketing email becomes a text only on the consent it
-- needed before 2520 (the "send me deals" tick, or the catalogue's implied rule), never on an address given on the site.
do $$
declare
  d text := pg_get_functiondef('app.notify_route()'::regprocedure);
  o text := $o$if new.category = 'marketing' and not app.has_marketing_consent(v_user, coalesce(c.consent_rule, 'express')) then return new; end if;$o$;
begin
  if position(o in d) = 0 then raise exception '2520: the marketing check of app.notify_route was not found'; end if;
  execute replace(d, o, $n$if new.category = 'marketing' and not app.has_marketing_consent_pre2520(v_user, coalesce(c.consent_rule, 'express')) then return new; end if;$n$);
end $$;

-- May this address get a marketing email now? Not suppressed (unsubscribed, bounced, complained, manual), the account with
-- the address not unsubscribed, not a test address; with the everyone switch off, only with the account's express consent.
create function app.marketing_can_email(p_email text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select nullif(btrim(coalesce(p_email, '')), '') is not null
     and not app.email_suppressed(p_email, true)
     and not app.email_is_test(p_email)
     and coalesce((select bool_and(app.has_marketing_consent(u.id, 'express')) from users u where lower(u.email) = lower(btrim(p_email))),
                  coalesce((app.settings()).marketing_everyone_enabled, false))
$$;

-- the one-click unsubscribe also marks the account with that address (campaign emails carry no account id)
alter function app.unsubscribe(uuid, timestamptz) rename to unsubscribe_pre2520;
create function app.unsubscribe(p_token uuid, p_now timestamptz default now()) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  v boolean := app.unsubscribe_pre2520(p_token, p_now);
  v_to text;
begin
  if not v then return v; end if;
  select o.to_address into v_to from notification_outbox o where o.unsubscribe_token = p_token;
  update users set marketing_opt_in = false, marketing_unsubscribed_at = p_now
   where lower(email) = v_to and (marketing_unsubscribed_at is null or marketing_opt_in);
  update consents c set withdrawn_at = p_now
    from users u where u.id = c.user_id and lower(u.email) = v_to and c.consent_code = 'marketing' and c.withdrawn_at is null;
  update marketing_campaign_sends set status = 'skipped', reason = 'unsubscribed' where email = v_to and status = 'waiting';
  return v;
end $$;
select pg_temp.copy_grants('app.unsubscribe(uuid, timestamptz)'::regprocedure, 'app.unsubscribe_pre2520(uuid, timestamptz)'::regprocedure);

-- ================================================================ 4. the audience
create function app.marketing_audience_refresh(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  with src as (
    -- renters (customers), unless their account was closed
    select lower(btrim(coalesce(nullif(r.email, ''), u.email))) as email, split_part(btrim(r.legal_name), ' ', 1) as first_name,
           r.user_id, r.id as renter_id, 'renter'::text as source, 1 as rank, r.created_at as at
      from renters r left join users u on u.id = r.user_id
     where coalesce(u.status, 'active') <> 'closed'
    union all
    -- customer accounts: no staff, owner or investor role (one who is also a renter comes in above)
    select lower(btrim(u.email)), split_part(btrim(u.full_name), ' ', 1), u.id, null::uuid, 'account', 1, u.created_at
      from users u
     where u.status in ('active', 'invited')
       and not exists (select 1 from user_roles ur where ur.user_id = u.id and ur.role::text in ('admin', 'va', 'field', 'owner'))
       and not exists (select 1 from investors i where i.user_id = u.id)
    union all
    -- renter leads from the site (the Sales list's own segment), never spam, Turo guests, leads staff typed in or do-not-contact
    select lower(btrim(l.email)), split_part(btrim(coalesce(l.name, '')), ' ', 1), null::uuid, null::uuid, 'lead', 2, l.created_at
      from leads l
     where app.sl_type(l) = 'renter' and l.status <> 'spam' and l.kind <> 'turo_guest' and l.do_not_contact_at is null
       and coalesce(l.source, 'web') not in ('manual', 'turo', 'phone', 'import')
    union all
    -- forms left unfinished: an address typed in counts even when the form was never sent (never the owner forms)
    select lower(btrim(c.email)), split_part(btrim(coalesce(c.name, '')), ' ', 1), null::uuid, null::uuid, 'unfinished_form', 3, c.first_at
      from contact_captures c
     where c.form in ('booking_request', 'contact', 'chat', 'game', 'signup')
  ), ok as (
    select * from src where email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and not app.email_is_test(email)
  ), agg as (
    select email,
           (array_agg(nullif(first_name, '') order by rank, at) filter (where nullif(first_name, '') is not null))[1] as first_name,
           (array_agg(user_id order by at) filter (where user_id is not null))[1] as user_id,
           (array_agg(renter_id order by at) filter (where renter_id is not null))[1] as renter_id,
           array_agg(distinct source order by source) as sources,
           (array_agg(source order by at, rank))[1] as first_source,
           min(rank)::smallint as rank, min(at) as first_seen_at, max(at) as last_seen_at
      from ok group by email
  ), up as (
    insert into marketing_contacts as m (email, first_name, user_id, renter_id, sources, first_source, rank, first_seen_at, last_seen_at, refreshed_at)
    select email, left(first_name, 60), user_id, renter_id, sources, first_source, rank, first_seen_at, last_seen_at, p_now from agg
    on conflict (email) do update set first_name = excluded.first_name, user_id = excluded.user_id, renter_id = excluded.renter_id,
           sources = excluded.sources, first_source = excluded.first_source, rank = excluded.rank, first_seen_at = excluded.first_seen_at,
           last_seen_at = excluded.last_seen_at, refreshed_at = excluded.refreshed_at
    returning 1)
  select count(*) into n from up;
  -- an address whose every source is gone (deleted, purged after 24 months) leaves the audience
  delete from marketing_contacts where refreshed_at < p_now;
  update marketing_campaign_sends s set status = 'skipped', reason = 'no longer in the audience'
   where s.status = 'waiting' and not exists (select 1 from marketing_contacts m where m.email = s.email);
  return n;
end $$;

-- ================================================================ 5. the day's marketing allowance
-- The free capacity of the day (Cloudflare's budget, then Resend's free plan) less the reserve for every other email; never
-- below notify_marketing_daily_max. The claim holds marketing at this number, and the campaign job queues within it.
create function app.marketing_daily_max(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select case when not s.marketing_auto_volume then s.notify_marketing_daily_max
              else greatest(s.notify_marketing_daily_max,
                            app.email_day_cap(p_now) - greatest(s.marketing_transactional_reserve,
                              2 * ceil((select count(*) from notification_outbox o
                                         where o.status = 'sent' and o.category <> 'marketing'
                                           and o.sent_at >= p_now - interval '14 days' and o.sent_at < p_now) / 14.0)::integer)) end
    from app.settings(app.local_date(p_now)) s
$$;

-- every version of the claim that holds marketing at notify_marketing_daily_max now holds it at the day's allowance
do $$
declare
  f record;
  d text;
  n integer := 0;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname = 'app' and p.proname like 'outbox_claim%' and p.prosrc like '%s.notify_marketing_daily_max%'
  loop
    d := pg_get_functiondef(f.sig);
    execute replace(d, 's.notify_marketing_daily_max', 'app.marketing_daily_max(p_now)');
    n := n + 1;
  end loop;
  if n = 0 then raise exception '2520: no version of the outbox claim reads notify_marketing_daily_max'; end if;
end $$;

-- ================================================================ 6. campaign content from the live listings
create function app.marketing_price(p_cents bigint) returns text
language sql immutable as $$
  select case when p_cents is null then null when p_cents % 100 = 0 then '$' || to_char(p_cents / 100, 'FM999,990')
              else app.fmt_money(p_cents) end
$$;

-- the cars on the site now (published, bookable, never a sample car), with when each was first listed
create function app.marketing_listed_cars() returns table (vehicle_id uuid, slug text, name text, daily_rate_cents bigint, seats smallint,
                                                           transmission text, published_at timestamptz)
language sql stable security definer set search_path = public, app as $$
  select p.vehicle_id, p.slug, app.vehicle_name(p.vehicle_id), p.daily_rate_cents::bigint, p.seats, p.transmission,
         coalesce(l.first_published_at, l.published_at, l.created_at)
    from public_vehicle_listings p
    join vehicles v on v.id = p.vehicle_id
    join vehicle_listings l on l.vehicle_id = p.vehicle_id
   where not v.is_sample and p.slug is not null
$$;

create function app.marketing_weekly_payload(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_n integer;
  v_min bigint;
  v_cars jsonb;
  v_deals jsonb;
begin
  select count(*), min(c.daily_rate_cents) into v_n, v_min from app.marketing_listed_cars() c;
  if v_n = 0 then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', c.name,
           'meta', concat_ws(' ', 'From ' || app.marketing_price(c.daily_rate_cents) || ' a day.',
                             case when c.seats is not null or nullif(c.transmission, '') is not null
                                  then concat_ws(', ', c.seats || ' seats', lower(nullif(c.transmission, ''))) || '.' end),
           'url', s.notify_base_url || '/cars/' || c.slug) order by c.published_at desc nulls last, c.name), '[]'::jsonb)
    into v_cars
    from (select * from app.marketing_listed_cars() order by published_at desc nulls last, name limit s.marketing_weekly_cars) c;
  -- the public codes running now: made by staff, for anyone, active, started, not ended, no use limit
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', 'Code ' || p.code,
           'detail', concat_ws(' ', coalesce(nullif(btrim(p.description), ''),
                                             case when p.percent_bps is not null then app.fmt_pct(p.percent_bps) || ' off the rental charge'
                                                  else app.marketing_price(p.amount_cents) || ' off the rental charge' end) || '.',
                               case when p.valid_until is not null then 'Until ' || app.fmt_date(p.valid_until) || '.' end),
           'url', s.notify_base_url || '/cars') order by p.valid_until nulls last, p.code), '[]'::jsonb)
    into v_deals
    from (select * from promo_codes p where p.is_active and p.renter_id is null and p.source = 'manual' and p.max_uses is null
             and p.valid_from <= p_now and (p.valid_until is null or p.valid_until > p_now)
           order by p.valid_until nulls last limit 3) p;
  return jsonb_build_object(
    'headline', v_n || case when v_n = 1 then ' car' else ' cars' end || ' ready to rent this week',
    'preheader_text', 'From ' || app.marketing_price(v_min) || ' a day. Request in two minutes, pay only when you approve.',
    'cars', v_cars, 'has_deals', jsonb_array_length(v_deals) > 0, 'deals', v_deals);
end $$;

create function app.marketing_new_vehicle_payload(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('vehicle_id', c.vehicle_id::text,
           'daily_price', app.marketing_price(c.daily_rate_cents),
           'seats', coalesce(c.seats::text, 'See the car page'),
           'transmission', coalesce(initcap(nullif(c.transmission, '')), 'See the car page'),
           'car_url', (app.settings()).notify_base_url || '/cars/' || c.slug)
    from app.marketing_listed_cars() c where c.vehicle_id = p_vehicle
$$;

-- a new campaign: the row, and one waiting row per address that may get it now
create function app.marketing_campaign_start(p_kind text, p_vehicle uuid, p_week date, p_payload jsonb, p_now timestamptz default now()) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  n integer;
begin
  insert into marketing_campaigns (kind, code, vehicle_id, week_of, payload, created_at)
  values (p_kind, case p_kind when 'weekly' then 'marketing_weekly' else 'marketing_new_vehicle' end, p_vehicle, p_week, p_payload, p_now)
  on conflict do nothing returning id into v_id;
  if v_id is null then return null; end if;
  insert into marketing_campaign_sends (campaign_id, email, created_at)
  select v_id, m.email, p_now from marketing_contacts m where app.marketing_can_email(m.email);
  get diagnostics n = row_count;
  update marketing_campaigns set audience = n, status = case when n = 0 then 'done' else 'sending' end,
         finished_at = case when n = 0 then p_now end where id = v_id;
  return v_id;
end $$;

-- ================================================================ 7. who receives a campaign email: the address it was queued for
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre2520;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code in ('marketing_weekly', 'marketing_new_vehicle') then
    -- no account id: a campaign email is an email only (no portal notice), and the unsubscribe marks the account by its address
    return query select 'renter'::text, null::uuid, p_event.payload ->> '_to_email', p_event.payload ->> '_to_name',
                        null::uuid, null::uuid, true
                  where nullif(p_event.payload ->> '_to_email', '') is not null;
    return;
  end if;
  return query select * from app.notification_recipients_pre2520(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure,
                           'app.notification_recipients_pre2520(app_events, notification_catalogue)'::regprocedure);

-- ================================================================ 8. the job (every 15 minutes)
create function app.job_marketing(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_local timestamp := p_now at time zone 'America/Toronto';
  v_today date := app.local_date(p_now);
  v_week date := (date_trunc('week', p_now at time zone 'America/Toronto'))::date;
  v_from timestamptz;
  v_until timestamptz;
  v_frac numeric;
  v_max integer;
  v_used integer;
  v_room integer;
  v_new integer := 0;
  v_queued integer := 0;
  v_skipped integer := 0;
  v_payload jsonb;
  c record;
  x record;
begin
  -- the audience, hourly
  if not exists (select 1 from marketing_contacts where refreshed_at > p_now - interval '55 minutes') then
    perform app.marketing_audience_refresh(p_now);
  end if;

  -- a new car on the site: once per car
  if s.marketing_new_vehicle_enabled then
    for c in select l.vehicle_id from app.marketing_listed_cars() l
              where l.published_at >= app.marketing_new_vehicle_since()
                and not exists (select 1 from marketing_campaigns m where m.kind = 'new_vehicle' and m.vehicle_id = l.vehicle_id)
              order by l.published_at loop
      if app.marketing_campaign_start('new_vehicle', c.vehicle_id, null, app.marketing_new_vehicle_payload(c.vehicle_id), p_now) is not null then
        v_new := v_new + 1;
      end if;
    end loop;
  end if;

  -- the weekly email: from its day and hour, once a week; the last week's people still waiting get this one instead
  if s.marketing_weekly_enabled and extract(isodow from v_local) = s.marketing_weekly_dow and extract(hour from v_local) >= s.marketing_weekly_hour
     and not exists (select 1 from marketing_campaigns m where m.kind = 'weekly' and m.week_of = v_week) then
    v_payload := app.marketing_weekly_payload(p_now);
    if v_payload is not null then
      update marketing_campaign_sends w set status = 'skipped', reason = 'a newer weekly email replaced it'
        from marketing_campaigns m where m.id = w.campaign_id and m.kind = 'weekly' and m.status = 'sending' and w.status = 'waiting';
      update marketing_campaigns set status = 'done', finished_at = p_now where kind = 'weekly' and status = 'sending';
      if app.marketing_campaign_start('weekly', null, v_week, v_payload, p_now) is not null then v_new := v_new + 1; end if;
    end if;
  end if;

  -- queue within the day's allowance, paced across the marketing hours (the claim keeps every other email first)
  v_from := (v_today + s.notify_marketing_from) at time zone 'America/Toronto';
  v_until := (v_today + s.notify_marketing_until) at time zone 'America/Toronto';
  if p_now >= v_from and p_now < v_until then
    v_frac := least(1, (extract(epoch from p_now - v_from) + 900) / greatest(900, extract(epoch from v_until - v_from)));
    v_max := app.marketing_daily_max(p_now);
    -- today's marketing so far: the outbox's (other codes) and the campaign emails queued today (their outbox rows may not exist yet)
    select (select count(*) from notification_outbox o
             where o.category = 'marketing' and o.code not in ('marketing_weekly', 'marketing_new_vehicle')
               and o.created_at >= app.local_midnight(v_today) and o.status not in ('skipped', 'suppressed'))
         + (select count(*) from marketing_campaign_sends w where w.status = 'queued' and w.queued_at >= app.local_midnight(v_today))
      into v_used;
    v_room := greatest(0, ceil(v_max * v_frac)::integer - v_used);
    for x in select w.campaign_id, w.email, m.kind, m.code, m.vehicle_id, m.payload, mc.first_name
               from marketing_campaign_sends w
               join marketing_campaigns m on m.id = w.campaign_id and m.status = 'sending'
               left join marketing_contacts mc on mc.email = w.email
              where w.status = 'waiting'
              order by case m.kind when 'new_vehicle' then 0 else 1 end, m.created_at, coalesce(mc.rank, 3), w.email
              for update of w skip locked loop
      exit when v_room <= 0;
      if not app.marketing_can_email(x.email) then
        update marketing_campaign_sends set status = 'skipped', reason = 'unsubscribed or not to be emailed' where campaign_id = x.campaign_id and email = x.email;
        v_skipped := v_skipped + 1;
        continue;
      end if;
      if x.kind = 'new_vehicle' and not exists (select 1 from app.marketing_listed_cars() l where l.vehicle_id = x.vehicle_id) then
        update marketing_campaign_sends set status = 'skipped', reason = 'the car is no longer listed' where campaign_id = x.campaign_id and email = x.email;
        v_skipped := v_skipped + 1;
        continue;
      end if;
      -- at most one campaign email a person a day: the rest wait for the next day
      if exists (select 1 from marketing_campaign_sends y where y.email = x.email and y.status = 'queued' and y.queued_at > p_now - interval '20 hours') then
        continue;
      end if;
      update marketing_campaign_sends
         set status = 'queued', queued_at = p_now,
             event_id = app.emit_event(x.code, 'marketing_campaign', x.campaign_id,
                          x.payload || jsonb_build_object('_to_email', x.email, '_to_name', coalesce(nullif(x.first_name, ''), 'there')),
                          'marketing:' || x.campaign_id || ':' || x.email)
       where campaign_id = x.campaign_id and email = x.email;
      v_queued := v_queued + 1;
      v_room := v_room - 1;
    end loop;
  end if;

  update marketing_campaigns m set status = 'done', finished_at = p_now
   where m.status = 'sending' and not exists (select 1 from marketing_campaign_sends w where w.campaign_id = m.id and w.status = 'waiting');
  return format('campaigns started %s, queued %s, skipped %s', v_new, v_queued, v_skipped);
end $$;

-- ================================================================ 9. Admin > Marketing > Email campaigns (Sales: read only)
create function public.server_marketing_emails(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_admin boolean := coalesce(app.user_is_admin(p_user), false);
  v_mid timestamptz := app.local_midnight(app.local_date(now()));
begin
  if not (v_admin or coalesce(app.sl_may(p_user), false)) then raise exception 'Admin or Sales only' using errcode = '42501'; end if;
  return jsonb_build_object(
    'can_edit', v_admin,
    'settings', jsonb_build_object('marketing_everyone_enabled', s.marketing_everyone_enabled, 'marketing_weekly_enabled', s.marketing_weekly_enabled,
                  'marketing_weekly_dow', s.marketing_weekly_dow, 'marketing_weekly_hour', s.marketing_weekly_hour, 'marketing_weekly_cars', s.marketing_weekly_cars,
                  'marketing_new_vehicle_enabled', s.marketing_new_vehicle_enabled, 'marketing_auto_volume', s.marketing_auto_volume,
                  'marketing_transactional_reserve', s.marketing_transactional_reserve, 'notify_marketing_daily_max', s.notify_marketing_daily_max),
    'daily_max', app.marketing_daily_max(now()),
    'day_cap', app.email_day_cap(now()),
    'hours', to_char(s.notify_marketing_from, 'FMHH24:MI') || ' to ' || to_char(s.notify_marketing_until, 'FMHH24:MI'),
    'audience', (select count(*) from marketing_contacts m where app.marketing_can_email(m.email)),
    'contacts', (select count(*) from marketing_contacts),
    'by_source', (select coalesce(jsonb_object_agg(src, n), '{}'::jsonb) from (select x.src, count(*) n from marketing_contacts m cross join lateral unnest(m.sources) as x(src) group by x.src) z),
    'unsubscribed', (select count(*) from email_suppressions e where e.scope = 'marketing' and e.reason = 'unsubscribe' and e.lifted_at is null),
    'unsubscribed_30d', (select count(*) from email_suppressions e where e.scope = 'marketing' and e.reason = 'unsubscribe' and e.lifted_at is null and e.created_at > now() - interval '30 days'),
    'bounced', (select count(*) from email_suppressions e where e.scope = 'all' and e.reason in ('bounce', 'complaint') and e.lifted_at is null),
    'waiting', (select count(*) from marketing_campaign_sends w join marketing_campaigns m on m.id = w.campaign_id and m.status = 'sending' where w.status = 'waiting'),
    'queued', (select count(*) from notification_outbox o where o.category = 'marketing' and o.status in ('queued', 'delayed', 'sending', 'merged')),
    'sent_today', (select count(*) from notification_outbox o where o.category = 'marketing' and o.status = 'sent' and o.sent_at >= v_mid),
    'sent_7d', (select count(*) from notification_outbox o where o.category = 'marketing' and o.status = 'sent' and o.sent_at > now() - interval '7 days'),
    'sent_30d', (select count(*) from notification_outbox o where o.category = 'marketing' and o.status = 'sent' and o.sent_at > now() - interval '30 days'),
    'by_code', (select coalesce(jsonb_agg(jsonb_build_object('code', z.code, 'subject', c.subject, 'sent_30d', z.n) order by z.n desc), '[]'::jsonb)
                  from (select o.code, count(*) n from notification_outbox o where o.category = 'marketing' and o.status = 'sent' and o.sent_at > now() - interval '30 days' group by o.code) z
                  join notification_catalogue c on c.code = z.code),
    'campaigns', (select coalesce(jsonb_agg(x order by x ->> 'created_at' desc), '[]'::jsonb) from (
        select jsonb_build_object('id', m.id, 'kind', m.kind, 'created_at', m.created_at, 'status', m.status, 'audience', m.audience,
                 'title', case m.kind when 'weekly' then 'Week of ' || app.fmt_day(m.week_of) else 'New car: ' || coalesce(app.vehicle_name(m.vehicle_id), 'a car') end,
                 'waiting', (select count(*) from marketing_campaign_sends w where w.campaign_id = m.id and w.status = 'waiting'),
                 'skipped', (select count(*) from marketing_campaign_sends w where w.campaign_id = m.id and w.status = 'skipped'),
                 'sent', (select count(*) from marketing_campaign_sends w join notification_outbox o on o.event_id = w.event_id
                           where w.campaign_id = m.id and o.status = 'sent'),
                 'queued', (select count(*) from marketing_campaign_sends w left join notification_outbox o on o.event_id = w.event_id
                           where w.campaign_id = m.id and w.status = 'queued' and coalesce(o.status, 'queued') in ('queued', 'delayed', 'sending', 'merged'))) x
          from marketing_campaigns m order by m.created_at desc limit 12) q));
end $$;

-- ================================================================ 9b. Account > Notifications: the offers box shows what really happens
-- With the everyone switch on, a person gets the offers until they unsubscribe: the box is ticked unless the account
-- unsubscribed (0028's function word for word, plus marketing_on). Unticking it unsubscribes, as before.
create or replace function public.my_profile() returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select jsonb_build_object(
    'user', (select jsonb_build_object('id', u.id, 'email', u.email, 'phone', u.phone, 'full_name', u.full_name,
                                       'marketing_opt_in', u.marketing_opt_in, 'marketing_opt_in_at', u.marketing_opt_in_at,
                                       'marketing_on', u.marketing_unsubscribed_at is null or u.marketing_opt_in)
               from users u where u.id = app.uid()),
    'renter', (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'mobile', r.mobile, 'email', r.email,
                                         'address_line1', r.address_line1, 'address_line2', r.address_line2, 'city', r.city,
                                         'province', r.province, 'postal_code', r.postal_code, 'country', r.country,
                                         'identity_status', r.identity_status)
                 from renters r where r.id = app.my_renter_id()),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'full_name', d.full_name, 'is_account_holder', d.is_account_holder,
                                                             'licence_class', d.licence_class, 'licence_issuer', d.licence_issuer,
                                                             'licence_expiry', d.licence_expiry, 'identity_status', d.identity_status)
                                           order by d.is_account_holder desc, d.full_name)
                           from drivers d where d.renter_id = app.my_renter_id()), '[]'::jsonb),
    'cards', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'brand', p.card_brand, 'last4', p.card_last4, 'exp_month', p.exp_month,
                                                           'exp_year', p.exp_year, 'cardholder_name', p.cardholder_name) order by p.created_at desc)
                         from payment_methods p where p.renter_id = app.my_renter_id() and p.status = 'active'), '[]'::jsonb))
$$;

-- ================================================================ 10. the catalogue rows (the two campaign emails)
-- CATALOGUE 2520 START (generated by supabase/seed/2520_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('marketing_weekly', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', '{{headline}}', '{{preheader_text}}', 'Weekly', 'Weekly marketing campaign (2520, app.job_marketing): once a week, on Program settings marketing_weekly_dow at marketing_weekly_hour (Toronto time), to every address in the marketing audience (anyone who gave us their email on carmacars.ca: renters, accounts, leads, forms left unfinished), minus anyone unsubscribed, bounced, complained or suppressed. The cars and deals come from the live listings and the active public promo codes when the campaign is made. Queued at the marketing priority: booking, payment and sign-in emails always go first, and the sends are spread over the days within the free email budgets. Switch: marketing_weekly_enabled.', null, '/cars', '[{"name":"cars","type":"list","fields":["name","meta","url"]},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deals","type":"list","fields":["label","detail","url"]},{"name":"first_name","type":"string"},{"name":"has_deals","type":"boolean"},{"name":"headline","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"preheader_text","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"}]'::jsonb, 'templates/marketing_weekly.html', 'templates/marketing_weekly.txt'),
  ('marketing_new_vehicle', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'New in the fleet: the {{vehicle_name}}', 'From {{daily_price}} a day. Ready to book now.', 'When a new car is listed', 'New car campaign (2520, app.job_marketing): a car''s listing goes live on the site (published, bookable, not a sample car). Once per car, to every address in the marketing audience (anyone who gave us their email on carmacars.ca), minus anyone unsubscribed, bounced, complained or suppressed. Queued at the marketing priority and spread over the days within the free email budgets; an address still waiting when the car stops being listed is not sent. Switch: marketing_new_vehicle_enabled.', null, null, '[{"name":"car_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"daily_price","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"seats","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"transmission","type":"string"},{"name":"unsubscribe_url","type":"url"},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/marketing_new_vehicle.html', 'templates/marketing_new_vehicle.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 2520 END
-- what emits them; email only (a campaign never becomes a text: texts keep their own consent); the consent basis is
-- implied (CASL: an address given to us on the site, an existing business relationship or inquiry), as the owner set
update notification_catalogue
   set emitted_by = 'app.job_marketing through app.marketing_campaign_start (2520)', no_text = true, consent_rule = 'implied'
 where code in ('marketing_weekly', 'marketing_new_vehicle');

-- ================================================================ 11. grants and the schedule
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['marketing_new_vehicle_since', 'marketing_can_email', 'marketing_audience_refresh', 'marketing_daily_max',
              'marketing_price', 'marketing_listed_cars', 'marketing_weekly_payload', 'marketing_new_vehicle_payload', 'marketing_campaign_start', 'job_marketing',
              'has_marketing_consent_pre2520', 'unsubscribe_pre2520', 'notification_recipients_pre2520']))
        or (n.nspname = 'public' and p.proname = 'server_marketing_emails')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('carmacars-marketing', '3,18,33,48 * * * *', $q$select app.job_marketing()$q$);
  end if;
end $$;
