-- Test helpers. Loaded once, after the migrations, by scripts/test.sh. Not a migration.
-- Assertions record a row in test.results and never abort the run, so one run reports everything.

create schema if not exists test;

create table test.results (
  id      bigint generated always as identity primary key,
  suite   text not null,
  name    text not null,
  passed  boolean not null,
  detail  text
);

-- The one function that writes results; it runs as its owner so assertions made while acting
-- as a restricted role can still record their outcome.
create or replace function test.record(p_name text, p_passed boolean, p_detail text default null) returns void
language plpgsql security definer set search_path = test, pg_catalog as $$
begin
  insert into test.results (suite, name, passed, detail)
  values (coalesce(nullif(current_setting('test.suite', true), ''), 'unnamed'), p_name, coalesce(p_passed, false), p_detail);
  if not coalesce(p_passed, false) then
    raise warning 'FAIL  %  %', p_name, coalesce(p_detail, '');
  end if;
end $$;

create or replace function test.suite(p_name text) returns void
language sql as $$ select set_config('test.suite', p_name, false); $$;

create or replace function test.ok(p_name text, p_condition boolean, p_detail text default null) returns void
language sql as $$ select test.record(p_name, p_condition, p_detail) $$;

-- Compare as text, so money in cents, dates and enums all read the same way.
create or replace function test.eq(p_name text, p_got anycompatible, p_want anycompatible) returns void
language sql as $$
  select test.record(p_name, p_got is not distinct from p_want,
                     case when p_got is distinct from p_want then format('got %s, want %s', p_got::text, p_want::text) end)
$$;

-- Dollars as written in the specifications: test.money('1,922.25') = 192225 cents.
create or replace function test.money(p_dollars text) returns bigint
language sql immutable as $$ select round(replace(replace(p_dollars, ',', ''), '$', '')::numeric * 100)::bigint $$;

-- The statement must fail, with a message containing p_like. Runs with the caller's rights,
-- so it also proves what a restricted role cannot do.
create or replace function test.throws(p_name text, p_sql text, p_like text default null) returns void
language plpgsql as $$
declare
  v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.record(p_name, p_like is null or v_msg ilike '%' || p_like || '%',
                        case when p_like is not null and v_msg not ilike '%' || p_like || '%'
                             then format('failed with "%s", wanted "%s"', v_msg, p_like) end);
    return;
  end;
  perform test.record(p_name, false, 'statement succeeded but should have failed');
end $$;

-- The statement must succeed.
create or replace function test.lives(p_name text, p_sql text) returns void
language plpgsql as $$
declare
  v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.record(p_name, false, 'failed with "' || v_msg || '"');
    return;
  end;
  perform test.record(p_name, true);
end $$;

-- Rows a write statement touched (an UPDATE that row-level security hides affects 0 rows).
create or replace function test.affected(p_sql text) returns bigint
language plpgsql as $$
declare
  n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

-- Rows a query returns to the caller; -1 when the caller has no privilege at all.
create or replace function test.visible(p_sql text) returns bigint
language plpgsql as $$
declare
  n bigint;
begin
  execute 'select count(*) from (' || p_sql || ') q' into n;
  return n;
exception when insufficient_privilege then
  return -1;
end $$;

-- ------------------------------------------------------------------ fixtures
create or replace function test.id(p_label text) returns uuid
language sql immutable as $$ select md5('carmacars-test:' || p_label)::uuid $$;

create or replace function test.mk_user(p_label text, p_role app_role, p_va va_function default null,
                                        p_field field_function default null, p_referral text default null)
returns uuid language plpgsql as $$
declare
  v_id uuid := test.id(p_label);
