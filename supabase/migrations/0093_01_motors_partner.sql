-- 0093_01_motors_partner.sql
-- A partner rental company's whole fleet and a chauffeur service (the owner's request of October 22, 2026;
-- docs/changes/2026-10-22-01-motors-partner.md).
--
--   1. The partner "01 Motors" (0046's partner supply model): no portal sign-in yet, staff manage its cars.
--   2. Pricing on the partner's own rates (a "partner-rate basis"): each car keeps the partner's sheet rates (1 to 2
--      days, 3 or more days, 7 or more days), editable in Admin. The renter pays the sheet rate marked up (10% by
--      default), rounded to the nearest dollar; CarmaCars takes its cut (20% of the sheet rate by default) and the
--      partner is owed the rest of the sheet rate. The markup and the cut are per partner with a per-car override.
--      0046's commission machinery took a percentage of the renter's price; on this basis the split records the
--      sheet amount, the cut and the payout, and the markup stays with CarmaCars (booking_splits.partner_markup_cents).
--   3. A 3+ day tier in the pricing engine: public.calc_rental_charge with a multi-day rate (8 arguments), the rate
--      card's and the booking's multi_day_rate_cents, and every caller that prices a booking passes it.
--   4. Per car: "insurance included" (no personal auto policy needed: coverage option 4, confirmed by itself) and "no
--      credit card needed" (a debit card pays and holds the deposit). The deposit, the ID checks and the ages stay.
--   5. A year that is approximate (the sheet has none): the public pages and the car's name leave it out and say
--      "Year confirmed when you book"; no VIN or plate is invented (a partner car may wait for both).
--   6. The chauffeur service: vehicles with a 2-hour and a 3+ hour rate, the public request (a lead of kind
--      'chauffeur' with its quote), staff confirmation in Admin, a To do line.
--   7. The data: the partner, its 62 cars (published, as requests) and its 11 chauffeur vehicles, keyed by the sheet's
--      row names so a second run adds nothing twice.
-- No earlier migration is edited. Functions that change are wrapped (renamed _pre0093) or patched in place with
-- pg_temp.patch_fn (0066, 0081), which refuses when the text it changes is not found.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0093: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings and columns
alter table program_settings
  add column if not exists partner_markup_bps integer not null default 1000 check (partner_markup_bps between 0 and 20000);
comment on column program_settings.partner_markup_bps is 'What the renter pays above a partner''s sheet rate unless the partner or the car has its own (0093): 10% by default';

alter table partners
  add column if not exists markup_bps integer check (markup_bps between 0 and 20000),
  add column if not exists payout_basis text not null default 'renter_price' check (payout_basis in ('renter_price', 'partner_rate'));
comment on column partners.markup_bps is 'The markup on this partner''s sheet rates (0093); empty: Program settings';
comment on column partners.payout_basis is 'renter_price: CarmaCars keeps the commission of what the renter paid (0046). partner_rate: the partner is owed its sheet rate less the commission, and the markup stays with CarmaCars (0093)';

alter table vehicles
  add column if not exists partner_markup_bps integer check (partner_markup_bps between 0 and 20000),
  add column if not exists insurance_included boolean not null default false,
  add column if not exists no_credit_card boolean not null default false,
  add column if not exists year_approximate boolean not null default false,
  add column if not exists partner_sheet_name text;
alter table vehicles add constraint vehicles_partner_markup check (partner_markup_bps is null or supply_type = 'partner');
create unique index if not exists vehicles_partner_sheet_name on vehicles (partner_id, lower(partner_sheet_name)) where partner_sheet_name is not null;
comment on column vehicles.partner_markup_bps is 'This partner car''s own markup on its sheet rates (0093); empty: the partner''s';
comment on column vehicles.insurance_included is 'Insurance comes with the car: the renter needs no personal auto policy; the booking''s coverage is option 4, confirmed by itself (0093)';
comment on column vehicles.no_credit_card is 'No credit card needed: a debit card in the renter''s name pays and holds the deposit (0093)';
comment on column vehicles.year_approximate is 'The model year is not known yet (a partner''s price sheet has none): the public pages and the car''s name leave it out and say the year is confirmed when the renter books (0093)';
comment on column vehicles.partner_sheet_name is 'The row of the partner''s price sheet this car came from (0093): the import''s key';

-- a partner car may wait for its plate and VIN (the partner's sheet has neither; staff add them in Admin)
alter table vehicles drop constraint if exists vehicles_plate_or_vin;
alter table vehicles add constraint vehicles_plate_or_vin check (vin is not null or nullif(btrim(plate), '') is not null or supply_type = 'partner');
-- ESV and EXT (Escalade ESV, Suburban and Yukon trims) stay in capitals (0087's rule; the same list is
-- web/src/features/vin/name-case.ts)
select pg_temp.patch_fn('app.car_name_case(text, text)'::regprocedure, $o$'EQS', 'TRD'];$o$, $n$'EQS', 'TRD', 'ESV', 'EXT'];$n$);
-- and it goes on the site without them (the checklist still says "No VIN yet"; handover needs the plate on the agreement)
select pg_temp.patch_fn('app.listing_basics_missing(uuid)'::regprocedure,
  $o$  if v.vin is null and nullif(btrim(v.plate), '') is null then$o$,
  $n$  if v.vin is null and nullif(btrim(v.plate), '') is null and v.supply_type <> 'partner' then$n$);

alter table rate_cards add column if not exists multi_day_rate_cents bigint check (multi_day_rate_cents > 0);
comment on column rate_cards.multi_day_rate_cents is 'The rate a day for rentals of 3 to 6 days (0093); empty: the daily and weekend rates as before';
alter table bookings
  add column if not exists multi_day_rate_cents bigint check (multi_day_rate_cents > 0),
  add column if not exists partner_sheet_rental_cents bigint check (partner_sheet_rental_cents >= 0),
  add column if not exists partner_cut_bps integer check (partner_cut_bps between 0 and 10000),
  add column if not exists partner_markup_bps integer check (partner_markup_bps between 0 and 20000);
comment on column bookings.multi_day_rate_cents is 'The car''s 3+ day rate when the booking was made (0093)';
comment on column bookings.partner_sheet_rental_cents is 'A partner-rate car (0093): what the rental comes to at the partner''s sheet rates, the amount the partner is paid on';

alter table booking_splits
  add column if not exists partner_rate_basis boolean not null default false,
  add column if not exists partner_sheet_cents bigint,
  add column if not exists partner_markup_cents bigint not null default 0;
comment on column booking_splits.partner_sheet_cents is 'A partner-rate car (0093): the sheet amount of this rental after refunds (owner_revenue_cents is this plus the mileage)';
comment on column booking_splits.partner_markup_cents is 'A partner-rate car (0093): the part of the rental charge above the sheet amount, CarmaCars'' own';
alter table booking_splits drop constraint if exists booking_splits_check1;
do $$
declare
  c record;
begin
  for c in select conname from pg_constraint where conrelid = 'booking_splits'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%owner_revenue_cents = ((rental_charge_cents + mileage_overage_cents) - kickback_cents)%' loop
    execute format('alter table booking_splits drop constraint %I', c.conname);
  end loop;
end $$;
alter table booking_splits add constraint booking_splits_owner_revenue
  check (owner_revenue_cents = rental_charge_cents + mileage_overage_cents - kickback_cents - partner_markup_cents);
alter table owner_statement_lines
  add column if not exists partner_sheet_cents bigint,
  add column if not exists partner_cut_bps integer;

-- the partner's sheet rates of a car, per day (1-2 days, 3+ days, 7+ days), editable in Admin
create table if not exists partner_rates (
  vehicle_id      uuid primary key references vehicles (id) on delete cascade,
  base_cents      bigint not null check (base_cents > 0),
  multi_day_cents bigint not null check (multi_day_cents > 0),
  long_term_cents bigint not null check (long_term_cents > 0),
  source          text,
  updated_by      uuid references users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create trigger partner_rates_updated before update on partner_rates for each row execute function app.set_updated_at();
create trigger audit_partner_rates after insert or update or delete on partner_rates for each row execute function app.audit_row();
comment on table partner_rates is 'A partner car''s sheet rates per day (0093): base (1 to 2 days), multi-day (3 or more), long term (7 or more). The renter''s rate card is made from them with the markup.';
alter table partner_rates enable row level security;
create policy admin_all on partner_rates for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- a booking may be priced at the 3+ day rate
alter table bookings drop constraint if exists bookings_rate_applied_check;
alter table bookings add constraint bookings_rate_applied_check check (rate_applied in ('daily', 'multi_day', 'weekly', 'monthly', 'none'));

-- coverage option 4: insurance included with the car
alter table bookings drop constraint if exists bookings_coverage_option_check;
alter table bookings add constraint bookings_coverage_option_check check (coverage_option in (1, 2, 3, 4));
alter table coverage_proofs drop constraint if exists coverage_proofs_coverage_option_check;
alter table coverage_proofs add constraint coverage_proofs_coverage_option_check check (coverage_option in (1, 2, 3, 4));

-- leads of kind 'chauffeur' (added to whatever the list is when this runs)
do $$
declare
  d text;
  v text[];
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = 'leads'::regclass and conname = 'leads_kind_check';
  select array_agg(m[1]) into v from regexp_matches(coalesce(d, ''), '''([a-z_]+)''', 'g') m;
  if v is null then v := array['owner_program', 'contact', 'insurer', 'launch_notice', 'other']; end if;
  if not 'chauffeur' = any (v) then v := v || 'chauffeur'::text; end if;
  execute 'alter table leads drop constraint if exists leads_kind_check';
  execute format('alter table leads add constraint leads_kind_check check (kind = any (%L::text[]))', v);
end $$;

-- ================================================================ 2. money: the markup, the 3+ day tier
-- The renter's price for a partner's sheet amount: marked up, rounded to the nearest dollar (half a dollar up). The
-- same rule is renterCents in web/src/features/partner/fleet-01-motors.ts.
create or replace function app.partner_renter_cents(p_sheet_cents bigint, p_markup_bps integer) returns bigint
language sql immutable as $$
  select (round(p_sheet_cents::numeric * (10000 + coalesce(p_markup_bps, 0)) / 1000000) * 100)::bigint
$$;

-- The markup on a partner car: its own, the partner's, or Program settings.
create or replace function app.partner_markup_bps(p_vehicle uuid, p_on date default app.today()) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(v.partner_markup_bps, p.markup_bps, (app.settings(p_on)).partner_markup_bps)
    from vehicles v left join partners p on p.id = v.partner_id where v.id = p_vehicle
$$;

-- Is this car priced on the partner-rate basis (a partner car with sheet rates, its partner on that basis)?
create or replace function app.partner_rate_basis(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select v.supply_type = 'partner' and p.payout_basis = 'partner_rate'
                     and exists (select 1 from partner_rates r where r.vehicle_id = v.id)
                     from vehicles v join partners p on p.id = v.partner_id where v.id = p_vehicle), false)
$$;

-- 0003's rate selection with the 3+ day tier: with a multi-day rate, a rental of 3 to 6 days is that rate a day (never
-- more than the daily and weekend rates would come to, which are capped at the weekly rate). Without one, 0003's rules.
create or replace function public.calc_rental_charge(
  p_pickup timestamptz, p_days integer, p_daily bigint, p_weekend bigint, p_weekly bigint, p_monthly bigint, p_tz text, p_multi bigint)
returns table (rate_applied text, daily_days integer, weekend_days integer, rental_charge_cents bigint)
language plpgsql immutable as $$
declare
  r record;
begin
  select * into r from public.calc_rental_charge(p_pickup, p_days, p_daily, p_weekend, p_weekly, p_monthly, coalesce(p_tz, 'America/Toronto'));
  if p_multi is not null and p_multi > 0 and p_days between 3 and 6 and r.rate_applied = 'daily' then
    return query select 'multi_day'::text, 0, 0, least(p_multi * p_days, r.rental_charge_cents);
    return;
  end if;
  return query select r.rate_applied, r.daily_days, r.weekend_days, r.rental_charge_cents;
end $$;
grant execute on function public.calc_rental_charge(timestamptz, integer, bigint, bigint, bigint, bigint, text, bigint) to anon, authenticated, service_role;

-- What a rental of a partner car comes to at the partner's sheet rates (the same tiers as the renter's rate card).
create or replace function app.partner_sheet_rental_cents(p_vehicle uuid, p_pickup timestamptz, p_days integer) returns bigint
language sql stable security definer set search_path = public, app as $$
  select (public.calc_rental_charge(p_pickup, p_days, r.base_cents, r.base_cents, r.long_term_cents * 7, r.long_term_cents * 30,
                                    'America/Toronto', r.multi_day_cents)).rental_charge_cents
    from partner_rates r where r.vehicle_id = p_vehicle and p_days between 1 and 30
$$;

-- price_lines: the multi-day rate in the description of a booking's price, and its rule
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$  v_monthly bigint := coalesce((p ->> 'monthly_rate_cents')::bigint, 0);$o$,
  $n$  v_monthly bigint := coalesce((p ->> 'monthly_rate_cents')::bigint, 0);
  v_multi bigint := nullif(p ->> 'multi_day_rate_cents', '')::bigint;   -- 0093: the 3+ day tier$n$);
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$public.calc_rental_charge(v_pickup, v_days, v_daily, v_weekend, v_weekly, v_monthly);$o$,
  $n$public.calc_rental_charge(v_pickup, v_days, v_daily, v_weekend, v_weekly, v_monthly, 'America/Toronto', v_multi);$n$);
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$  elsif r.rate_applied = 'weekly' then$o$,
  $n$  elsif r.rate_applied = 'multi_day' then
    v_uncapped := v_days * v_multi;
    v_capped := v_uncapped > r.rental_charge_cents;
    v_rule := format('%s days at the 3+ day rate', v_days) || case when v_capped then ', capped at the weekly rate' else '' end;
  elsif r.rate_applied = 'weekly' then$n$);
