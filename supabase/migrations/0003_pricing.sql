-- 0003_pricing.sql
-- Charge catalogue, admin defaults (D), per-vehicle rate cards and overrides (V).
-- Per-booking terms (B) live with the booking in 0005 (booking_fee_terms).

create type revenue_class as enum (
  'owner_revenue',    -- rental charge, late-return extra days, mileage overage (and the non-refundable discount, negative)
  'company_only',     -- every other renter fee
  'pass_through',     -- tolls, tickets, replacement cost, damage billed at cost
  'booking_expense',  -- referral kickback: deducted from the booking before Owner Revenue
  'claim_funds'       -- deductible and loss of use: go to the per-claim ledger
);

create type charge_stage as enum ('booking', 'pickup', 'extension', 'check_in', 'after_return', 'on_decline', 'monthly', 'split');

-- ---------------------------------------------------------------- charge catalogue
create table fee_types (
  code              text primary key,
  label             text not null,
  family            text not null check (family in ('rental', 'fee', 'pass_through', 'damage', 'deposit', 'expense')),
  unit              text not null check (unit in ('flat', 'per_day', 'per_km', 'per_hour', 'per_item', 'percent', 'at_cost')),
  per_what          text not null default 'rental' check (per_what in ('rental', 'driver', 'seat', 'item', 'invoice', 'charge', 'km', 'day')),
  revenue_class     revenue_class,              -- null for the deposit (not revenue)
  hst_applies       boolean not null,           -- 'as invoiced' items carry HST from the receipt on the line itself
  hst_as_invoiced   boolean not null default false,
  stage             charge_stage not null,
  refundable_by_tier boolean not null default false,
  change_default    boolean not null default false, -- D: admin default can be changed
  change_vehicle    boolean not null default false, -- V: per vehicle
  change_booking    boolean not null default false, -- B: per booking
  in_master_spec    boolean not null default true,  -- false = "Company*" (company only, not classified in the Master Spec)
  sort_order        integer not null default 0
);

-- ---------------------------------------------------------------- admin defaults (D)
create table fee_defaults (
  id             uuid primary key default gen_random_uuid(),
  fee_type_code  text not null references fee_types (code),
  vehicle_class  vehicle_class,                 -- null = all classes
  amount_cents   bigint check (amount_cents >= 0),  -- null = not yet priced (e.g. coverage sold): cannot be sold until set
  cap_cents      bigint check (cap_cents >= 0),     -- max per rental
  percent_bps    integer check (percent_bps >= 0),  -- markup, interest rate or cap multiplier
  min_cents      bigint check (min_cents >= 0),     -- allowed range for per-vehicle values
  max_cents      bigint check (max_cents >= 0),
  grace_minutes  integer,
  note           text,
  effective_from date not null default current_date,
  effective_to   date,
  set_by         uuid references users (id),
  created_at     timestamptz not null default now(),
  check (effective_to is null or effective_to > effective_from)
);
-- (an enum cast is not immutable, so the "all classes" row gets its own partial index)
create unique index fee_defaults_key_class on fee_defaults (fee_type_code, vehicle_class, effective_from) where vehicle_class is not null;
create unique index fee_defaults_key_all on fee_defaults (fee_type_code, effective_from) where vehicle_class is null;
create trigger audit_fee_defaults after insert or update or delete on fee_defaults
  for each row execute function app.audit_row();