begin
  insert into users (id, email, full_name) values (v_id, p_label || '@example.test', initcap(replace(p_label, '_', ' ')));
  insert into user_roles (user_id, role) values (v_id, p_role);
  -- staff have entered their home address, as at their first sign-in (0059; suite 38 tests the ones who have not)
  if p_role = 'va' then
    insert into staff_profiles (user_id, staff_type, va_function) values (v_id, 'va', p_va);
  elsif p_role = 'field' then
    insert into staff_profiles (user_id, staff_type, field_function, referral_code) values (v_id, 'field', coalesce(p_field, 'driver_detailer'), p_referral);
  end if;
  if p_role in ('va', 'field') and exists (select 1 from information_schema.columns where table_name = 'staff_profiles' and column_name = 'home_address') then
    execute 'update staff_profiles set home_address = $1, home_postal_code = $2 where user_id = $3' using '1 ' || initcap(replace(p_label, '_', ' ')) || ' Lane, Testville', 'X9X 9X9', v_id;
  end if;
  return v_id;
end $$;

create or replace function test.mk_owner(p_label text, p_referral text default null, p_hst text default null,
                                         p_shareholder boolean default false)
returns uuid language plpgsql as $$
declare
  v_id uuid := test.id('owner:' || p_label);
  v_user uuid := test.mk_user(p_label, 'owner');
begin
  insert into owners (id, user_id, owner_type, legal_name, referral_code, hst_number, is_shareholder, status, email, phone)
  values (v_id, v_user, 'individual', initcap(replace(p_label, '_', ' ')), p_referral, p_hst, p_shareholder, 'active',
          p_label || '@example.test', '416-555-0100');
  insert into owner_agreements (id, owner_id, kind, agreement_number, agreement_date, status)
  values (test.id('agreement:' || p_label), v_id, 'enrollment', 'EA-' || p_label, date '2026-08-15', 'signed');
  return v_id;
end $$;

-- A vehicle already live in the program, with its signed schedule and fee terms.
create or replace function test.mk_vehicle(p_label text, p_owner_label text, p_mode management_mode default 'managed',
    p_insurance bigint default 45000, p_tracker bigint default 2500, p_share_bps integer default 3500,
    p_enrolled date default date '2026-09-01', p_shareholder boolean default false)
returns uuid language plpgsql as $$
declare
  v_id uuid := test.id('vehicle:' || p_label);
  v_owner uuid := test.id('owner:' || p_owner_label);
  v_sched uuid := test.id('schedule:' || p_label);
  v_n integer;
begin
  insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode,
                        onboarding_method, is_shareholder_owned, on_fleet_policy, fleet_policy_added_on, enrollment_date)
  values (v_id, v_owner, 'F-' || p_label, 2023, 'Mercedes-Benz', 'C 300 ' || p_label,
          upper(substr(md5(p_label), 1, 17)), 'T' || upper(substr(md5(p_label), 1, 6)), 'premium', 'available', p_mode,
          case when p_mode = 'turo_only' then 'none'::onboarding_method else 'transfer'::onboarding_method end,
          p_shareholder, p_mode <> 'turo_only', case when p_mode <> 'turo_only' then p_enrolled end, p_enrolled);
  if not p_shareholder then
    select count(*) + 1 into v_n from vehicle_schedules where owner_agreement_id = test.id('agreement:' || p_owner_label);
    insert into vehicle_schedules (id, vehicle_id, owner_agreement_id, schedule_number, vehicle_number, held_by, title_status,
        management_mode, onboarding_method, insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps,
        enrollment_date, signed_at)
    values (v_sched, v_id, test.id('agreement:' || p_owner_label), 'VS-' || p_label, v_n, 'individual', 'owned_outright',
        p_mode, case when p_mode = 'turo_only' then 'none'::onboarding_method else 'transfer'::onboarding_method end,
        p_insurance, p_tracker, case when p_mode = 'turo_only' then 0 else 10000 end, p_share_bps, p_enrolled, now());
  end if;
  insert into vehicle_fee_history (vehicle_id, vehicle_schedule_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from)
  values (v_id, case when not p_shareholder then v_sched end, case when p_shareholder then 'shareholder' else 'signed_schedule' end,
          p_insurance, p_tracker, p_share_bps, p_enrolled);
  insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents,
        km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
  values (v_id, 10000, 12000, 56000, 180000, 200, 35, 100000, 7500, 7500, p_enrolled::timestamptz);
  return v_id;
end $$;

create or replace function test.mk_renter(p_label text, p_with_login boolean default true) returns uuid
language plpgsql as $$
declare
  v_id uuid := test.id('renter:' || p_label);
  v_user uuid;