-- the quote (car page, request, rentals added by hand) and a booking's own price carry the rate
select pg_temp.patch_fn('app.price_quote(uuid, timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$    'weekly_rate_cents', rc.weekly_rate_cents, 'monthly_rate_cents', rc.monthly_rate_cents,
$o$,
  $n$    'weekly_rate_cents', rc.weekly_rate_cents, 'monthly_rate_cents', rc.monthly_rate_cents, 'multi_day_rate_cents', rc.multi_day_rate_cents,
$n$);
select pg_temp.patch_fn('app.price_quote(uuid, timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$                                'weekly_rate_cents', rc.weekly_rate_cents, 'monthly_rate_cents', rc.monthly_rate_cents),$o$,
  $n$                                'weekly_rate_cents', rc.weekly_rate_cents, 'monthly_rate_cents', rc.monthly_rate_cents,
                                'multi_day_rate_cents', rc.multi_day_rate_cents),$n$);
select pg_temp.patch_fn('app.booking_price_spec(uuid, jsonb)'::regprocedure,
  $o$    'weekly_rate_cents', b.weekly_rate_cents, 'monthly_rate_cents', b.monthly_rate_cents,$o$,
  $n$    'weekly_rate_cents', b.weekly_rate_cents, 'monthly_rate_cents', b.monthly_rate_cents, 'multi_day_rate_cents', b.multi_day_rate_cents,$n$);
-- every other place a booking is priced from its stored rates
select pg_temp.patch_fn('app.confirm_extension_payment(uuid, jsonb, bigint, timestamptz, uuid)'::regprocedure,
  $o$b.weekly_rate_cents, b.monthly_rate_cents);$o$,
  $n$b.weekly_rate_cents, b.monthly_rate_cents, 'America/Toronto', b.multi_day_rate_cents);$n$);
select pg_temp.patch_fn('app.preview_booking_change(uuid, jsonb)'::regprocedure,
  $o$b.weekly_rate_cents, b.monthly_rate_cents);$o$,
  $n$b.weekly_rate_cents, b.monthly_rate_cents, 'America/Toronto', b.multi_day_rate_cents);$n$);
select pg_temp.patch_fn('app.apply_booking_change(uuid, uuid, jsonb, bigint)'::regprocedure,
  $o$b.weekly_rate_cents, b.monthly_rate_cents);$o$,
  $n$b.weekly_rate_cents, b.monthly_rate_cents, 'America/Toronto', b.multi_day_rate_cents);$n$);
select pg_temp.patch_fn('app.booking_rate_sheet_cents(uuid)'::regprocedure,
  $o$b.weekly_rate_cents, b.monthly_rate_cents)).rental_charge_cents$o$,
  $n$b.weekly_rate_cents, b.monthly_rate_cents, 'America/Toronto', b.multi_day_rate_cents)).rental_charge_cents$n$);
select pg_temp.patch_fn('app.manual_rental_create_0058(uuid, jsonb)'::regprocedure,
  $o$coalesce(rc.weekly_rate_cents, 0), coalesce(rc.monthly_rate_cents, 0));$o$,
  $n$coalesce(rc.weekly_rate_cents, 0), coalesce(rc.monthly_rate_cents, 0), 'America/Toronto', rc.multi_day_rate_cents);$n$);
select pg_temp.patch_fn('app.request_booking(uuid, uuid, timestamptz, timestamptz, booking_type, text, text, uuid, text, text, text, text, text, text)'::regprocedure,
  $o$coalesce(rc.weekly_rate_cents, 0), coalesce(rc.monthly_rate_cents, 0));$o$,
  $n$coalesce(rc.weekly_rate_cents, 0), coalesce(rc.monthly_rate_cents, 0), 'America/Toronto', rc.multi_day_rate_cents);$n$);
-- the calendar's and staff's change previews keep the rate with the others
select pg_temp.patch_fn('app.calendar_preview_change(uuid, jsonb, timestamptz)'::regprocedure,
  $o$  v_daily bigint; v_weekend bigint; v_weekly bigint; v_monthly bigint;$o$,
  $n$  v_daily bigint; v_weekend bigint; v_weekly bigint; v_monthly bigint; v_multi bigint;$n$);
select pg_temp.patch_fn('app.calendar_preview_change(uuid, jsonb, timestamptz)'::regprocedure,
  $o$v_monthly := b.monthly_rate_cents;$o$, $n$v_monthly := b.monthly_rate_cents; v_multi := b.multi_day_rate_cents;$n$);
select pg_temp.patch_fn('app.calendar_preview_change(uuid, jsonb, timestamptz)'::regprocedure,
  $o$v_monthly := rc.monthly_rate_cents;$o$, $n$v_monthly := rc.monthly_rate_cents; v_multi := rc.multi_day_rate_cents;$n$);
select pg_temp.patch_fn('app.calendar_preview_change(uuid, jsonb, timestamptz)'::regprocedure,
  $o$public.calc_rental_charge(v_pickup, v_days, v_daily, v_weekend, v_weekly, v_monthly);$o$,
  $n$public.calc_rental_charge(v_pickup, v_days, v_daily, v_weekend, v_weekly, v_monthly, 'America/Toronto', v_multi);$n$);
select pg_temp.patch_fn('app.adjust_booking_0016(uuid, uuid, jsonb, text)'::regprocedure,
  $o$  v_daily bigint; v_weekend bigint; v_weekly bigint; v_monthly bigint;$o$,
  $n$  v_daily bigint; v_weekend bigint; v_weekly bigint; v_monthly bigint; v_multi bigint;$n$);
select pg_temp.patch_fn('app.adjust_booking_0016(uuid, uuid, jsonb, text)'::regprocedure,
  $o$v_monthly := b.monthly_rate_cents;$o$, $n$v_monthly := b.monthly_rate_cents; v_multi := b.multi_day_rate_cents;$n$);
select pg_temp.patch_fn('app.adjust_booking_0016(uuid, uuid, jsonb, text)'::regprocedure,
  $o$v_monthly := rc.monthly_rate_cents;$o$, $n$v_monthly := rc.monthly_rate_cents; v_multi := rc.multi_day_rate_cents;$n$);
select pg_temp.patch_fn('app.adjust_booking_0016(uuid, uuid, jsonb, text)'::regprocedure,
  $o$public.calc_rental_charge(v_pickup, v_days, v_daily, v_weekend, v_weekly, v_monthly);$o$,
  $n$public.calc_rental_charge(v_pickup, v_days, v_daily, v_weekend, v_weekly, v_monthly, 'America/Toronto', v_multi);$n$);

-- A rate card made for a partner car without the multi-day rate (the Rates tab) keeps the one from its sheet rates.
create or replace function app.rate_cards_partner_multi() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.multi_day_rate_cents is null then
    select app.partner_renter_cents(r.multi_day_cents, app.partner_markup_bps(new.vehicle_id)) into new.multi_day_rate_cents
      from partner_rates r where r.vehicle_id = new.vehicle_id;
    -- never above the daily rate the card was given
    if new.multi_day_rate_cents > new.daily_rate_cents then new.multi_day_rate_cents := new.daily_rate_cents; end if;
  end if;
  return new;
end $$;
create trigger rate_cards_partner_multi before insert on rate_cards for each row execute function app.rate_cards_partner_multi();

-- ================================================================ 3. a booking: the 3+ day rate, the partner basis, coverage option 4
-- Before a booking is written: the car's multi-day rate with the rates it was priced at; on a partner-rate car the
-- sheet amount, the cut and the markup (kept from when it was made; the sheet amount follows the dates and the car);
-- on a car with insurance included, coverage option 4.
create or replace function app.bookings_partner_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  rc rate_cards;
  v_days integer;
  v_moved boolean := tg_op = 'UPDATE' and new.vehicle_id is distinct from old.vehicle_id;
begin
  select * into v from vehicles where id = new.vehicle_id;
  if v.id is null then return new; end if;
  if tg_op = 'INSERT' or v_moved then
    if tg_op = 'INSERT' and new.multi_day_rate_cents is not null then null;
    else
      select * into rc from rate_cards r where r.vehicle_id = v.id and r.effective_from <= coalesce(new.booked_at, now())
         and (r.effective_to is null or r.effective_to > coalesce(new.booked_at, now())) order by r.effective_from desc limit 1;
      new.multi_day_rate_cents := case when rc.id is not null and rc.daily_rate_cents = new.daily_rate_cents then rc.multi_day_rate_cents end;
    end if;
    if app.partner_rate_basis(v.id) and new.booking_type::text <> 'owner' then
      new.partner_cut_bps := app.partner_commission_bps(v.id);
      new.partner_markup_bps := app.partner_markup_bps(v.id);
    else
      new.partner_cut_bps := null; new.partner_markup_bps := null; new.partner_sheet_rental_cents := null;
    end if;
  end if;
  if new.partner_cut_bps is not null then
    v_days := coalesce(new.billable_days, public.calc_billable_days(new.pickup_at, new.return_at));
    new.partner_sheet_rental_cents := coalesce(app.partner_sheet_rental_cents(v.id, new.pickup_at, v_days), new.partner_sheet_rental_cents);
  end if;
  if new.booking_type::text <> 'owner' then
    if v.insurance_included then
      new.coverage_option := 4;
    elsif new.coverage_option = 4 then
      -- moved to a car without insurance included: the renter chooses again
      new.coverage_option := null; new.coverage_confirmed_at := null;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists bookings_z9_partner on bookings;
create trigger bookings_z9_partner before insert or update of vehicle_id, pickup_at, return_at, billable_days, coverage_option on bookings
  for each row execute function app.bookings_partner_before();

-- After: coverage option 4 is confirmed at once (the car's own insurance, nothing for the renter to send).
create or replace function app.bookings_included_coverage_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.coverage_option = 4 and new.booking_type::text <> 'owner'
     and not exists (select 1 from coverage_proofs c where c.booking_id = new.id and c.coverage_option = 4 and c.status = 'confirmed') then
    update coverage_proofs set status = 'lapsed' where booking_id = new.id and status in ('submitted', 'confirmed');
    insert into coverage_proofs (booking_id, coverage_option, status, confirmed_at, covers_vehicle_and_drivers, confirmation_text, submitted_at)
    values (new.id, 4, 'confirmed', now(), true, 'Insurance included with the car: no personal auto policy needed (0093)', now());
  end if;
  if new.coverage_option = 4 and new.coverage_confirmed_at is null then
    update bookings set coverage_confirmed_at = now() where id = new.id and coverage_confirmed_at is null;
  end if;
  return null;
end $$;
drop trigger if exists bookings_z9_included_coverage on bookings;
create trigger bookings_z9_included_coverage after insert or update of coverage_option, vehicle_id on bookings
  for each row when (new.coverage_option = 4) execute function app.bookings_included_coverage_after();

create or replace function app.coverage_option_label(p_option integer) returns text
language sql immutable as $$
  select case p_option when 1 then 'OPCF 27 on your own auto policy' when 2 then 'rental coverage on your credit card'
                       when 3 then 'the CarmaCars Protection Plan' when 4 then 'insurance included with the car'
                       else 'no option chosen yet' end
$$;

-- The request: a car with insurance included takes option 4 whatever was sent; option 4 is never chosen for another car.
select pg_temp.patch_fn('app.submit_booking_request_pre0066(jsonb, inet, text, uuid)'::regprocedure,
  $o$  v_cover integer := (p_request ->> 'coverage_option')::integer;$o$,
  $n$  v_cover integer := case when coalesce((select v0.insurance_included from vehicles v0 where v0.id = nullif(p_request ->> 'vehicle_id', '')::uuid), false) then 4
                           when nullif(p_request ->> 'coverage_option', '') = '4' then null
                           else nullif(p_request ->> 'coverage_option', '')::integer end;   -- 0093$n$);
select pg_temp.patch_fn('app.submit_booking_request_pre0066(jsonb, inet, text, uuid)'::regprocedure,
  $o$  if v_cover is null or v_cover not in (1, 2, 3) then$o$,
  $n$  if v_cover is null or v_cover not in (1, 2, 3, 4) then$n$);
-- the renter changes option 1 or 2 before pickup; never on a car with insurance included
select pg_temp.patch_fn('app.set_coverage_option(uuid, uuid, integer)'::regprocedure,
  $o$  perform app.coverage_assert_open(b);$o$,
  $n$  if b.coverage_option = 4 then
    raise exception 'Insurance is included with this car: there is nothing to choose or send.' using errcode = '23514';
  end if;
  perform app.coverage_assert_open(b);$n$);

-- ================================================================ 4. no credit card needed: a debit card pays
-- The card that pays may be a debit card on a car marked "no credit card needed" (a prepaid card is still refused).
create or replace function app.booking_card_ok(p_booking uuid, p_card jsonb) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select v.no_credit_card from bookings b join vehicles v on v.id = b.vehicle_id where b.id = p_booking), false)
     and coalesce(p_card ->> 'funding', 'debit') in ('credit', 'debit', 'unknown')
$$;
select pg_temp.patch_fn('app.finalize_booking_pre0074(uuid, text, jsonb, bigint, integer, jsonb, uuid)'::regprocedure,
  $o$if p_card is not null and (p_card ->> 'is_credit') = 'false' then$o$,
  $n$if p_card is not null and (p_card ->> 'is_credit') = 'false' and not app.booking_card_ok(p_booking, p_card) then$n$);