-- ---------------------------------------------------------------- per-vehicle rate card (V)
create table rate_cards (
  id                   uuid primary key default gen_random_uuid(),
  vehicle_id           uuid not null references vehicles (id) on delete cascade,
  daily_rate_cents     bigint not null check (daily_rate_cents > 0),
  weekend_rate_cents   bigint not null check (weekend_rate_cents > 0),
  weekly_rate_cents    bigint not null check (weekly_rate_cents > 0),
  monthly_rate_cents   bigint not null check (monthly_rate_cents > 0),   -- 30 days
  km_allowance_per_day integer not null check (km_allowance_per_day >= 0),
  overage_cents_per_km integer not null check (overage_cents_per_km >= 0),
  deposit_cents        bigint not null check (deposit_cents >= 0),
  delivery_fee_cents   bigint not null check (delivery_fee_cents >= 0),
  pickup_fee_cents     bigint not null check (pickup_fee_cents >= 0),
  effective_from       timestamptz not null default now(),
  effective_to         timestamptz,
  set_by               uuid references users (id),  -- an admin, or the owner for a Self-Managed vehicle
  set_by_owner         boolean not null default false,
  created_at           timestamptz not null default now(),
  check (effective_to is null or effective_to > effective_from),
  exclude using gist (vehicle_id with =, tstzrange(effective_from, effective_to, '[)') with &&)
);
create index rate_cards_vehicle_idx on rate_cards (vehicle_id, effective_from desc);
create trigger audit_rate_cards after insert or update or delete on rate_cards
  for each row execute function app.audit_row();

-- Any other fee set for one vehicle (e.g. coverage price, young driver fee on an exotic).
create table vehicle_fee_overrides (
  id             uuid primary key default gen_random_uuid(),
  vehicle_id     uuid not null references vehicles (id) on delete cascade,
  fee_type_code  text not null references fee_types (code),
  amount_cents   bigint check (amount_cents >= 0),
  cap_cents      bigint check (cap_cents >= 0),
  percent_bps    integer check (percent_bps >= 0),
  reason         text,
  effective_from date not null default current_date,
  effective_to   date,
  set_by         uuid references users (id),
  created_at     timestamptz not null default now(),
  unique (vehicle_id, fee_type_code, effective_from),
  check (effective_to is null or effective_to > effective_from)
);
create trigger audit_vehicle_fee_overrides after insert or update or delete on vehicle_fee_overrides
  for each row execute function app.audit_row();

-- Resolve one fee for a vehicle on a date: vehicle override, then class default, then general default.
create or replace function public.effective_fee(p_fee text, p_vehicle uuid, p_on date default current_date)
returns table (amount_cents bigint, cap_cents bigint, percent_bps integer, source text)
language sql stable as $$
  with v as (select class from vehicles where id = p_vehicle),
  cand as (
    select o.amount_cents, o.cap_cents, o.percent_bps, 'vehicle'::text as source, 1 as rank
      from vehicle_fee_overrides o
     where o.vehicle_id = p_vehicle and o.fee_type_code = p_fee
       and o.effective_from <= p_on and (o.effective_to is null or o.effective_to > p_on)
    union all
    select d.amount_cents, d.cap_cents, d.percent_bps, 'default', case when d.vehicle_class is null then 3 else 2 end
      from fee_defaults d
     where d.fee_type_code = p_fee
       and (d.vehicle_class is null or d.vehicle_class = (select class from v))
       and d.effective_from <= p_on and (d.effective_to is null or d.effective_to > p_on)
  )
  select amount_cents, cap_cents, percent_bps, source from cand order by rank limit 1
$$;

-- ================================================================ pricing arithmetic
-- These functions are the single source of truth for money arithmetic. The TypeScript
-- pricing module calls them (RPC) rather than re-implementing them.

-- Billable days: hours from pickup time to return time / 24, rounded up. Minimum 1.
-- Measured on the Toronto clock, so a rental from 10:00 to 10:00 across a daylight-saving
-- change is still whole days (elapsed UTC time would make it 23 or 25 hours).
create or replace function public.calc_billable_days(p_pickup timestamptz, p_return timestamptz,
                                                     p_tz text default 'America/Toronto')
returns integer language sql immutable as $$
  select greatest(1, ceil(extract(epoch from ((p_return at time zone p_tz) - (p_pickup at time zone p_tz))) / 86400.0)::integer)
$$;

-- Rate selection (renter billing spec section 2).
create or replace function public.calc_rental_charge(
  p_pickup timestamptz, p_days integer,
  p_daily bigint, p_weekend bigint, p_weekly bigint, p_monthly bigint,
  p_tz text default 'America/Toronto')