begin
  if p_with_login then v_user := test.mk_user(p_label, 'renter'); end if;
  insert into renters (id, user_id, legal_name, date_of_birth, mobile, email, identity_status)
  values (v_id, v_user, initcap(replace(p_label, '_', ' ')), date '1990-05-05', '647-555-0199', p_label || '@example.test', 'verified');
  insert into drivers (id, renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, identity_status)
  values (test.id('driver:' || p_label), v_id, true, v_user, initcap(replace(p_label, '_', ' ')), date '1990-05-05',
          'L' || upper(substr(md5(p_label), 1, 14)), 'G', 'ON', date '2030-01-01', 'verified');
  insert into payment_methods (id, renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit)
  values (test.id('card:' || p_label), v_id, 'visa', '4242', initcap(replace(p_label, '_', ' ')), 12, 2030, true);
  return v_id;
end $$;

-- A booking written straight into a given status (the import path), priced at the stored rates
-- unless a rental charge is given. Times are Toronto wall-clock strings.
create or replace function test.mk_booking(p_number text, p_vehicle_label text, p_renter_label text,
    p_pickup text, p_return text, p_status booking_status default 'closed',
    p_rental_cents bigint default null, p_type booking_type default 'standard',
    p_referred_by text default null, p_booked text default null, p_checked_in text default null,
    p_renews text default null)
returns uuid language plpgsql as $$
declare
  v_id uuid := test.id('booking:' || p_number);
  v_pickup timestamptz := p_pickup::timestamp at time zone 'America/Toronto';
  v_return timestamptz := p_return::timestamp at time zone 'America/Toronto';
  v_days integer := public.calc_billable_days(v_pickup, v_return);
  v_rate record;
  v_rental bigint;
  v_discount bigint;