select pg_temp.patch_fn('app.finalize_live_payment(uuid, jsonb, bigint, jsonb, uuid)'::regprocedure,
  $o$if p_card is not null and (p_card ->> 'is_credit') = 'false' then$o$,
  $n$if p_card is not null and (p_card ->> 'is_credit') = 'false' and not app.booking_card_ok(p_booking, p_card) then$n$);

-- the pay page says so (the server reads it)
create or replace function public.vehicle_takes_debit(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select no_credit_card from vehicles where id = p_vehicle), false)
$$;
revoke all on function public.vehicle_takes_debit(uuid) from public, anon, authenticated;
grant execute on function public.vehicle_takes_debit(uuid) to service_role;

-- ================================================================ 5. the split on the partner's rates, and its statement line
-- 0058's split, then, for a booking on a partner-rate car (one car, the usual case): the partner's revenue is the
-- sheet amount of the rental kept (scaled by what the renter kept of the planned rental: a refund or a chargeback
-- lowers it in proportion, a late return's extra days raise it, a discount CarmaCars gave does not change it) plus the
-- extra kilometres; CarmaCars' cut is the commission of that; the payout the rest. The markup (the rental charge above
-- the sheet amount, after the kickbacks) is CarmaCars' own. A booking moved to another car after pickup keeps 0058's
-- split for its parts. A part already paid out is not rewritten: a later refund's share goes on the next statement.
alter function app.compute_booking_split(uuid) rename to compute_booking_split_pre0093;
create or replace function app.compute_booking_split(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s booking_splits;
  v_before uuid[];
  v_planned bigint;
  v_base bigint;
  v_rev bigint; v_share bigint; v_pay bigint; v_prior bigint; v_delta bigint;
  n integer;
begin
  select * into b from bookings where id = p_booking;
  select coalesce(array_agg(id), '{}') into v_before from owner_deductions where booking_id = p_booking;
  -- an unpaid part on this basis goes back to the plain columns before 0058 writes it again
  update booking_splits set partner_markup_cents = 0, partner_rate_basis = false, partner_sheet_cents = null,
         owner_revenue_cents = rental_charge_cents + mileage_overage_cents - kickback_cents, company_share_cents = 0,
         owner_payout_cents = rental_charge_cents + mileage_overage_cents - kickback_cents
   where booking_id = p_booking and owner_statement_id is null and partner_rate_basis;
  perform app.compute_booking_split_pre0093(p_booking);
  if b.id is null or b.partner_cut_bps is null or b.partner_sheet_rental_cents is null or b.booking_type::text = 'owner' then return; end if;
  select count(*) into n from booking_splits where booking_id = p_booking;
  if n <> 1 then return; end if;
  select * into s from booking_splits where booking_id = p_booking and vehicle_id = b.vehicle_id;
  if s.booking_id is null then return; end if;
  select coalesce(sum(li.amount_cents), 0) into v_planned from booking_line_items li
   where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter
     and li.charge_type in ('rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount');
  v_base := case when v_planned > 0 then round(b.partner_sheet_rental_cents::numeric * greatest(s.rental_charge_cents, 0) / v_planned)::bigint else 0 end;
  v_rev := v_base + s.mileage_overage_cents;
  v_share := public.calc_bps(v_rev, b.partner_cut_bps);
  v_pay := v_rev - v_share;
  if s.owner_statement_id is null then
    update booking_splits set partner_rate_basis = true, partner_sheet_cents = v_base,
           partner_markup_cents = rental_charge_cents + mileage_overage_cents - kickback_cents - v_rev,
           owner_revenue_cents = v_rev, company_share_bps = b.partner_cut_bps, company_share_cents = v_share, owner_payout_cents = v_pay
     where booking_id = p_booking and vehicle_id = s.vehicle_id;
  elsif s.partner_rate_basis then
    -- already on a statement: 0058's share of a later refund was worked out on the renter's price; the partner's is
    -- worked out on the sheet amount instead
    delete from owner_deductions where booking_id = p_booking and vehicle_id = s.vehicle_id and kind in ('refund_share', 'chargeback_share')
       and status = 'open' and not (id = any (v_before));
    select coalesce(sum(amount_cents), 0) into v_prior from owner_deductions
     where booking_id = p_booking and vehicle_id = s.vehicle_id and kind in ('refund_share', 'chargeback_share') and status <> 'waived';
    v_delta := s.owner_payout_cents - v_pay - v_prior;
    if v_delta > 0 then
      insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, booking_id)
      values (s.owner_id, s.vehicle_id, case when s.chargeback_cents > 0 then 'chargeback_share' else 'refund_share' end,
              format('Booking %s: the partner''s share of a later %s (on the sheet rate)', b.booking_number,
                     case when s.chargeback_cents > 0 then 'chargeback' else 'refund' end),
              v_delta, app.today(), p_booking);
    end if;
  end if;
end $$;