returns table (rate_applied text, daily_days integer, weekend_days integer, rental_charge_cents bigint)
language plpgsql immutable as $$
declare
  v_daily integer := 0;
  v_weekend integer := 0;
  v_total bigint;
  i integer;
  v_dow integer;
begin
  if p_days < 1 or p_days > 30 then
    raise exception 'A rental transaction is 1 to 30 days; % requested. Longer stays renew with a new booking.', p_days
      using errcode = '22023';
  end if;
  if p_days <= 6 then
    for i in 0 .. p_days - 1 loop
      -- day i starts i x 24 hours after pickup on the Toronto clock
      v_dow := extract(dow from ((p_pickup at time zone p_tz) + make_interval(days => i)));
      if v_dow in (5, 6) then v_weekend := v_weekend + 1; else v_daily := v_daily + 1; end if;
    end loop;
    v_total := least(v_daily * p_daily + v_weekend * p_weekend, p_weekly);
    return query select 'daily'::text, v_daily, v_weekend, v_total;
  elsif p_days <= 29 then
    v_total := least(round(p_weekly::numeric * p_days / 7)::bigint, p_monthly);
    return query select 'weekly'::text, 0, 0, v_total;
  else
    return query select 'monthly'::text, 0, 0, p_monthly;
  end if;
end $$;

-- A per-day fee with a per-rental cap (young driver, additional driver, winter tire, baby seat).
create or replace function public.calc_capped_per_day(p_rate_cents bigint, p_days integer, p_cap_cents bigint, p_units integer default 1)
returns bigint language sql immutable as $$
  select p_units * least(p_rate_cents * p_days, coalesce(p_cap_cents, p_rate_cents * p_days))
$$;

-- HST on one taxable amount.
create or replace function public.calc_hst(p_amount_cents bigint, p_hst_bps integer default 1300)
returns bigint language sql immutable as $$ select public.calc_bps(p_amount_cents, p_hst_bps) $$;

-- Cancellation tier (renter billing spec section 5): the first row that fits applies.
-- Notice is elapsed time from when the cancellation is received to the pickup time.
-- p_by_carmacars: CarmaCars cancels, or a driver cannot be verified: 100%, even when non-refundable.
create or replace function public.calc_cancellation(
  p_booked_at timestamptz, p_received_at timestamptz, p_start_at timestamptz,
  p_non_refundable boolean, p_total_paid_cents bigint, p_by_carmacars boolean default false)
returns table (tier text, refund_bps integer, refund_cents bigint, retained_cents bigint)
language plpgsql immutable as $$
declare
  v_tier text;
  v_bps integer;
  v_notice interval := p_start_at - p_received_at;
begin
  if p_by_carmacars then
    v_tier := 'carmacars_cancelled'; v_bps := 10000;
  elsif p_non_refundable then
    v_tier := 'non_refundable'; v_bps := 0;
  elsif p_received_at - p_booked_at <= interval '24 hours' and v_notice >= interval '48 hours' then
    v_tier := 'within_24h_of_booking'; v_bps := 9500;
  elsif v_notice >= interval '48 hours' then
    v_tier := 'notice_48h_plus'; v_bps := 7500;
  elsif v_notice >= interval '24 hours' then
    v_tier := 'notice_24_to_48h'; v_bps := 5000;
  else
    v_tier := 'under_24h_or_after_start'; v_bps := 0;
  end if;
  return query select v_tier, v_bps, public.calc_bps(p_total_paid_cents, v_bps),
                      p_total_paid_cents - public.calc_bps(p_total_paid_cents, v_bps);
end $$;

-- Late return (section 1): nothing up to the grace period; then a fee per started hour counted
-- from the return time, capped at a multiple of the booking's daily rate per 24 hours, plus the
-- rental charge for each extra day or part day at the booking's daily rate.
create or replace function public.calc_late_return(
  p_minutes_late integer, p_booking_daily_rate_cents bigint,
  p_fee_per_hour_cents bigint default 2500, p_cap_multiplier_bps integer default 15000,
  p_grace_minutes integer default 30)
