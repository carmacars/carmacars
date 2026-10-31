-- 0271: a car's weekend rate is always higher than its daily rate (docs/changes/2026-10-31-weekend-above-daily.md).
--
-- The owner saw cars whose weekend rate was not above the daily rate. Now:
-- 1. program_settings.weekend_premium_bps (1500 = 15%): what a weekend day costs above a weekday when it was not set higher.
-- 2. Any rate card saved with a weekend rate at or below its daily rate is raised to daily x (1 + premium), rounded up
--    to the dollar (a weekend rate already above daily is kept as typed). Partner and synced rate cards follow it too.
-- 3. The current rate cards that break the rule are raised now (bookings keep the rates they were made with).

alter table program_settings add column if not exists weekend_premium_bps integer not null default 1500
  check (weekend_premium_bps between 0 and 10000);
comment on column program_settings.weekend_premium_bps is 'A weekend rate at or below the daily rate is raised to daily plus this (0271), in basis points: 1500 = 15%.';

create or replace function app.weekend_floor_cents(p_daily bigint) returns bigint
language sql stable security definer set search_path = public, app as $$
  select (ceil(p_daily * (10000 + coalesce((app.settings()).weekend_premium_bps, 1500)) / 10000.0 / 100) * 100)::bigint
$$;

create or replace function app.rate_card_weekend_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.weekend_rate_cents <= new.daily_rate_cents then
    new.weekend_rate_cents := app.weekend_floor_cents(new.daily_rate_cents);
  end if;
  return new;
end $$;
drop trigger if exists rate_cards_weekend_guard on rate_cards;
create trigger rate_cards_weekend_guard before insert or update of daily_rate_cents, weekend_rate_cents on rate_cards
  for each row execute function app.rate_card_weekend_guard();

-- the current cards that break the rule
update rate_cards set weekend_rate_cents = app.weekend_floor_cents(daily_rate_cents)
 where effective_to is null and weekend_rate_cents <= daily_rate_cents;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('weekend_floor_cents', 'rate_card_weekend_guard') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