-- The partner's statement shows the sheet amount as the rental, the cut and the payout; never the renter's price.
alter function app.build_owner_statement(uuid, date, uuid) rename to build_owner_statement_pre0093;
create or replace function app.build_owner_statement(p_owner uuid, p_month date, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := app.build_owner_statement_pre0093(p_owner, p_month, p_by);
begin
  if v_id is null then return v_id; end if;
  update owner_statement_lines l
     set rental_charge_cents = s.partner_sheet_cents, kickback_cents = 0, partner_sheet_cents = s.partner_sheet_cents, partner_cut_bps = s.company_share_bps,
         description = l.description || format(': at your sheet rate %s, CarmaCars %s', app.fmt_money(s.partner_sheet_cents), app.fmt_pct(s.company_share_bps))
    from booking_splits s
   where l.owner_statement_id = v_id and l.line_type = 'rental' and s.booking_id = l.booking_id and s.vehicle_id = l.vehicle_id and s.partner_rate_basis;
  return v_id;
end $$;

-- ================================================================ 6. a year that is approximate
-- The car's name, its web address and the facts its text is written from leave the year out until it is confirmed.
select pg_temp.patch_fn('app.vehicle_name(uuid)'::regprocedure,
  $o$concat_ws(' ', v.year::text, v.make$o$,
  $n$concat_ws(' ', case when not v.year_approximate then v.year::text end, v.make$n$);
select pg_temp.patch_fn('app.listing_slug(uuid)'::regprocedure,
  $o$v.year::text$o$, $n$case when not v.year_approximate then v.year::text end$n$);
select pg_temp.patch_fn('app.car_copy_facts_of(uuid, jsonb)'::regprocedure,
  $o$  f := f #- '{place,area}';$o$,
  $n$  f := f #- '{place,area}';
  if coalesce((select v0.year_approximate from vehicles v0 where v0.id = p_vehicle), false) then f := f #- '{car,year}'; end if;   -- 0093$n$);

select pg_temp.patch_fn('app.vehicle_studio_photos(uuid)'::regprocedure,
  $o$concat_ws(' ', v.year::text, v.make, v.model), s.view)$o$,
  $n$concat_ws(' ', case when not v.year_approximate then v.year::text end, v.make, v.model), s.view)$n$);
-- The offer (with the rental agreement after it) names the car with its year: staff confirm the year first.
select pg_temp.patch_fn('app.send_offer(uuid, uuid, text, timestamptz)'::regprocedure,
  $o$  select * into v from vehicles where id = b.vehicle_id;$o$,
  $n$  select * into v from vehicles where id = b.vehicle_id;
  if v.year_approximate and b.booking_type::text <> 'owner' then
    raise exception 'Confirm the model year of the % first (Admin > Partners, the car''s Edit): the offer and the agreement name it', app.vehicle_name(v.id) using errcode = '23514';
  end if;$n$);

-- The public row of a car (fleet, car page, model pages, the chat's facts): the 3+ day and 7+ day rates, the two
-- flags, the year left out when approximate, and whether the rates are a partner's guideline rates.
alter function app.public_listing_row(uuid) rename to public_listing_row_pre0093;
create or replace function app.public_listing_row(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when x is null then null else
    x || jsonb_build_object(
      'year', case when v.year_approximate then null else to_jsonb(v.year) end,
      'year_approximate', v.year_approximate,
      'insurance_included', v.insurance_included,
      'no_credit_card', v.no_credit_card,
      'guideline_rates', app.partner_rate_basis(v.id),
      'multi_day_rate_cents', rc.multi_day_rate_cents,
      'long_term_rate_cents', case when rc.multi_day_rate_cents is not null then round(rc.weekly_rate_cents / 7.0)::bigint end) end
    from (select app.public_listing_row_pre0093(p_vehicle) as x) q
    join vehicles v on v.id = p_vehicle
    left join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
$$;

-- ================================================================ 7. the partner's rates in Admin
-- The renter's rate card from a car's sheet rates and markup: the 1-2 day rate is the daily and weekend rate, the 3+
-- day rate the multi-day rate, the 7+ day rate a day the weekly (7 days) and monthly (30 days) rates. The deposit,
-- kilometres, delivery and pickup of the current card are kept. Nothing changes when the card already says so.
create or replace function app.partner_rates_apply(p_vehicle uuid, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r partner_rates;
  rc rate_cards;
  m integer := app.partner_markup_bps(p_vehicle);
  d bigint; mu bigint; l bigint;
  v_id uuid;
  v_src text;
begin
  select * into r from partner_rates where vehicle_id = p_vehicle;
  if r.vehicle_id is null then return null; end if;
  d := app.partner_renter_cents(r.base_cents, m);
  mu := least(app.partner_renter_cents(r.multi_day_cents, m), d);
  l := app.partner_renter_cents(r.long_term_cents, m);
  select * into rc from rate_cards x where x.vehicle_id = p_vehicle and x.effective_from <= now() and (x.effective_to is null or x.effective_to > now());
  if rc.id is not null and rc.daily_rate_cents = d and rc.weekend_rate_cents = d and rc.weekly_rate_cents = l * 7 and rc.monthly_rate_cents = l * 30
     and rc.multi_day_rate_cents is not distinct from mu then
    return rc.id;
  end if;
  v_id := app.set_rate_card(p_vehicle, d, d, l * 7, l * 30, now(), p_by,
    case when rc.id is null then jsonb_build_object('km_mode', 'default')
         else jsonb_build_object('km_mode', 'custom', 'km_allowance_per_day', rc.km_allowance_per_day, 'overage_cents_per_km', rc.overage_cents_per_km,
                                 'deposit_cents', rc.deposit_cents, 'delivery_fee_cents', rc.delivery_fee_cents, 'pickup_fee_cents', rc.pickup_fee_cents) end);
  v_src := format('The partner''s sheet rate plus %s, to the nearest dollar', app.fmt_pct(m));
  update rate_cards set multi_day_rate_cents = mu,
         auto_defaults = auto_defaults || jsonb_build_object(
           'daily', jsonb_build_object('value', d, 'source', v_src || ' (1 to 2 days)'),
           'weekend', jsonb_build_object('value', d, 'source', 'The daily rate (the partner''s sheet has no weekend rate)'),
           'weekly', jsonb_build_object('value', l * 7, 'source', v_src || ' (7 or more days), for 7 days'),
           'monthly', jsonb_build_object('value', l * 30, 'source', v_src || ' (7 or more days), for 30 days'))
   where id = v_id;
  return v_id;
end $$;

-- The partner's pricing (Admin): the markup and the commission (empty: Program settings) and the basis. Every car's
-- renter rates follow.
create or replace function app.partner_pricing_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  pr partners;
  c record;
  v_mk integer := nullif(p ->> 'markup_bps', '')::integer;
  v_cm integer := nullif(p ->> 'commission_bps', '')::integer;
begin
  perform app.assert_admin(p_by);
  select * into pr from partners where id = nullif(p ->> 'id', '')::uuid for update;
  if pr.id is null then raise exception 'Partner not found' using errcode = 'P0002'; end if;
  if v_mk is not null and (v_mk < 0 or v_mk > 20000) then raise exception 'The markup is between 0%% and 200%%' using errcode = '22023'; end if;
  if v_cm is not null and (v_cm < 0 or v_cm > 10000) then raise exception 'The commission is between 0%% and 100%%' using errcode = '22023'; end if;
  if coalesce(p ->> 'payout_basis', pr.payout_basis) not in ('renter_price', 'partner_rate') then raise exception 'Unknown basis' using errcode = '22023'; end if;
  update partners set markup_bps = case when p ? 'markup_bps' then v_mk else markup_bps end,
         commission_bps = case when p ? 'commission_bps' then v_cm else commission_bps end,
         payout_basis = coalesce(nullif(p ->> 'payout_basis', ''), payout_basis)
   where id = pr.id returning * into pr;
  for c in select v.id from vehicles v join partner_rates r on r.vehicle_id = v.id where v.partner_id = pr.id and v.retired_at is null loop
    perform app.partner_rates_apply(c.id, p_by);
  end loop;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'partner_pricing', 'partners', pr.id::text, jsonb_build_object('markup_bps', pr.markup_bps, 'commission_bps', pr.commission_bps, 'payout_basis', pr.payout_basis));
  return app.partner_row(pr);
end $$;

-- One partner car (Admin): its sheet rates, its own markup and commission (empty: the partner's), the two flags, the
-- year (and whether it is still approximate). The renter's rates follow the sheet rates.
create or replace function app.partner_car_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  r partner_rates;
  v_b bigint := nullif(p ->> 'base_cents', '')::bigint;
  v_m bigint := nullif(p ->> 'multi_day_cents', '')::bigint;
  v_l bigint := nullif(p ->> 'long_term_cents', '')::bigint;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for update;
  if v.id is null or v.supply_type <> 'partner' then raise exception 'Choose a partner car' using errcode = '22023'; end if;
  select * into r from partner_rates where vehicle_id = v.id;
  v_b := coalesce(v_b, r.base_cents); v_m := coalesce(v_m, r.multi_day_cents, v_b); v_l := coalesce(v_l, r.long_term_cents, v_m);
  if v_b is null or v_b <= 0 or v_m <= 0 or v_l <= 0 then raise exception 'Enter the partner''s three rates a day (1 to 2 days, 3 or more, 7 or more)' using errcode = '22023'; end if;
  if v_m > v_b or v_l > v_m then raise exception 'The rate a day goes down with the length: 1 to 2 days, then 3 or more, then 7 or more' using errcode = '22023'; end if;
  if (p ? 'markup_bps') and nullif(p ->> 'markup_bps', '')::integer not between 0 and 20000 then raise exception 'The markup is between 0%% and 200%%' using errcode = '22023'; end if;
  if (p ? 'commission_bps') and nullif(p ->> 'commission_bps', '')::integer not between 0 and 10000 then raise exception 'The commission is between 0%% and 100%%' using errcode = '22023'; end if;
  if nullif(p ->> 'year', '') is not null and (p ->> 'year')::integer not between 1980 and 2100 then raise exception 'Enter the model year' using errcode = '22023'; end if;
  insert into partner_rates (vehicle_id, base_cents, multi_day_cents, long_term_cents, source, updated_by)
  values (v.id, v_b, v_m, v_l, coalesce(nullif(p ->> 'source', ''), 'Admin'), p_by)
  on conflict (vehicle_id) do update set base_cents = excluded.base_cents, multi_day_cents = excluded.multi_day_cents, long_term_cents = excluded.long_term_cents,
    source = excluded.source, updated_by = excluded.updated_by;
  update vehicles set partner_markup_bps = case when p ? 'markup_bps' then nullif(p ->> 'markup_bps', '')::integer else partner_markup_bps end,
         commission_bps = case when p ? 'commission_bps' then nullif(p ->> 'commission_bps', '')::integer else commission_bps end,
         insurance_included = coalesce((p ->> 'insurance_included')::boolean, insurance_included),
         no_credit_card = coalesce((p ->> 'no_credit_card')::boolean, no_credit_card),
         year = coalesce(nullif(p ->> 'year', '')::smallint, year),
         year_approximate = case when nullif(p ->> 'year', '') is not null and not (p ? 'year_approximate') then false
                                 else coalesce((p ->> 'year_approximate')::boolean, year_approximate) end
   where id = v.id;
  perform app.partner_rates_apply(v.id, p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'partner_car_save', 'vehicles', v.id::text, p - 'vehicle_id');
  return app.partner_car_row(v.id);
end $$;

create or replace function app.partner_car_row(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'sheet_name', v.partner_sheet_name, 'plate', v.plate, 'vin', v.vin,
    'status', v.status, 'retired_at', v.retired_at, 'year', v.year, 'year_approximate', v.year_approximate,
    'commission_bps', v.commission_bps, 'commission_effective_bps', app.partner_commission_bps(v.id),
    'markup_bps', v.partner_markup_bps, 'markup_effective_bps', app.partner_markup_bps(v.id),
    'insurance_included', v.insurance_included, 'no_credit_card', v.no_credit_card,
    'base_cents', r.base_cents, 'multi_day_cents', r.multi_day_cents, 'long_term_cents', r.long_term_cents,
    'renter_daily_cents', rc.daily_rate_cents, 'renter_multi_day_cents', rc.multi_day_rate_cents,
    'renter_long_term_cents', case when rc.weekly_rate_cents is not null then round(rc.weekly_rate_cents / 7.0)::bigint end,
    'listing_status', l.status, 'slug', l.slug, 'real_photos', exists (select 1 from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status <> 'rejected'))
    from vehicles v
    left join partner_rates r on r.vehicle_id = v.id
    left join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
    left join vehicle_listings l on l.vehicle_id = v.id
   where v.id = p_vehicle
$$;

-- Admin > Partners > a partner: its pricing, and each car with its sheet rates and the renter's.
alter function app.partner_detail(uuid, uuid) rename to partner_detail_pre0093;
create or replace function app.partner_detail(p_by uuid, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  d jsonb := app.partner_detail_pre0093(p_by, p_id);
  pr partners;
begin
  if d is null then return d; end if;
  select * into pr from partners where id = p_id;
  return d || jsonb_build_object(
    'markup_bps', pr.markup_bps, 'markup_effective_bps', coalesce(pr.markup_bps, (app.settings()).partner_markup_bps), 'payout_basis', pr.payout_basis,
    'cars', coalesce((select jsonb_agg(app.partner_car_row(v.id) order by v.partner_sheet_name nulls last, v.make, v.model) from vehicles v where v.partner_id = p_id), '[]'::jsonb),
    'chauffeur', coalesce((select jsonb_agg(app.chauffeur_vehicle_row(c) order by c.sort_order) from chauffeur_vehicles c where c.partner_id = p_id), '[]'::jsonb));
end $$;

-- ================================================================ 8. the chauffeur service
create table if not exists chauffeur_vehicles (
  id                 uuid primary key default gen_random_uuid(),
  partner_id         uuid references partners (id),
  sheet_name         text,
  name               text not null check (length(btrim(name)) between 2 and 120),
  slug               text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  kind               text not null check (kind in ('chauffeur_only', 'chauffeur_rental')),
  passengers         integer not null check (passengers between 1 and 20),
  rental_vehicle_ids uuid[] not null default '{}',
  sheet_2h_cents     bigint not null check (sheet_2h_cents > 0),
  sheet_3plus_cents  bigint not null check (sheet_3plus_cents > 0),
  markup_bps         integer check (markup_bps between 0 and 20000),
  cut_bps            integer check (cut_bps between 0 and 10000),
  active             boolean not null default true,
  sort_order         integer not null default 100,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create unique index if not exists chauffeur_vehicles_sheet on chauffeur_vehicles (partner_id, lower(sheet_name)) where sheet_name is not null;
create trigger chauffeur_vehicles_updated before update on chauffeur_vehicles for each row execute function app.set_updated_at();
create trigger audit_chauffeur_vehicles after insert or update or delete on chauffeur_vehicles for each row execute function app.audit_row();
comment on table chauffeur_vehicles is 'A vehicle of the chauffeur service (0093): its partner, the sheet''s rates a hour for 2 hours and for 3 or more, chauffeur only or also a rental (the rental cars it is)';

create sequence if not exists chauffeur_request_seq start 1001;
create table if not exists chauffeur_requests (
  id                   uuid primary key default gen_random_uuid(),
  reference            text not null unique default ('CH-' || nextval('chauffeur_request_seq')),
  lead_id              uuid references leads (id) on delete set null,
  chauffeur_vehicle_id uuid not null references chauffeur_vehicles (id),
  service_date         date not null,
  start_time           time not null,
  hours                integer not null check (hours between 2 and 24),
  pickup_address       text not null check (length(btrim(pickup_address)) between 3 and 300),
  dropoff_address      text check (length(dropoff_address) <= 300),
  passengers           integer not null check (passengers between 1 and 20),
  occasion             text check (length(occasion) <= 80),
  notes                text check (length(notes) <= 2000),
  name                 text not null,
  email                text,
  phone                text,
  status               text not null default 'new' check (status in ('new', 'quoted', 'confirmed', 'completed', 'cancelled', 'declined')),
  rate_cents           bigint not null,
  renter_cents         bigint not null,
  hst_cents            bigint not null,
  total_cents          bigint not null,
  sheet_cents          bigint not null,
  cut_bps              integer not null,
  markup_bps           integer not null,
  partner_payout_cents bigint not null,
  carmacars_keep_cents bigint not null,
  quote_note           text,
  staff_note           text,
  request_key          text unique,
  handled_by           uuid references users (id),
  quoted_at            timestamptz,
  confirmed_at         timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  check (email is not null or phone is not null)
);
create index if not exists chauffeur_requests_status on chauffeur_requests (status, service_date);
create trigger chauffeur_requests_updated before update on chauffeur_requests for each row execute function app.set_updated_at();
create trigger audit_chauffeur_requests after insert or update or delete on chauffeur_requests for each row execute function app.audit_row();
comment on table chauffeur_requests is 'A chauffeur booking request (0093): the lead of kind chauffeur, its quote (hours at the 2-hour or 3+ hour rate, marked up, with HST) and what the partner is owed; staff quote and confirm it';

alter table chauffeur_vehicles enable row level security;
alter table chauffeur_requests enable row level security;
create policy admin_all on chauffeur_vehicles for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on chauffeur_requests for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy va_read on chauffeur_requests for select to authenticated using (app.va_has('cs', 'sales'));

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('chauffeur_request', 'cs', 'Quote a chauffeur request', 'high', 'opening_minutes', 30,
   'A visitor asked for the chauffeur service: confirm the vehicle and driver are free with the partner, then send the quote and confirm')
on conflict (task_type) do update set queue = excluded.queue, title = excluded.title, priority = excluded.priority,
  due_kind = excluded.due_kind, due_amount = excluded.due_amount, description = excluded.description;

-- The rates of a chauffeur vehicle for the renter: the sheet's rates marked up (its own markup, its partner's, Program
-- settings), and the cut (its own, its partner's commission, Program settings).
create or replace function app.chauffeur_vehicle_row(c chauffeur_vehicles) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', c.id, 'name', c.name, 'slug', c.slug, 'kind', c.kind, 'passengers', c.passengers, 'active', c.active, 'sort_order', c.sort_order,
    'sheet_name', c.sheet_name, 'sheet_2h_cents', c.sheet_2h_cents, 'sheet_3plus_cents', c.sheet_3plus_cents, 'markup_bps', c.markup_bps, 'cut_bps', c.cut_bps,
    'markup_effective_bps', m.mk, 'cut_effective_bps', m.cut,
    'rate_2h_cents', app.partner_renter_cents(c.sheet_2h_cents, m.mk), 'rate_3plus_cents', app.partner_renter_cents(c.sheet_3plus_cents, m.mk),
    'rentals', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'path', case when l.status = 'published' then '/cars/' || l.slug end) order by v.partner_sheet_name)
                          from vehicles v left join vehicle_listings l on l.vehicle_id = v.id where v.id = any (c.rental_vehicle_ids) and v.retired_at is null), '[]'::jsonb))
    from (select coalesce(c.markup_bps, p.markup_bps, (app.settings()).partner_markup_bps) as mk,
                 coalesce(c.cut_bps, p.commission_bps, (app.settings()).partner_commission_bps) as cut
            from (select 1) one left join partners p on p.id = c.partner_id) m
$$;

-- A quote: at least 2 hours; exactly 2 at the 2-hour rate, 3 or more at the 3+ hour rate, a hour; HST on top. The same
-- rule is chauffeurCharge in web/src/features/partner/fleet-01-motors.ts.
create or replace function app.chauffeur_quote(p_vehicle uuid, p_hours integer) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  c chauffeur_vehicles;
  r jsonb;
  v_rate bigint; v_sheet_rate bigint; v_renter bigint; v_sheet bigint; v_hst bigint; v_cut bigint;
begin
  select * into c from chauffeur_vehicles where id = p_vehicle;
  if c.id is null then raise exception 'Choose a vehicle' using errcode = '22023'; end if;
  if p_hours is null or p_hours < 2 or p_hours > 24 then raise exception 'Book 2 to 24 hours' using errcode = '22023'; end if;
  r := app.chauffeur_vehicle_row(c);
  v_rate := case when p_hours = 2 then (r ->> 'rate_2h_cents')::bigint else (r ->> 'rate_3plus_cents')::bigint end;
  v_sheet_rate := case when p_hours = 2 then c.sheet_2h_cents else c.sheet_3plus_cents end;
  v_renter := v_rate * p_hours;
  v_sheet := v_sheet_rate * p_hours;
  v_cut := public.calc_bps(v_sheet, (r ->> 'cut_effective_bps')::integer);
  v_hst := public.calc_hst(v_renter, (app.settings()).hst_bps);
  return jsonb_build_object('vehicle_id', c.id, 'vehicle', c.name, 'hours', p_hours, 'rate_cents', v_rate, 'renter_cents', v_renter,
    'hst_cents', v_hst, 'total_cents', v_renter + v_hst, 'sheet_cents', v_sheet, 'cut_bps', (r ->> 'cut_effective_bps')::integer,
    'markup_bps', (r ->> 'markup_effective_bps')::integer, 'cut_cents', v_cut, 'partner_payout_cents', v_sheet - v_cut,
    'carmacars_keep_cents', v_renter - (v_sheet - v_cut),
    'line', format('Chauffeur service, %s: %s hours at %s an hour', c.name, p_hours, app.fmt_money(v_rate)));
end $$;

-- The public page: every active vehicle with the renter's hourly rates.
create or replace function public.chauffeur_services() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('vehicles', coalesce((select jsonb_agg(app.chauffeur_vehicle_row(c) - array['sheet_name', 'sheet_2h_cents', 'sheet_3plus_cents', 'markup_bps', 'cut_bps', 'markup_effective_bps', 'cut_effective_bps']
                                                                  order by c.sort_order, c.name) from chauffeur_vehicles c where c.active), '[]'::jsonb),
                            'hst_bps', (app.settings()).hst_bps, 'min_hours', 2, 'max_hours', 24)
$$;

-- The public request (the server calls it after its bot check): validated, limited per address, the lead of kind
-- chauffeur, the request with its quote, a task for customer service. The same browser key twice is one request.
create or replace function public.submit_chauffeur_request(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c chauffeur_vehicles;
  q jsonb;
  v_key text := nullif(left(p ->> 'request_key', 80), '');
  x chauffeur_requests;
  v_lead uuid;
  v_name text := nullif(left(btrim(coalesce(p ->> 'name', '')), 120), '');
  v_email text := lower(nullif(btrim(coalesce(p ->> 'email', '')), ''));
  v_phone text := nullif(left(btrim(coalesce(p ->> 'phone', '')), 40), '');
  v_date date;
  v_time time;
  v_hours integer;
  v_pax integer;
  v_err jsonb := '{}'::jsonb;
begin
  if v_key is not null then
    select * into x from chauffeur_requests where request_key = v_key;
    if x.id is not null then return jsonb_build_object('ok', true, 'reference', x.reference, 'created', false); end if;
  end if;
  if p_ip is not null and not app.rate_limit('chauffeur:' || p_ip, 5, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  select * into c from chauffeur_vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid and active;
  begin v_date := (p ->> 'date')::date; exception when others then v_date := null; end;
  begin v_time := (p ->> 'start_time')::time; exception when others then v_time := null; end;
  v_hours := case when (p ->> 'hours') ~ '^\d{1,2}$' then (p ->> 'hours')::integer end;
  v_pax := case when (p ->> 'passengers') ~ '^\d{1,2}$' then (p ->> 'passengers')::integer end;
  if c.id is null then v_err := v_err || jsonb_build_object('vehicle_id', 'Choose a vehicle.'); end if;
  if v_date is null or v_date < app.today() then v_err := v_err || jsonb_build_object('date', 'Choose a date from today on.'); end if;
  if v_date > app.today() + 365 then v_err := v_err || jsonb_build_object('date', 'Choose a date within a year.'); end if;
  if v_time is null then v_err := v_err || jsonb_build_object('start_time', 'Choose the start time.'); end if;
  if v_hours is null or v_hours < 2 or v_hours > 24 then v_err := v_err || jsonb_build_object('hours', 'Book at least 2 hours (24 at most).'); end if;
  if length(btrim(coalesce(p ->> 'pickup_address', ''))) < 3 then v_err := v_err || jsonb_build_object('pickup_address', 'Enter the pickup address.'); end if;
  if v_pax is null or v_pax < 1 then v_err := v_err || jsonb_build_object('passengers', 'Enter the number of passengers.');
  elsif c.id is not null and v_pax > c.passengers then v_err := v_err || jsonb_build_object('passengers', format('The %s seats %s passengers.', c.name, c.passengers)); end if;
  if v_name is null or length(v_name) < 2 then v_err := v_err || jsonb_build_object('name', 'Enter your name.'); end if;
  if v_email is null and v_phone is null then v_err := v_err || jsonb_build_object('email', 'Give an email address or a phone number.'); end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_err := v_err || jsonb_build_object('email', 'Enter a valid email address.'); end if;
  if v_err <> '{}'::jsonb then return jsonb_build_object('ok', false, 'error', 'invalid', 'fields', v_err); end if;
  q := app.chauffeur_quote(c.id, v_hours);
  insert into leads (kind, name, email, phone, message, payload, source, source_url)
  values ('chauffeur', v_name, v_email, v_phone, left(p ->> 'notes', 1000),
          jsonb_strip_nulls(jsonb_build_object('vehicle', c.name, 'chauffeur_vehicle_id', c.id, 'date', v_date, 'start_time', to_char(v_time, 'HH24:MI'), 'hours', v_hours,
            'pickup_address', left(btrim(p ->> 'pickup_address'), 300), 'dropoff_address', nullif(left(btrim(coalesce(p ->> 'dropoff_address', '')), 300), ''),
            'passengers', v_pax, 'occasion', nullif(left(btrim(coalesce(p ->> 'occasion', '')), 80), ''), 'quote', q - array['sheet_cents', 'cut_bps', 'markup_bps', 'cut_cents', 'partner_payout_cents', 'carmacars_keep_cents'])),
          'web', nullif(left(p ->> 'source_url', 500), ''))
  returning id into v_lead;
  insert into chauffeur_requests (lead_id, chauffeur_vehicle_id, service_date, start_time, hours, pickup_address, dropoff_address, passengers, occasion, notes,
                                  name, email, phone, rate_cents, renter_cents, hst_cents, total_cents, sheet_cents, cut_bps, markup_bps,
                                  partner_payout_cents, carmacars_keep_cents, request_key)
  values (v_lead, c.id, v_date, v_time, v_hours, left(btrim(p ->> 'pickup_address'), 300), nullif(left(btrim(coalesce(p ->> 'dropoff_address', '')), 300), ''),
          v_pax, nullif(left(btrim(coalesce(p ->> 'occasion', '')), 80), ''), nullif(left(btrim(coalesce(p ->> 'notes', '')), 2000), ''),
          v_name, v_email, v_phone, (q ->> 'rate_cents')::bigint, (q ->> 'renter_cents')::bigint, (q ->> 'hst_cents')::bigint, (q ->> 'total_cents')::bigint,
          (q ->> 'sheet_cents')::bigint, (q ->> 'cut_bps')::integer, (q ->> 'markup_bps')::integer, (q ->> 'partner_payout_cents')::bigint,
          (q ->> 'carmacars_keep_cents')::bigint, v_key)
  returning * into x;
  update leads set payload = payload || jsonb_build_object('reference', x.reference, 'chauffeur_request_id', x.id) where id = v_lead;
  perform app.raise_task(p_type => 'chauffeur_request', p_queue => 'cs', p_due_at => app.task_due('first_reply', null),
    p_title => left(format('Chauffeur request %s: %s, %s for %s hours', x.reference, c.name, app.fmt_day(v_date), v_hours), 200),
    p_detail => format('%s (%s) asked for the %s on %s at %s for %s hours, %s passengers, from %s%s. Quote: %s plus HST. Check the vehicle and driver with the partner, then quote and confirm in Admin > Chauffeur.',
                       v_name, concat_ws(', ', v_email, v_phone), c.name, app.fmt_day(v_date), to_char(v_time, 'HH24:MI'), v_hours, v_pax, x.pickup_address,
                       coalesce(' to ' || x.dropoff_address, ''), app.fmt_money(x.renter_cents)),
    p_related_table => 'chauffeur_requests', p_related_id => x.id, p_dedupe => 'chauffeur:' || x.id);
  return jsonb_build_object('ok', true, 'reference', x.reference, 'created', true, 'quote', q - array['sheet_cents', 'cut_bps', 'markup_bps', 'cut_cents', 'partner_payout_cents', 'carmacars_keep_cents']);
end $$;

create or replace function app.chauffeur_assert(p_by uuid) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_by is null or not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'sales')) then
    raise exception 'Not permitted: chauffeur requests are handled by an Admin, customer service or Sales' using errcode = '42501';
  end if;
end $$;

-- Admin > Chauffeur: the requests (newest service date first among the open ones), each with its quote and what the
-- partner is owed, and the counts.
create or replace function app.chauffeur_requests_list(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_status text := nullif(p ->> 'status', '');
begin
  perform app.chauffeur_assert(p_by);
  return jsonb_build_object(
    'rows', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('vehicle', c.name, 'vehicle_kind', c.kind, 'line',
                                format('Chauffeur service, %s: %s hours at %s an hour', c.name, r.hours, app.fmt_money(r.rate_cents)))
                                order by (r.status in ('new', 'quoted', 'confirmed')) desc, r.service_date, r.start_time)
                       from chauffeur_requests r join chauffeur_vehicles c on c.id = r.chauffeur_vehicle_id
                      where v_status is null or r.status = v_status), '[]'::jsonb),
    'counts', (select jsonb_object_agg(s, (select count(*) from chauffeur_requests x where x.status = s))
                 from unnest(array['new', 'quoted', 'confirmed', 'completed', 'cancelled', 'declined']) s),
    'today', coalesce((select jsonb_agg(jsonb_build_object('reference', r.reference, 'start_time', to_char(r.start_time, 'HH24:MI'), 'vehicle', c.name, 'name', r.name, 'hours', r.hours) order by r.start_time)
                         from chauffeur_requests r join chauffeur_vehicles c on c.id = r.chauffeur_vehicle_id
                        where r.service_date = app.today() and r.status = 'confirmed'), '[]'::jsonb),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.sort_order) from chauffeur_vehicles c where c.active), '[]'::jsonb));