returns table (extra_days integer, extra_days_cents bigint, late_fee_cents bigint)
language plpgsql immutable as $$
declare
  v_hours integer;
  v_cap bigint := public.calc_bps(p_booking_daily_rate_cents, p_cap_multiplier_bps);
  v_days integer;
begin
  if p_minutes_late is null or p_minutes_late <= p_grace_minutes then
    return query select 0, 0::bigint, 0::bigint;
    return;
  end if;
  v_hours := ceil(p_minutes_late / 60.0)::integer;
  v_days := ceil(p_minutes_late / 1440.0)::integer;
  return query select v_days, v_days * p_booking_daily_rate_cents,
    (v_hours / 24) * v_cap + least((v_hours % 24) * p_fee_per_hour_cents, v_cap);
end $$;

-- Fuel: pump price plus 25%, plus the $25 service fee (both company only, before HST).
create or replace function public.calc_fuel_charge(p_pump_cost_cents bigint, p_markup_bps integer default 2500, p_service_fee_cents bigint default 2500)
returns table (fuel_cents bigint, service_fee_cents bigint, total_cents bigint)
language sql immutable as $$
  select f, p_service_fee_cents, f + p_service_fee_cents
    from (select p_pump_cost_cents + public.calc_bps(p_pump_cost_cents, p_markup_bps) as f) x
$$;

-- Mileage overage.
create or replace function public.calc_mileage_overage(p_km_out integer, p_km_in integer, p_allowance_km integer, p_cents_per_km integer)
returns bigint language sql immutable as $$
  select greatest(0, (p_km_in - p_km_out) - p_allowance_km)::bigint * p_cents_per_km
$$;

-- The refund percentage alone (basis points), for callers that only need the tier.
create or replace function public.calc_refund_bps(
  p_booked_at timestamptz, p_received_at timestamptz, p_start_at timestamptz,
  p_non_refundable boolean default false, p_by_carmacars boolean default false)
returns integer language sql immutable as $$
  select refund_bps from public.calc_cancellation(p_booked_at, p_received_at, p_start_at, p_non_refundable, 0, p_by_carmacars)
$$;

-- Deposit method (section 3): card hold for 7 days or less, charged then refunded for longer.
create or replace function public.calc_deposit_method(p_days integer, p_hold_max_days integer default 7)
returns text language sql immutable as $$
  select case when p_days <= p_hold_max_days then 'card_hold' else 'charged' end
$$;

-- Interest on an overdue balance for one month (1.5% a month, compounding monthly).
create or replace function public.calc_monthly_interest(p_balance_cents bigint, p_monthly_bps integer default 150)
returns bigint language sql immutable as $$ select public.calc_bps(greatest(p_balance_cents, 0), p_monthly_bps) $$;

-- Referral kickback (section 8 step 1): 20% of the rental charge after discount and before HST,
-- only when the booking qualifies. Eligibility itself is decided by app.kickback_eligibility().
create or replace function public.calc_kickback(p_rental_charge_cents bigint, p_eligible boolean, p_kickback_bps integer default 2000)
returns bigint language sql immutable as $$
  select case when p_eligible then public.calc_bps(p_rental_charge_cents, p_kickback_bps) else 0 end
$$;

-- The whole split of one booking (section 8 steps 1 to 4).
--   p_rental_charge_cents  rental charge after discount, with late-return extra days, before HST
--   p_company_share_bps    the vehicle's Revenue Share; 1000 on a shareholder-owned car; 0 Self-Managed
create or replace function public.calc_booking_split(
  p_rental_charge_cents bigint, p_mileage_overage_cents bigint, p_kickback_eligible boolean,
  p_company_share_bps integer, p_kickback_bps integer default 2000)
returns table (kickback_cents bigint, owner_revenue_cents bigint, company_share_cents bigint, owner_payout_cents bigint)
language sql immutable as $$
  select k, r, public.calc_bps(r, p_company_share_bps), r - public.calc_bps(r, p_company_share_bps)
  from (select k, p_rental_charge_cents + p_mileage_overage_cents - k as r
          from (select public.calc_kickback(p_rental_charge_cents, p_kickback_eligible, p_kickback_bps) as k) a) b