begin
  select * into v_rate from public.calc_rental_charge(v_pickup, v_days, 10000, 12000, 56000, 180000);
  v_rental := case when p_type = 'owner' then 0 else coalesce(p_rental_cents, v_rate.rental_charge_cents) end;
  v_discount := case when p_type = 'non_refundable' then public.calc_bps(v_rental, 1000) else 0 end;
  insert into bookings (id, booking_number, booking_type, status, vehicle_id, renter_id, renews_booking_id,
      booked_at, pickup_at, return_at, original_return_at, billable_days,
      checked_in_at, handed_over_at,
      daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days,
      rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km,
      deposit_cents, card_on_file_id, referred_by_code,
      subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
  values (v_id, p_number, p_type, p_status, test.id('vehicle:' || p_vehicle_label), test.id('renter:' || p_renter_label),
      case when p_renews is not null then test.id('booking:' || p_renews) end,
      coalesce(p_booked::timestamp at time zone 'America/Toronto', v_pickup - interval '10 days'), v_pickup, v_return, v_return, v_days,
      case when p_status in ('returned', 'closed') then coalesce(p_checked_in::timestamp at time zone 'America/Toronto', v_return) end,
      case when p_status in ('on_rent', 'returned', 'closed') then v_pickup end,
      case when p_type = 'owner' then 0 else 10000 end, case when p_type = 'owner' then 0 else 12000 end,
      case when p_type = 'owner' then 0 else 56000 end, case when p_type = 'owner' then 0 else 180000 end,
      case when p_type = 'owner' then 'none' else v_rate.rate_applied end, v_rate.daily_days, v_rate.weekend_days,
      v_rental, v_discount, 200, 200 * v_days, 35,
      case when p_type = 'owner' then 0 else 100000 end, test.id('card:' || p_renter_label), p_referred_by,
      v_rental - v_discount, public.calc_hst(v_rental - v_discount), (v_rental - v_discount) + public.calc_hst(v_rental - v_discount));
  if p_type <> 'owner' and v_rental > 0 then
    perform test.mk_line(p_number, 'rental_charge', v_rental);
    if v_discount > 0 then perform test.mk_line(p_number, 'non_refundable_discount', -v_discount); end if;
  end if;
  return v_id;
end $$;

-- One charge line, classified and taxed from the catalogue, attached to the booking's paid charge.
create or replace function test.mk_line(p_number text, p_charge_type text, p_amount_cents bigint, p_paid boolean default true)
returns uuid language plpgsql as $$
declare
  v_booking uuid := test.id('booking:' || p_number);
  v_pay uuid := test.id('payment:' || p_number || case when p_paid then '' else ':unpaid' end);
  f fee_types;
  v_hst bigint;
  v_id uuid;
begin
  select * into f from fee_types where code = p_charge_type;
  if f.code is null then raise exception 'unknown charge type %', p_charge_type; end if;
  v_hst := case when f.hst_applies then public.calc_hst(p_amount_cents) else 0 end;
  if not exists (select 1 from payments where id = v_pay) then
    insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
    select v_pay, v_booking, b.renter_id, 'booking_total', 'charge', 'card', 1,
           case when p_paid then 'succeeded' else 'failed' end, b.booked_at
      from bookings b where b.id = v_booking;
  end if;
  insert into booking_line_items (booking_id, charge_type, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents,
                                  revenue_class, stage, payment_id)
  values (v_booking, p_charge_type, 1, p_amount_cents, p_amount_cents, f.hst_applies, v_hst, f.revenue_class, f.stage, v_pay)
  returning id into v_id;
  update payments set amount_cents = greatest(1, (select sum(amount_cents + hst_cents) from booking_line_items where payment_id = v_pay))
   where id = v_pay;
  return v_id;
end $$;

grant usage on schema test to authenticated, anon;
grant execute on all functions in schema test to authenticated, anon;

-- The plate check before publishing (0042, on by default) is off for the earlier suites: they test the publish rules
-- of 0022 to 0041 with photos that carry no plate decision. 26_tolls_plates_forms.sql switches it on and tests it.
alter table program_settings alter column listing_plate_check_required set default false;
update program_settings set listing_plate_check_required = false;

-- Publishing new cars automatically (0070, on by default) is off for the earlier suites: they add cars and set up their
-- listings by hand. 49_listing_no_roadblocks.sql switches it on and tests it.
alter table program_settings alter column listing_publish_new_cars_automatically set default false;
update program_settings set listing_publish_new_cars_automatically = false;

-- The licence before an offer is accepted, the return charges written at check-in and the refill price per eighth
-- (0130, on by default) are off for the earlier suites: they approve offers without licence images and price the
-- returns by calling the Check-in assessment themselves. 82_handover_signing_licence.sql switches them on and tests them.
alter table program_settings alter column booking_licence_required set default false;
alter table program_settings alter column booking_return_auto_charges set default false;
alter table program_settings alter column statement_fuel_cents_per_eighth set default null;
update program_settings set booking_licence_required = false, booking_return_auto_charges = false, statement_fuel_cents_per_eighth = null;

-- The review request program of 0146 (on by default) replaces 0023's and 0061's review emails, which the earlier suites
-- test: it is off for them. 91_review_requests.sql switches it on and tests it.
alter table program_settings alter column review_program_enabled set default false;
update program_settings set review_program_enabled = false;
-- Field jobs made from each confirmed booking and given to the least busy field staff member (0151, on by default) are
-- off for the earlier suites: they make, assign and count field jobs themselves. 96_field_finance_owner_mtd.sql switches
-- them on and tests them.
alter table program_settings alter column field_jobs_auto set default false;
update program_settings set field_jobs_auto = false;
-- the jobs the migration made for the bookings already there, before any suite ran
delete from field_jobs j where j.auto_created and j.auto_at is not null and j.status = 'scheduled'
   and not exists (select 1 from condition_reports c where c.field_job_id = j.id);
-- The signing session (identity code, initials, consents, drawn signature) and the agreement check at check-out (0154,
-- on by default) are off for the earlier suites: they sign with typed names and check cars out with made-up drivers
-- whose licence details are partly blank. 87_agreement_accuracy.sql switches them on and tests them.
alter table program_settings alter column esign_strict set default false;
alter table program_settings alter column agreement_claim_check set default false;
update program_settings set esign_strict = false, agreement_claim_check = false;