end $$;

-- A request moved on by staff: the vehicle or the hours (the quote is made again), quoted (the quote note says how it
-- was sent), confirmed, completed, cancelled or declined; the staff note. The task closes once it is quoted or closed.
create or replace function app.chauffeur_request_update(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x chauffeur_requests;
  q jsonb;
  v_status text := nullif(p ->> 'status', '');
  v_vehicle uuid;
  v_hours integer;
begin
  perform app.chauffeur_assert(p_by);
  select * into x from chauffeur_requests where id = nullif(p ->> 'id', '')::uuid for update;
  if x.id is null then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if v_status is not null and v_status not in ('new', 'quoted', 'confirmed', 'completed', 'cancelled', 'declined') then raise exception 'Unknown status' using errcode = '22023'; end if;
  if x.status in ('completed', 'cancelled', 'declined') and v_status is not null and v_status <> x.status then
    raise exception 'This request is closed (%)', x.status using errcode = '23514';
  end if;
  v_vehicle := coalesce(nullif(p ->> 'vehicle_id', '')::uuid, x.chauffeur_vehicle_id);
  v_hours := coalesce(nullif(p ->> 'hours', '')::integer, x.hours);
  if v_vehicle <> x.chauffeur_vehicle_id or v_hours <> x.hours then
    q := app.chauffeur_quote(v_vehicle, v_hours);
    update chauffeur_requests set chauffeur_vehicle_id = v_vehicle, hours = v_hours, rate_cents = (q ->> 'rate_cents')::bigint, renter_cents = (q ->> 'renter_cents')::bigint,
           hst_cents = (q ->> 'hst_cents')::bigint, total_cents = (q ->> 'total_cents')::bigint, sheet_cents = (q ->> 'sheet_cents')::bigint,
           cut_bps = (q ->> 'cut_bps')::integer, markup_bps = (q ->> 'markup_bps')::integer, partner_payout_cents = (q ->> 'partner_payout_cents')::bigint,
           carmacars_keep_cents = (q ->> 'carmacars_keep_cents')::bigint
     where id = x.id;
  end if;
  update chauffeur_requests set status = coalesce(v_status, status), handled_by = p_by,
         quote_note = case when p ? 'quote_note' then nullif(btrim(p ->> 'quote_note'), '') else quote_note end,
         staff_note = case when p ? 'staff_note' then nullif(btrim(p ->> 'staff_note'), '') else staff_note end,
         quoted_at = case when v_status = 'quoted' then coalesce(quoted_at, now()) else quoted_at end,
         confirmed_at = case when v_status = 'confirmed' then coalesce(confirmed_at, now()) else confirmed_at end
   where id = x.id returning * into x;
  if x.status <> 'new' then
    update tasks set status = 'done', completed_at = now(), completion_note = coalesce(completion_note, 'Chauffeur request ' || x.status)
     where related_table = 'chauffeur_requests' and related_id = x.id and status in ('open', 'in_progress', 'waiting');
  end if;
  if x.lead_id is not null then
    update leads set status = case x.status when 'new' then 'new' when 'quoted' then 'contacted' when 'confirmed' then 'converted' when 'completed' then 'converted'
                                            when 'declined' then 'closed' else 'closed' end
     where id = x.lead_id;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'chauffeur_request_update', 'chauffeur_requests', x.id::text, jsonb_build_object('status', x.status, 'hours', x.hours, 'vehicle', x.chauffeur_vehicle_id));
  return to_jsonb(x);
end $$;

-- A chauffeur vehicle (Admin): its rates, markup and cut, active.
create or replace function app.chauffeur_vehicle_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c chauffeur_vehicles;
begin
  perform app.assert_admin(p_by);
  update chauffeur_vehicles set
         sheet_2h_cents = coalesce(nullif(p ->> 'sheet_2h_cents', '')::bigint, sheet_2h_cents),
         sheet_3plus_cents = coalesce(nullif(p ->> 'sheet_3plus_cents', '')::bigint, sheet_3plus_cents),
         markup_bps = case when p ? 'markup_bps' then nullif(p ->> 'markup_bps', '')::integer else markup_bps end,
         cut_bps = case when p ? 'cut_bps' then nullif(p ->> 'cut_bps', '')::integer else cut_bps end,
         passengers = coalesce(nullif(p ->> 'passengers', '')::integer, passengers),
         active = coalesce((p ->> 'active')::boolean, active)
   where id = nullif(p ->> 'id', '')::uuid returning * into c;
  if c.id is null then raise exception 'Chauffeur vehicle not found' using errcode = 'P0002'; end if;
  return app.chauffeur_vehicle_row(c);
end $$;