$$;

-- The same split when the kickback is already known.
create or replace function public.calc_split(
  p_rental_charge_cents bigint, p_mileage_overage_cents bigint, p_kickback_cents bigint, p_company_share_bps integer)
returns table (owner_revenue_cents bigint, company_share_cents bigint, owner_payout_cents bigint)
language sql immutable as $$
  select r, public.calc_bps(r, p_company_share_bps), r - public.calc_bps(r, p_company_share_bps)
  from (select p_rental_charge_cents + p_mileage_overage_cents - p_kickback_cents as r) x
$$;

-- Extension (section 6): the whole booking is repriced at its new total length, at the rates
-- stored on it, and the renter pays the difference. Total length stays at 30 days or less.
create or replace function public.calc_extension(
  p_pickup timestamptz, p_current_days integer, p_new_days integer,
  p_daily bigint, p_weekend bigint, p_weekly bigint, p_monthly bigint, p_tz text default 'America/Toronto')
returns table (previous_rental_charge_cents bigint, new_rental_charge_cents bigint, rental_difference_cents bigint)
language sql immutable as $$
  select o.rental_charge_cents, n.rental_charge_cents, n.rental_charge_cents - o.rental_charge_cents
    from public.calc_rental_charge(p_pickup, p_current_days, p_daily, p_weekend, p_weekly, p_monthly, p_tz) o,
         public.calc_rental_charge(p_pickup, p_new_days, p_daily, p_weekend, p_weekly, p_monthly, p_tz) n
$$;

-- Card on File declined (section 7): retries after 1, 3 and 7 days, counted from the first decline.
-- Returns null when there is no further retry.
create or replace function public.calc_payment_retry_at(p_first_declined_at timestamptz, p_retries_done integer)
returns timestamptz language sql immutable as $$
  select case p_retries_done when 0 then p_first_declined_at + interval '1 day'
                             when 1 then p_first_declined_at + interval '3 days'
                             when 2 then p_first_declined_at + interval '7 days' end
$$;

-- Who pays the transfer-back fees on exit (owner spec section 9).
create or replace function public.calc_retransfer_payer(
  p_months_on_fleet_policy integer, p_owner_default boolean default false,
  p_insurer_declined boolean default false, p_owner_failed_to_disclose boolean default false,
  p_free_after_months integer default 6)
returns text language sql immutable as $$
  select case when p_owner_default then 'owner'
              when p_insurer_declined then case when p_owner_failed_to_disclose then 'owner' else 'carmacars' end
              when p_months_on_fleet_policy >= p_free_after_months then 'carmacars'
              else 'owner' end
$$;

-- Buyout price: Canadian Black Book average trade-in value on the offer date x 1.10 (plus any sales tax).
create or replace function public.calc_buyout_price(p_black_book_cents bigint, p_premium_bps integer default 1000)
returns bigint language sql immutable as $$ select p_black_book_cents + public.calc_bps(p_black_book_cents, p_premium_bps) $$;

-- An owner Fee pro-rated by day for the enrollment or exit month.
create or replace function public.calc_prorated_fee(p_monthly_cents bigint, p_days_active integer, p_days_in_month integer)
returns bigint language sql immutable as $$
  select round(p_monthly_cents::numeric * p_days_active / p_days_in_month)::bigint
$$;

-- An investor's Return for one Return Month: one-twelfth of the Yearly Percentage on the
-- Invested Amount at the start of the month, pro-rated by days for a part month.
create or replace function public.calc_investment_return(
  p_invested_cents bigint, p_yearly_bps integer, p_days_earning integer, p_days_in_month integer)
returns bigint language sql immutable as $$
  select round((p_invested_cents::numeric * p_yearly_bps * p_days_earning) / (120000::numeric * p_days_in_month))::bigint
$$;