-- ================================================================ 9. the door, To do
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0093;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('ops_read', 'admin_read', 'va_read') and p_name = 'chauffeur_requests')
     or (p_call in ('ops_do', 'admin_do', 'va_do') and p_name in ('chauffeur_request_update', 'chauffeur_vehicle_save', 'partner_pricing_save', 'partner_car_save')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p_ := p_ - '_va';
    return case p_name
      when 'chauffeur_requests' then app.chauffeur_requests_list(p_user, p_)
      when 'chauffeur_request_update' then app.chauffeur_request_update(p_user, p_)
      when 'chauffeur_vehicle_save' then app.chauffeur_vehicle_save(p_user, p_)
      when 'partner_pricing_save' then app.partner_pricing_save(p_user, p_)
      else app.partner_car_save(p_user, p_) end;
  end if;
  return app.door_pre0093(p_user, p_aal, p_call, p_name, p);
end $$;

alter function app.admin_todo(uuid) rename to admin_todo_pre0093;
create or replace function app.admin_todo(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_todo_pre0093(p_admin);
  n integer := (select count(*) from chauffeur_requests where status = 'new');
  t jsonb := coalesce((select jsonb_agg(jsonb_build_object('reference', r.reference, 'start_time', to_char(r.start_time, 'HH24:MI'), 'vehicle', c.name, 'name', r.name, 'hours', r.hours) order by r.start_time)
                         from chauffeur_requests r join chauffeur_vehicles c on c.id = r.chauffeur_vehicle_id
                        where r.service_date = app.today() and r.status = 'confirmed'), '[]'::jsonb);
begin
  return jsonb_set(v, '{items}', coalesce(v -> 'items', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
           'key', 'chauffeur', 'count', n, 'label', 'Chauffeur requests to quote', 'href', '/admin/chauffeur', 'button', 'Quote them')))
         || jsonb_build_object('chauffeur_today', t);
end $$;

-- ================================================================ 10. the data: the partner, its cars, its chauffeur vehicles
-- p: {partner: {business_name, commission_bps, markup_bps, notes}, cars: [{sheet, make, model, trim, colour, body, seats, doors,
-- drive, transmission, class, year, included, base, multi, long}], chauffeur: [{sheet, name, slug, kind, passengers,
-- rentals: [sheet names], two_hour, three_plus, sort}]}. Keyed by the partner's name and each sheet row's name: a car or
-- vehicle already on file is left as it is (its rates may have been negotiated since), so a second run adds nothing.
-- Each new car goes through the add path every car takes (0082's after-add and 0087's standard settings: the fleet
-- number, the car code, the listing and its copy), gets the renter's rates from its sheet rates, and is published as
-- requests with the eight studio stand-ins until its own photos are added in Admin.
create or replace function app.partner_fleet_import_0093(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  pr partners;
  v_owner uuid;
  c jsonb;
  v_id uuid;
  v_added integer := 0; v_kept integer := 0; v_ch integer := 0;
  v_pub jsonb;
begin
  select * into pr from partners where lower(business_name) = lower(p #>> '{partner,business_name}');
  if pr.id is null then
    insert into owners (owner_type, legal_name, corporation_name, status, kind)
    values ('corporation', p #>> '{partner,business_name}', p #>> '{partner,business_name}', 'active', 'partner') returning id into v_owner;
    insert into partners (owner_id, business_name, commission_bps, markup_bps, payout_basis, status, notes)
    values (v_owner, p #>> '{partner,business_name}', (p #>> '{partner,commission_bps}')::integer, (p #>> '{partner,markup_bps}')::integer,
            'partner_rate', 'active', p #>> '{partner,notes}')
    returning * into pr;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'partner_create', 'partners', pr.id::text, jsonb_build_object('business_name', pr.business_name, 'by', 'migration 0093'));
  end if;

  for c in select value from jsonb_array_elements(p -> 'cars') loop
    if exists (select 1 from vehicles v where v.partner_id = pr.id and lower(v.partner_sheet_name) = lower(c ->> 'sheet')) then
      v_kept := v_kept + 1;
      continue;
    end if;
    v_id := gen_random_uuid();
    insert into vehicles (id, owner_id, supply_type, partner_id, year, make, model, trim, colour, fuel, vin, plate, class, status, management_mode,
                          enrollment_date, body_type, allows_18_to_20, title_brand_clear, year_approximate, insurance_included, no_credit_card, partner_sheet_name)
    values (v_id, pr.owner_id, 'partner', pr.id, (c ->> 'year')::smallint, c ->> 'make', c ->> 'model', nullif(c ->> 'trim', ''), nullif(c ->> 'colour', ''),
            'gasoline', null, null, (c ->> 'class')::vehicle_class, 'available', 'managed', app.today(), c ->> 'body', false, true, true,
            coalesce((c ->> 'included')::boolean, false), coalesce((c ->> 'included')::boolean, false), c ->> 'sheet');
    insert into partner_rates (vehicle_id, base_cents, multi_day_cents, long_term_cents, source)
    values (v_id, (c ->> 'base')::bigint, (c ->> 'multi')::bigint, (c ->> 'long')::bigint, 'The partner''s price sheet of September 2026 (migration 0093)');
    -- the add path (the class given; drivers 18 to 20 follow Program settings like every car, 0087)
    perform app.vehicle_after_add(v_id, null, jsonb_strip_nulls(jsonb_build_object('class', c ->> 'class', 'colour', nullif(c ->> 'colour', ''))));
    perform app.partner_rates_apply(v_id, null);
    perform app.ensure_listing(v_id);
    update vehicle_listings set seats = (c ->> 'seats')::smallint, doors = (c ->> 'doors')::smallint, transmission = c ->> 'transmission',
           body_style = c ->> 'body', drivetrain = c ->> 'drive',
           spec_sources = spec_sources || jsonb_build_object('seats', 'partner sheet (0093)', 'doors', 'partner sheet (0093)', 'transmission', 'partner sheet (0093)',
                                                             'body_style', 'partner sheet (0093)', 'drivetrain', 'partner sheet (0093)')
     where vehicle_id = v_id;
    perform app.listing_template_copy(v_id);
    v_pub := app.listing_auto_publish(v_id, 'added');
    if not coalesce((v_pub ->> 'published')::boolean, false) then
      insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
      values (null, 'partner_car_not_published', 'vehicles', v_id::text, v_pub);
    end if;
    v_added := v_added + 1;
  end loop;

  for c in select value from jsonb_array_elements(p -> 'chauffeur') loop
    insert into chauffeur_vehicles (partner_id, sheet_name, name, slug, kind, passengers, rental_vehicle_ids, sheet_2h_cents, sheet_3plus_cents, sort_order)
    values (pr.id, c ->> 'sheet', c ->> 'name', c ->> 'slug', c ->> 'kind', (c ->> 'passengers')::integer,
            coalesce((select array_agg(v.id order by v.partner_sheet_name) from vehicles v
                       where v.partner_id = pr.id and lower(v.partner_sheet_name) in (select lower(x) from jsonb_array_elements_text(c -> 'rentals') x)), '{}'),
            (c ->> 'two_hour')::bigint, (c ->> 'three_plus')::bigint, (c ->> 'sort')::integer)
    on conflict (partner_id, lower(sheet_name)) where sheet_name is not null do nothing;
    if found then v_ch := v_ch + 1; end if;
  end loop;
  return jsonb_build_object('partner_id', pr.id, 'cars_added', v_added, 'cars_kept', v_kept, 'chauffeur_added', v_ch);
end $$;

-- FLEET 0093 START (generated by supabase/seed/0093_gen.mjs from web/src/features/partner/fleet-01-motors.ts; do not edit by hand)
select app.partner_fleet_import_0093('{"partner":{"business_name":"01 Motors","commission_bps":2000,"markup_bps":1000,"notes":"Partner rental fleet (October 22, 2026). No portal sign-in yet: staff manage the cars; add an email and invite them from this page later. Rates are the partner''s guideline rates; final pricing may change after insurance review (driver risk, vehicle, use)."},"cars":[{"sheet":"Mercedes A220","make":"Mercedes-Benz","model":"A-Class","trim":"A220","colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic (dual-clutch)","class":"premium","year":2025,"included":false,"base":14000,"multi":12000,"long":10000},
  {"sheet":"Mercedes A35 AMG","make":"Mercedes-Benz","model":"A-Class","trim":"A35 AMG","colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic (dual-clutch)","class":"luxury","year":2025,"included":false,"base":20000,"multi":17500,"long":15000},
  {"sheet":"Mercedes C300 Conv","make":"Mercedes-Benz","model":"C-Class","trim":"C300 Cabriolet","colour":null,"body":"Convertible","seats":4,"doors":2,"drive":"All-wheel drive","transmission":"Automatic","class":"premium","year":2023,"included":false,"base":20000,"multi":17500,"long":14000},
  {"sheet":"Mercedes C300 Sedan Black","make":"Mercedes-Benz","model":"C-Class","trim":"C300","colour":"Black","body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"premium","year":2025,"included":false,"base":20000,"multi":17500,"long":15000},
  {"sheet":"Mercedes C300 Sedan Grey","make":"Mercedes-Benz","model":"C-Class","trim":"C300","colour":"Grey","body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"premium","year":2025,"included":false,"base":17500,"multi":15000,"long":15000},
  {"sheet":"Mercedes C43 AMG Blue","make":"Mercedes-Benz","model":"C-Class","trim":"C43 AMG","colour":"Blue","body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":25000,"multi":22500,"long":20000},
  {"sheet":"Mercedes C43 AMG White","make":"Mercedes-Benz","model":"C-Class","trim":"C43 AMG","colour":"White","body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":25000,"multi":22500,"long":20000},
  {"sheet":"Mercedes C43 AMG Grey","make":"Mercedes-Benz","model":"C-Class","trim":"C43 AMG","colour":"Grey","body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":24000,"multi":20000,"long":18000},
  {"sheet":"Mercedes C63s AMG","make":"Mercedes-Benz","model":"C-Class","trim":"C63 S AMG","colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":40000,"multi":37500,"long":32500},
  {"sheet":"Mercedes E43 AMG","make":"Mercedes-Benz","model":"E-Class","trim":"E43 AMG","colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2020,"included":false,"base":25000,"multi":22500,"long":20000},
  {"sheet":"Mercedes E53 AMG Coupe","make":"Mercedes-Benz","model":"E-Class","trim":"E53 AMG Coupe","colour":null,"body":"Coupe","seats":4,"doors":2,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2023,"included":false,"base":35000,"multi":30000,"long":27500},
  {"sheet":"Mercedes GT53 AMG","make":"Mercedes-Benz","model":"AMG GT","trim":"GT53 4-Door Coupe","colour":null,"body":"Sedan","seats":4,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2024,"included":false,"base":42000,"multi":37500,"long":35000},
  {"sheet":"Mercedes S500","make":"Mercedes-Benz","model":"S-Class","trim":"S500","colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2024,"included":false,"base":45000,"multi":40000,"long":32500},
  {"sheet":"Mercedes S580","make":"Mercedes-Benz","model":"S-Class","trim":"S580","colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":true,"base":60000,"multi":57500,"long":55000},
  {"sheet":"Mercedes S580 Maybach","make":"Mercedes-Benz","model":"S-Class","trim":"Maybach S580","colour":null,"body":"Sedan","seats":4,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":45000,"multi":40000,"long":32500},
  {"sheet":"Mercedes S63 AMG","make":"Mercedes-Benz","model":"S-Class","trim":"S63 AMG","colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":true,"base":70000,"multi":65000,"long":60000},
  {"sheet":"Mercedes GLB250","make":"Mercedes-Benz","model":"GLB","trim":"GLB250","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic (dual-clutch)","class":"premium","year":2025,"included":false,"base":15000,"multi":12000,"long":10000},
  {"sheet":"Mercedes GLB35 AMG","make":"Mercedes-Benz","model":"GLB","trim":"GLB35 AMG","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic (dual-clutch)","class":"luxury","year":2025,"included":false,"base":20000,"multi":17500,"long":15000},
  {"sheet":"Mercedes GLC43 AMG SUV","make":"Mercedes-Benz","model":"GLC","trim":"GLC43 AMG","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":22500,"multi":20000,"long":18000},
  {"sheet":"Mercedes GLC43 AMG Coupe","make":"Mercedes-Benz","model":"GLC","trim":"GLC43 AMG Coupe","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":25000,"multi":22500,"long":20000},
  {"sheet":"Mercedes GLE53 AMG","make":"Mercedes-Benz","model":"GLE","trim":"GLE53 AMG","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":35000,"multi":32500,"long":30000},
  {"sheet":"Mercedes GLE53 AMG Coupe","make":"Mercedes-Benz","model":"GLE","trim":"GLE53 AMG Coupe","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":40000,"multi":40000,"long":40000},
  {"sheet":"Mercedes G63 AMG","make":"Mercedes-Benz","model":"G-Class","trim":"G63 AMG","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"Four-wheel drive","transmission":"Automatic","class":"exotic","year":2025,"included":true,"base":100000,"multi":100000,"long":90000},
  {"sheet":"Mercedes GLS600 Maybach","make":"Mercedes-Benz","model":"GLS","trim":"Maybach GLS600","colour":null,"body":"SUV","seats":4,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"exotic","year":2025,"included":true,"base":150000,"multi":120000,"long":100000},
  {"sheet":"BMW 330i MSport","make":"BMW","model":"3 Series","trim":"330i M Sport","colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"premium","year":2025,"included":false,"base":20000,"multi":17500,"long":12000},
  {"sheet":"BMW M340i","make":"BMW","model":"3 Series","trim":"M340i","colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":25000,"multi":22500,"long":20000},
  {"sheet":"BMW M3 Comp","make":"BMW","model":"M3","trim":"Competition","colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":50000,"multi":47500,"long":40000},
  {"sheet":"BMW 430i MSport","make":"BMW","model":"4 Series","trim":"430i M Sport","colour":null,"body":"Coupe","seats":4,"doors":2,"drive":"All-wheel drive","transmission":"Automatic","class":"premium","year":2025,"included":false,"base":22500,"multi":20000,"long":17500},
  {"sheet":"BMW M440i","make":"BMW","model":"4 Series","trim":"M440i","colour":null,"body":"Coupe","seats":4,"doors":2,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":25000,"multi":22500,"long":20000},
  {"sheet":"BMW M440i Gran Coupe","make":"BMW","model":"4 Series","trim":"M440i Gran Coupe","colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":true,"base":30000,"multi":27500,"long":25000},
  {"sheet":"BMW M4 Comp White","make":"BMW","model":"M4","trim":"Competition","colour":"White","body":"Coupe","seats":4,"doors":2,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":47500,"multi":45000,"long":37500},
  {"sheet":"BMW M4 Comp Black","make":"BMW","model":"M4","trim":"Competition","colour":"Black","body":"Coupe","seats":4,"doors":2,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":true,"base":75000,"multi":72500,"long":70000},
  {"sheet":"BMW 530i MSport","make":"BMW","model":"5 Series","trim":"530i M Sport","colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"premium","year":2025,"included":false,"base":20000,"multi":17500,"long":15000},
  {"sheet":"BMW X3M Comp","make":"BMW","model":"X3 M","trim":"Competition","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2024,"included":false,"base":35000,"multi":32500,"long":30000},
  {"sheet":"BMW X4M40i","make":"BMW","model":"X4","trim":"M40i","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":25000,"multi":22000,"long":20000},
  {"sheet":"BMW X5 MSport","make":"BMW","model":"X5","trim":"M Sport","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"premium","year":2025,"included":false,"base":22500,"multi":20000,"long":17500},
  {"sheet":"BMW X6M","make":"BMW","model":"X6 M","trim":null,"colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":37500,"multi":35000,"long":32500},
  {"sheet":"Audi A5 Conv","make":"Audi","model":"A5","trim":"Cabriolet","colour":null,"body":"Convertible","seats":4,"doors":2,"drive":"All-wheel drive","transmission":"Automatic","class":"premium","year":2024,"included":false,"base":20000,"multi":17500,"long":15000},
  {"sheet":"Audi S5","make":"Audi","model":"S5","trim":null,"colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2024,"included":false,"base":23000,"multi":20000,"long":20000},
  {"sheet":"Audi R8 Spyder","make":"Audi","model":"R8","trim":"Spyder","colour":null,"body":"Convertible","seats":2,"doors":2,"drive":"All-wheel drive","transmission":"Automatic (dual-clutch)","class":"exotic","year":2023,"included":false,"base":100000,"multi":90000,"long":90000},
  {"sheet":"Porsche 718 Boxster","make":"Porsche","model":"718 Boxster","trim":null,"colour":null,"body":"Convertible","seats":2,"doors":2,"drive":"Rear-wheel drive","transmission":"Automatic (dual-clutch)","class":"luxury","year":2025,"included":false,"base":40000,"multi":37500,"long":32500},
  {"sheet":"Porsche 911 Turbo S","make":"Porsche","model":"911","trim":"Turbo S","colour":null,"body":"Coupe","seats":4,"doors":2,"drive":"All-wheel drive","transmission":"Automatic (dual-clutch)","class":"exotic","year":2025,"included":false,"base":200000,"multi":200000,"long":190000},
  {"sheet":"Porsche Macan S","make":"Porsche","model":"Macan","trim":"S","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic (dual-clutch)","class":"luxury","year":2024,"included":false,"base":25000,"multi":22500,"long":20000},
  {"sheet":"Porsche Cayenne","make":"Porsche","model":"Cayenne","trim":null,"colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":27500,"multi":25000,"long":22500},
  {"sheet":"Range Rover Velar White","make":"Land Rover","model":"Range Rover Velar","trim":null,"colour":"White","body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":22000,"multi":20000,"long":17500},
  {"sheet":"Range Rover Velar Blue","make":"Land Rover","model":"Range Rover Velar","trim":null,"colour":"Blue","body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":25000,"multi":22000,"long":20000},
  {"sheet":"Range Rover Sport V6","make":"Land Rover","model":"Range Rover Sport","trim":"V6","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":25000,"multi":22000,"long":20000},
  {"sheet":"Range Rover Sport V8","make":"Land Rover","model":"Range Rover Sport","trim":"V8","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":30000,"multi":27500,"long":25000},
  {"sheet":"Range Rover Autobiography","make":"Land Rover","model":"Range Rover","trim":"Autobiography","colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":true,"base":60000,"multi":60000,"long":60000},
  {"sheet":"Ferrari California T","make":"Ferrari","model":"California","trim":"T","colour":null,"body":"Convertible","seats":4,"doors":2,"drive":"Rear-wheel drive","transmission":"Automatic (dual-clutch)","class":"exotic","year":2017,"included":true,"base":150000,"multi":145000,"long":140000},
  {"sheet":"Ferrari 488 Spider","make":"Ferrari","model":"488","trim":"Spider","colour":null,"body":"Convertible","seats":2,"doors":2,"drive":"Rear-wheel drive","transmission":"Automatic (dual-clutch)","class":"exotic","year":2019,"included":false,"base":200000,"multi":180000,"long":160000},
  {"sheet":"Mclaren 570s","make":"McLaren","model":"570S","trim":null,"colour":null,"body":"Coupe","seats":2,"doors":2,"drive":"Rear-wheel drive","transmission":"Automatic (dual-clutch)","class":"exotic","year":2021,"included":true,"base":150000,"multi":145000,"long":140000},
  {"sheet":"Lamborghini Urus","make":"Lamborghini","model":"Urus","trim":null,"colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"exotic","year":2024,"included":true,"base":200000,"multi":180000,"long":160000},
  {"sheet":"Corvette C8 Stingray","make":"Chevrolet","model":"Corvette","trim":"Stingray","colour":null,"body":"Coupe","seats":2,"doors":2,"drive":"Rear-wheel drive","transmission":"Automatic (dual-clutch)","class":"exotic","year":2025,"included":false,"base":70000,"multi":60000,"long":50000},
  {"sheet":"Chevrolet Suburban","make":"Chevrolet","model":"Suburban","trim":null,"colour":null,"body":"SUV","seats":7,"doors":4,"drive":"Four-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":40000,"multi":37500,"long":32500},
  {"sheet":"Cadillac Escalade","make":"Cadillac","model":"Escalade","trim":null,"colour":null,"body":"SUV","seats":7,"doors":4,"drive":"Four-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":false,"base":60000,"multi":55000,"long":50000},
  {"sheet":"Cadillac Escalade ESV","make":"Cadillac","model":"Escalade","trim":"ESV","colour":null,"body":"SUV","seats":7,"doors":4,"drive":"Four-wheel drive","transmission":"Automatic","class":"luxury","year":2025,"included":true,"base":60000,"multi":55000,"long":50000},
  {"sheet":"Rolls Royce Ghost","make":"Rolls-Royce","model":"Ghost","trim":null,"colour":null,"body":"Sedan","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"exotic","year":2024,"included":false,"base":100000,"multi":90000,"long":80000},
  {"sheet":"Bentley Bentayga","make":"Bentley","model":"Bentayga","trim":null,"colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"exotic","year":2024,"included":true,"base":120000,"multi":110000,"long":100000},
  {"sheet":"Ford Mustang Conv","make":"Ford","model":"Mustang","trim":"Convertible","colour":null,"body":"Convertible","seats":4,"doors":2,"drive":"Rear-wheel drive","transmission":"Automatic","class":"premium","year":2024,"included":false,"base":15000,"multi":12000,"long":10000},
  {"sheet":"Infiniti Q60","make":"Infiniti","model":"Q60","trim":null,"colour":null,"body":"Coupe","seats":4,"doors":2,"drive":"All-wheel drive","transmission":"Automatic","class":"premium","year":2022,"included":false,"base":20000,"multi":17500,"long":15000},
  {"sheet":"Maserati Levante","make":"Maserati","model":"Levante","trim":null,"colour":null,"body":"SUV","seats":5,"doors":4,"drive":"All-wheel drive","transmission":"Automatic","class":"luxury","year":2024,"included":false,"base":25000,"multi":22000,"long":20000}],"chauffeur":[{"sheet":"Mercedes GLS Maybach","name":"Mercedes-Maybach GLS","slug":"mercedes-maybach-gls","kind":"chauffeur_only","passengers":4,"rentals":[],"two_hour":35000,"three_plus":30000,"sort":1},
  {"sheet":"Mercedes S580","name":"Mercedes-Benz S580","slug":"mercedes-benz-s580","kind":"chauffeur_rental","passengers":3,"rentals":["Mercedes S580"],"two_hour":20000,"three_plus":17500,"sort":2},
  {"sheet":"Mercedes S680","name":"Mercedes-Maybach S680","slug":"mercedes-maybach-s680","kind":"chauffeur_rental","passengers":3,"rentals":[],"two_hour":22500,"three_plus":20000,"sort":3},
  {"sheet":"Chevrolet Suburban","name":"Chevrolet Suburban","slug":"chevrolet-suburban","kind":"chauffeur_rental","passengers":6,"rentals":["Chevrolet Suburban"],"two_hour":17500,"three_plus":15000,"sort":4},
  {"sheet":"Cadillac Escalade","name":"Cadillac Escalade","slug":"cadillac-escalade","kind":"chauffeur_rental","passengers":6,"rentals":["Cadillac Escalade"],"two_hour":20000,"three_plus":17500,"sort":5},
  {"sheet":"Range Rovers","name":"Range Rover","slug":"range-rover","kind":"chauffeur_rental","passengers":4,"rentals":["Range Rover Autobiography","Range Rover Sport V8","Range Rover Sport V6","Range Rover Velar White","Range Rover Velar Blue"],"two_hour":20000,"three_plus":15000,"sort":6},
  {"sheet":"Rolls Royce Ghost","name":"Rolls-Royce Ghost","slug":"rolls-royce-ghost","kind":"chauffeur_rental","passengers":3,"rentals":["Rolls Royce Ghost"],"two_hour":35000,"three_plus":35000,"sort":7},
  {"sheet":"Rolls Royce Phantom","name":"Rolls-Royce Phantom","slug":"rolls-royce-phantom","kind":"chauffeur_only","passengers":3,"rentals":[],"two_hour":60000,"three_plus":50000,"sort":8},
  {"sheet":"Rolls Royce Cullinan","name":"Rolls-Royce Cullinan","slug":"rolls-royce-cullinan","kind":"chauffeur_only","passengers":4,"rentals":[],"two_hour":60000,"three_plus":50000,"sort":9},
  {"sheet":"Sprinter Van Blue","name":"Mercedes-Benz Sprinter (blue)","slug":"mercedes-benz-sprinter-blue","kind":"chauffeur_only","passengers":12,"rentals":[],"two_hour":40000,"three_plus":35000,"sort":10},
  {"sheet":"Sprinter Van Orange","name":"Mercedes-Benz Sprinter (orange)","slug":"mercedes-benz-sprinter-orange","kind":"chauffeur_only","passengers":12,"rentals":[],"two_hour":40000,"three_plus":35000,"sort":11}]}'::jsonb);
-- FLEET 0093 END

-- ================================================================ 11. the guides for this release
create or replace function app.guide_release_0093(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;

-- GUIDES 0093 START (generated by supabase/seed/0093_gen.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_0093('admin', 'partners-company-cars-and-rentals-added-by-hand', 'chapter', 'fleet-and-listings', 'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
3. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
4. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
5. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
6. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**Owners and partners** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings.

1. Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
2. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
3. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
4. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
5. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
6. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
7. Choose Where it came from and how it is paid: **Paid another way**, **Send a payment link**, **Charge the saved card when the renter signs** or **Unpaid: invoice later**.
8. Press **Check the calendar and the price**. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** takes every sample car off the site in one click. Nothing stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. It becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
', 'Partners, company cars and rentals added by hand', 'Add a car, partners, add a rental, retire or delete a car, sample cars and tolls with two rentals.',
  'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
3. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
4. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
5. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
6. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**Owners and partners** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## A partner fleet on its own rates

Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).

1. **Owners and partners** > **Partners** > the partner. **Pricing** shows how it is paid: the renter pays the partner''s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press **Edit pricing** to change the markup, the cut or the basis for every car at once.
2. **Cars** lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter''s rates. Press **Edit** on a car to change a negotiated rate, give that car its own markup or cut, mark it **Insurance included** or **No credit card needed**, or confirm its model year. The renter''s rates change at once.
3. The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and "Guideline rates; final price confirmed after review". A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.
4. The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says "Year confirmed when you book"; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car''s page before its first handover.
5. Real photos: open the car (its name in Cars), **Photos**, and add them. Once approved they replace the eight studio stand-ins.

> Good to know: The partner''s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner''s share in proportion; a discount CarmaCars gives comes out of the markup.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings.

1. Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
2. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
3. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
4. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
5. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
6. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
7. Choose Where it came from and how it is paid: **Paid another way**, **Send a payment link**, **Charge the saved card when the renter signs** or **Unpaid: invoice later**.
8. Press **Check the calendar and the price**. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** takes every sample car off the site in one click. Nothing stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. It becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
',
  '<p class="gd-p">A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.</p><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-car" data-gd-task><h2 class="gd-h2">Add a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then <b class="gd-ui">Add a car</b>. Start with the VIN: everything else about the car comes from it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">No VIN at hand? Press <b class="gd-ui">No VIN at hand? Add the car by its plate</b> and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose who supplies it: <b class="gd-ui">A program owner&#39;s car</b> (choose the owner; the car starts its onboarding), <b class="gd-ui">CarmaCars-owned (company fleet)</b> (no owner; all of its revenue is CarmaCars&#39;) or <b class="gd-ui">A partner rental company&#39;s car</b> (choose the partner; leave the commission empty to use the partner&#39;s).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car&#39;s Rates tab. Press <b class="gd-ui">Add the car</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car&#39;s listing; a field you change is kept.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car&#39;s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.</div></aside><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Who supplies the car</b> shows the supplier and the commission, and changes them. Vehicles filters by supply type.</p></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-partners" data-gd-task><h2 class="gd-h2">Partners</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Partners</b>. Partner rental companies whose cars we rent out on commission.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add a partner</b>: business and legal name, contacts, HST number, commission and insurance with its expiry date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Banking (Admins only): <b class="gd-ui">Save the payout account</b> for the account we pay the partner into. The account number is stored encrypted. Press <b class="gd-ui">Verify</b> once checked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Portal: <b class="gd-ui">Invite to the owner portal</b> gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Print the partner agreement</b>, then record the signed scan under Record a paper signature.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-a-partner-fleet-on-its-own-rates" data-gd-task><h2 class="gd-h2">A partner fleet on its own rates</h2><p class="gd-p">Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Partners</b> &gt; the partner. <b class="gd-ui">Pricing</b> shows how it is paid: the renter pays the partner&#39;s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press <b class="gd-ui">Edit pricing</b> to change the markup, the cut or the basis for every car at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Cars</b> lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter&#39;s rates. Press <b class="gd-ui">Edit</b> on a car to change a negotiated rate, give that car its own markup or cut, mark it <b class="gd-ui">Insurance included</b> or <b class="gd-ui">No credit card needed</b>, or confirm its model year. The renter&#39;s rates change at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and &quot;Guideline rates; final price confirmed after review&quot;. A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says &quot;Year confirmed when you book&quot;; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car&#39;s page before its first handover.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Real photos: open the car (its name in Cars), <b class="gd-ui">Photos</b>, and add them. Once approved they replace the eight studio stand-ins.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The partner&#39;s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner&#39;s share in proportion; a discount CarmaCars gives comes out of the markup.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-rental-by-hand" data-gd-task><h2 class="gd-h2">Add a rental by hand</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. For phone, walk-in, Turo, partner and insurer bookings.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check the price: the car&#39;s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">An owner&#39;s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner&#39;s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press <b class="gd-ui">Insurer confirmed</b> once the insurer confirms it.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Choose Where it came from and how it is paid: <b class="gd-ui">Paid another way</b>, <b class="gd-ui">Send a payment link</b>, <b class="gd-ui">Charge the saved card when the renter signs</b> or <b class="gd-ui">Unpaid: invoice later</b>.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Press <b class="gd-ui">Check the calendar and the price</b>. Tick <b class="gd-ui">Do not email the renter</b> if they should not get the confirmation. Press <b class="gd-ui">Add the rental</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, <b class="gd-ui">Verified in person</b> records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-retire-or-delete-a-car" data-gd-task><h2 class="gd-h2">Retire or delete a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Retire or delete</b>, or the car&#39;s own page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Retire this car</b> takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. <b class="gd-ui">Restore</b> brings it back.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Delete this car</b> removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On the same page, <b class="gd-ui">Delete all sample cars</b> deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-sample-cars-on-the-site" data-gd-task><h2 class="gd-h2">Sample cars on the site</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, or <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Site</b>. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide sample cars</b> takes every sample car off the site in one click. Nothing stops it: not an enquiry, not an old request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show sample cars</b> puts the 20 back, with their photos and rates. Ones that were deleted are made again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the site each one is marked &quot;Example car&quot;. They never appear in search engines or the sitemap.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A request on a sample car is never a booking. It becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-why-a-car-is-not-on-the-site-yet" data-gd-task><h2 class="gd-h2">Why a car is not on the site yet</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, the card Not on the site yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The same car is a line on To do with <b class="gd-ui">Set rates and publish</b>. The car comes off both once it is on the site.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-tolls-when-two-rentals-overlap" data-gd-task><h2 class="gd-h2">Tolls when two rentals overlap</h2><p class="gd-p">Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.</p></section>');
select app.guide_release_0093('admin', 'chauffeur-service', 'chapter', 'partners-company-cars-and-rentals-added-by-hand', null, 'Chauffeur service', 'Chauffeur requests: quote, confirm and close them; the vehicles and their hourly rates.',
  'Visitors book a driver and a luxury car or van by the hour on carmacars.ca/chauffeur. The vehicles come from a partner''s chauffeur price guide, each with a rate for 2 hours and a rate for 3 hours or more.

:::flow
Request | The visitor sends the date, hours and addresses
Quote | You check with the partner and send the quote
Confirm | The client agrees and pays
Done | Mark it completed after the trip
:::

## The requests

**Bookings** > **Chauffeur**. Each request has its number (CH-1001 and up), the vehicle, the date and start time, the hours, the pickup and drop-off addresses, the passengers, the occasion and the notes.

1. The **Quote** column is the price for the client: the hours at the 2-hour rate (exactly 2 hours) or the 3+ hour rate (3 hours or more), before HST, then HST and the total. The line under it is the quote line to send.
2. **Partner, CarmaCars** shows the partner''s sheet amount, what the partner is owed (the sheet amount less the cut) and what CarmaCars keeps (the markup plus the cut).
3. Check the vehicle and the driver with the partner for that time. To change the vehicle or the hours, press **Change**: the quote is worked out again.
4. Send the quote line by email or phone, then press **Quoted** and say how you sent it. The task in the queue is done.
5. When the client agrees, take the payment (a payment link, or at pickup), press **Confirm** and note how it is paid.
6. After the trip press **Completed**. **Decline** or **Cancel** closes a request with the reason.

> Tip: To do has a line **Chauffeur requests to quote** while any request is new, and the card Chauffeur today lists the confirmed trips of the day.

## The vehicles and their rates

**Owners and partners** > **Partners** > the partner, card Chauffeur vehicles.

1. Each vehicle shows the partner''s rates an hour and the client''s (the markup added, rounded to the nearest dollar).
2. Press **Edit** to change a rate, give it its own markup or cut, change the passengers, or take it off the site.
3. A vehicle the partner also rents (chauffeur / rental) links to its car pages on the public page.

> Good to know: Booking requests for cars, offers and payments do not cover chauffeur trips: a chauffeur request is a quote that you send and confirm here.
',
  '<p class="gd-p">Visitors book a driver and a luxury car or van by the hour on carmacars.ca/chauffeur. The vehicles come from a partner&#39;s chauffeur price guide, each with a rate for 2 hours and a rate for 3 hours or more.</p><ol class="gd-flow"><li><b>1</b><span>Request</span><em>The visitor sends the date, hours and addresses</em></li><li><b>2</b><span>Quote</span><em>You check with the partner and send the quote</em></li><li><b>3</b><span>Confirm</span><em>The client agrees and pays</em></li><li><b>4</b><span>Done</span><em>Mark it completed after the trip</em></li></ol><section class="gd-task" id="chauffeur-service-the-requests" data-gd-task><h2 class="gd-h2">The requests</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Chauffeur</b>. Each request has its number (CH-1001 and up), the vehicle, the date and start time, the hours, the pickup and drop-off addresses, the passengers, the occasion and the notes.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The <b class="gd-ui">Quote</b> column is the price for the client: the hours at the 2-hour rate (exactly 2 hours) or the 3+ hour rate (3 hours or more), before HST, then HST and the total. The line under it is the quote line to send.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Partner, CarmaCars</b> shows the partner&#39;s sheet amount, what the partner is owed (the sheet amount less the cut) and what CarmaCars keeps (the markup plus the cut).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the vehicle and the driver with the partner for that time. To change the vehicle or the hours, press <b class="gd-ui">Change</b>: the quote is worked out again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Send the quote line by email or phone, then press <b class="gd-ui">Quoted</b> and say how you sent it. The task in the queue is done.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">When the client agrees, take the payment (a payment link, or at pickup), press <b class="gd-ui">Confirm</b> and note how it is paid.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">After the trip press <b class="gd-ui">Completed</b>. <b class="gd-ui">Decline</b> or <b class="gd-ui">Cancel</b> closes a request with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>To do has a line <b class="gd-ui">Chauffeur requests to quote</b> while any request is new, and the card Chauffeur today lists the confirmed trips of the day.</div></aside></section><section class="gd-task" id="chauffeur-service-the-vehicles-and-their-rates" data-gd-task><h2 class="gd-h2">The vehicles and their rates</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Partners</b> &gt; the partner, card Chauffeur vehicles.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each vehicle shows the partner&#39;s rates an hour and the client&#39;s (the markup added, rounded to the nearest dollar).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Edit</b> to change a rate, give it its own markup or cut, change the passengers, or take it off the site.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A vehicle the partner also rents (chauffeur / rental) links to its car pages on the public page.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Booking requests for cars, offers and payments do not cover chauffeur trips: a chauffeur request is a quote that you send and confirm here.</div></aside></section>');
select app.guide_release_0093('va', 'chauffeur-requests', 'chapter', 'customer-service', null, 'Chauffeur requests', 'Quote and confirm a chauffeur request; partner cars with insurance included or no credit card needed.',
  'Customer service and Sales handle the chauffeur requests sent from carmacars.ca/chauffeur, and answer questions about the partner cars on the site.

## Quote a chauffeur request

A new request is a task in your queue: Chauffeur request CH-1001, with the vehicle, the date, the hours and the client''s contact.

1. Open **Chauffeur** from the task (or the menu). Find the request by its number.
2. Check the vehicle and the driver with the partner for that date and time.
3. To change the vehicle or the hours, press **Change**. The quote is worked out again: 2 hours at the 2-hour rate, 3 hours or more at the 3+ hour rate for every hour, then HST.
4. Send the quote line to the client by email or phone. Press **Quoted** and write how you sent it.
5. When the client agrees and the payment is arranged, press **Confirm**. After the trip, press **Completed**.

> Tip: The minimum is 2 hours. The rates on the site are guideline rates: the price is confirmed in the quote.

## Partner cars: insurance included, no credit card

Some partner cars say **Insurance included: no personal auto policy needed** and **No credit card needed: debit accepted** on their page.

1. On these cars the renter does not choose a coverage option: the booking shows "insurance included with the car", already confirmed. There is no proof to review.
2. The renter may pay with a debit card in their own name. A prepaid card is still refused.
3. The deposit, the licence and selfie checks and the ages are the same as on every car.
4. Partner cars without a confirmed model year say "Year confirmed when you book". An offer cannot be sent until an Admin confirms the year: ask an Admin.
',
  '<p class="gd-p">Customer service and Sales handle the chauffeur requests sent from carmacars.ca/chauffeur, and answer questions about the partner cars on the site.</p><section class="gd-task" id="chauffeur-requests-quote-a-chauffeur-request" data-gd-task><h2 class="gd-h2">Quote a chauffeur request</h2><p class="gd-p">A new request is a task in your queue: Chauffeur request CH-1001, with the vehicle, the date, the hours and the client&#39;s contact.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Chauffeur</b> from the task (or the menu). Find the request by its number.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the vehicle and the driver with the partner for that date and time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To change the vehicle or the hours, press <b class="gd-ui">Change</b>. The quote is worked out again: 2 hours at the 2-hour rate, 3 hours or more at the 3+ hour rate for every hour, then HST.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Send the quote line to the client by email or phone. Press <b class="gd-ui">Quoted</b> and write how you sent it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">When the client agrees and the payment is arranged, press <b class="gd-ui">Confirm</b>. After the trip, press <b class="gd-ui">Completed</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The minimum is 2 hours. The rates on the site are guideline rates: the price is confirmed in the quote.</div></aside></section><section class="gd-task" id="chauffeur-requests-partner-cars-insurance-included-no-credit-card" data-gd-task><h2 class="gd-h2">Partner cars: insurance included, no credit card</h2><p class="gd-p">Some partner cars say <b class="gd-ui">Insurance included: no personal auto policy needed</b> and <b class="gd-ui">No credit card needed: debit accepted</b> on their page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On these cars the renter does not choose a coverage option: the booking shows &quot;insurance included with the car&quot;, already confirmed. There is no proof to review.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The renter may pay with a debit card in their own name. A prepaid card is still refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The deposit, the licence and selfie checks and the ages are the same as on every car.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Partner cars without a confirmed model year say &quot;Year confirmed when you book&quot;. An offer cannot be sent until an Admin confirms the year: ask an Admin.</div></li></ol></div></section>');
-- GUIDES 0093 END

-- ================================================================ 12. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and (p.proname like '%\_pre0093' or p.proname = any (array[
             'partner_renter_cents', 'partner_markup_bps', 'partner_rate_basis', 'partner_sheet_rental_cents', 'rate_cards_partner_multi',
             'bookings_partner_before', 'bookings_included_coverage_after', 'booking_card_ok', 'compute_booking_split', 'build_owner_statement',
             'public_listing_row', 'partner_rates_apply', 'partner_pricing_save', 'partner_car_save', 'partner_car_row', 'partner_detail',
             'chauffeur_vehicle_row', 'chauffeur_quote', 'chauffeur_assert', 'chauffeur_requests_list', 'chauffeur_request_update', 'chauffeur_vehicle_save',
             'door', 'admin_todo', 'partner_fleet_import_0093', 'guide_release_0093']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- each wrapped function keeps the privileges it had
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_pre0093', 'door'), ('admin_todo_pre0093', 'admin_todo'), ('compute_booking_split_pre0093', 'compute_booking_split'),
                          ('build_owner_statement_pre0093', 'build_owner_statement'), ('public_listing_row_pre0093', 'public_listing_row'),
                          ('partner_detail_pre0093', 'partner_detail')) m(old_name, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    foreach g in array array['anon', 'authenticated'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
revoke all on function public.chauffeur_services() from public;
grant execute on function public.chauffeur_services() to anon, authenticated, service_role;
revoke all on function public.submit_chauffeur_request(jsonb, text) from public, anon, authenticated;
grant execute on function public.submit_chauffeur_request(jsonb, text) to service_role;
grant select on partner_rates, chauffeur_vehicles, chauffeur_requests to authenticated;
grant all on partner_rates, chauffeur_vehicles, chauffeur_requests to service_role;
grant usage on sequence chauffeur_request_seq to service_role;
