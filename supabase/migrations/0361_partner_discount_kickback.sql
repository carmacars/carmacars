-- 0361_partner_discount_kickback.sql
-- 01 Motors on our own pricing (docs/changes/2026-11-06-lead-time-and-partner-pricing.md). The owner: "remove the 10%
-- markup on 01 motors cars, we get a 20% kickback but we keep 100% of the fees and taxes we get to charge ... keep
-- their rates stored and apply a 10% discount on all of their rates into our system but record that we get a 20%
-- kickback from the listed rates they gave us. And then have all of our pricing rules apply to their vehicles".
--
--   1. The partner's listed rates stay as given (partner_rates). Our selling base rate is the listed rate less the
--      partner discount (Program settings partner_discount_bps, 10%; per partner partners.discount_bps; per car
--      vehicles.partner_discount_bps), to the nearest dollar. The markup (0093) is gone.
--   2. From that base every rule of our own cars applies: the weekend rule (0271: a weekend rate at or below the daily
--      rate is raised to daily + 15%; the listed sheet has no weekend rate, so the discounted weekend is the discounted
--      daily rate), lead-time pricing (0360), every fee, the deposit, taxes, promo codes and the non-refundable discount.
--   3. The partner is owed its listed rental: the listed rates times the booked days (the sheet amount 0093 keeps,
--      before our discount, never our lead-time adjustment or discounts), less the kickback CarmaCars receives: 20% of
--      that listed rental (the partner's commission_bps, now the kickback). Fees, kilometre overage and taxes are
--      CarmaCars' own, 100%. booking_splits.partner_kickback_cents records the receivable; owner_payout_cents is what is
--      payable to the partner; partner_markup_cents is now CarmaCars' margin on the rental against the listed rental
--      (negative when our selling price is below the listed rate) plus the kilometre overage.
--   4. The partner's statement shows each rental at the listed rate, the 20% kickback and the amount payable. Admin's
--      partner page shows the receivable and the payable.
--   5. Data: the partners lose the markup (01 Motors keeps its 20% as the kickback, takes the 10% discount), each partner
--      car's rate card is made again from its listed rates, and requests not yet offered on a partner car are priced
--      again on the new rates. Offers out and confirmed bookings keep their locked prices and are paid to the partner
--      as before (0093's split, kept for any booking that still carries its markup).
-- No applied migration is edited: functions that change are replaced or patched in place with pg_temp.patch_fn.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0361: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings and columns
alter table program_settings
  add column if not exists partner_discount_bps integer not null default 1000 check (partner_discount_bps between 0 and 9000);
comment on column program_settings.partner_discount_bps is 'A partner car''s selling base rate is its listed rate less this (0361): 10% by default; a partner or a car may have its own';
comment on column program_settings.partner_commission_bps is 'A partner''s commission (0046). On the listed-rate basis (0361) it is the kickback CarmaCars receives: 20% of the listed rental';
comment on column program_settings.partner_markup_bps is 'No longer used (0361: partner cars are sold at their listed rate less the partner discount). Kept for bookings made before.';

alter table partners add column if not exists discount_bps integer check (discount_bps between 0 and 9000);
comment on column partners.discount_bps is 'The discount on this partner''s listed rates that makes our selling base rate (0361); empty: Program settings';
comment on column partners.commission_bps is 'On the partner_rate basis: the kickback CarmaCars receives, a percentage of the listed rental (0361); on renter_price: the commission (0046). Empty: Program settings';
comment on column partners.markup_bps is 'No longer used (0361)';
comment on column partners.payout_basis is 'renter_price: CarmaCars keeps the commission of what the renter paid (0046). partner_rate: the partner is owed its listed rental less the kickback; the renter pays our price from the listed rate less the discount (0361)';

alter table vehicles add column if not exists partner_discount_bps integer check (partner_discount_bps between 0 and 9000);
alter table vehicles drop constraint if exists vehicles_partner_discount;
alter table vehicles add constraint vehicles_partner_discount check (partner_discount_bps is null or supply_type = 'partner');
comment on column vehicles.partner_discount_bps is 'This partner car''s own discount on its listed rates (0361); empty: the partner''s';

alter table bookings add column if not exists partner_discount_bps integer check (partner_discount_bps between 0 and 9000);
comment on column bookings.partner_discount_bps is 'A partner-rate car (0361): the discount on the listed rates when the booking was made. A booking with partner_markup_bps was made on 0093''s markup';
comment on column bookings.partner_cut_bps is 'A partner-rate car: the kickback (0361; 0093''s cut) CarmaCars receives, a percentage of the listed rental';

alter table booking_splits add column if not exists partner_kickback_cents bigint not null default 0;
comment on column booking_splits.partner_kickback_cents is 'A partner-rate car (0361): the kickback receivable from the partner, its percentage of the listed rental (equals company_share_cents)';
comment on column booking_splits.partner_markup_cents is 'A partner-rate car: CarmaCars'' own part of the rental (0361: the rental charge less the listed rental, which may be negative, plus the kilometre overage; 0093: the markup)';
comment on table partner_rates is 'A partner car''s listed rates per day (0093): base (1 to 2 days), multi-day (3 or more), long term (7 or more). Our rate card is made from them less the partner discount (0361).';

-- ================================================================ 2. our selling rates from the listed rates
create or replace function app.partner_discount_bps(p_vehicle uuid, p_on date default app.today()) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(v.partner_discount_bps, p.discount_bps, (app.settings(p_on)).partner_discount_bps)
    from vehicles v left join partners p on p.id = v.partner_id where v.id = p_vehicle
$$;

-- The selling rate for a listed rate: less the discount, to the nearest dollar (half a dollar up). The same rule is
-- sellingCents in web/src/features/partner/fleet-01-motors.ts.
create or replace function app.partner_selling_cents(p_listed_cents bigint, p_discount_bps integer) returns bigint
language sql immutable as $$
  select (round(p_listed_cents::numeric * (10000 - coalesce(p_discount_bps, 0)) / 1000000) * 100)::bigint
$$;

-- Our rate card from a car's listed rates: the 1-2 day rate less the discount is the daily rate, the weekend rate follows
-- our weekend rule (0271), the 3+ day rate is the multi-day rate (never above the daily), the 7+ day rate a day makes the
-- weekly (7 days) and monthly (30 days) rates. The deposit, kilometres, delivery and pickup of the current card are kept.
-- Nothing changes when the card already says so.
create or replace function app.partner_rates_apply(p_vehicle uuid, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r partner_rates;
  rc rate_cards;
  m integer := app.partner_discount_bps(p_vehicle);
  d bigint; w bigint; mu bigint; l bigint;
  v_id uuid;
  v_src text;
begin
  select * into r from partner_rates where vehicle_id = p_vehicle;
  if r.vehicle_id is null then return null; end if;
  d := app.partner_selling_cents(r.base_cents, m);
  w := app.weekend_floor_cents(d);
  mu := least(app.partner_selling_cents(r.multi_day_cents, m), d);
  l := app.partner_selling_cents(r.long_term_cents, m);
  select * into rc from rate_cards x where x.vehicle_id = p_vehicle and x.effective_from <= now() and (x.effective_to is null or x.effective_to > now());
  if rc.id is not null and rc.daily_rate_cents = d and rc.weekend_rate_cents = w and rc.weekly_rate_cents = l * 7 and rc.monthly_rate_cents = l * 30
     and rc.multi_day_rate_cents is not distinct from mu then
    return rc.id;
  end if;
  v_id := app.set_rate_card(p_vehicle, d, w, l * 7, l * 30, now(), p_by,
    case when rc.id is null then jsonb_build_object('km_mode', 'default')
         else jsonb_build_object('km_mode', 'custom', 'km_allowance_per_day', rc.km_allowance_per_day, 'overage_cents_per_km', rc.overage_cents_per_km,
                                 'deposit_cents', rc.deposit_cents, 'delivery_fee_cents', rc.delivery_fee_cents, 'pickup_fee_cents', rc.pickup_fee_cents) end);
  v_src := format('The partner''s listed rate less %s, to the nearest dollar', app.fmt_pct(m));
  update rate_cards set multi_day_rate_cents = mu,
         auto_defaults = auto_defaults || jsonb_build_object(
           'daily', jsonb_build_object('value', d, 'source', v_src || ' (1 to 2 days)'),
           'weekend', jsonb_build_object('value', w, 'source', 'The daily rate plus the weekend premium in Program settings (the partner''s sheet has no weekend rate)'),
           'weekly', jsonb_build_object('value', l * 7, 'source', v_src || ' (7 or more days), for 7 days'),
           'monthly', jsonb_build_object('value', l * 30, 'source', v_src || ' (7 or more days), for 30 days'))
   where id = v_id;
  return v_id;
end $$;

-- A rate card made for a partner car without the multi-day rate (the Rates tab) keeps the one from its listed rates.
create or replace function app.rate_cards_partner_multi() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.multi_day_rate_cents is null then
    select app.partner_selling_cents(r.multi_day_cents, app.partner_discount_bps(new.vehicle_id)) into new.multi_day_rate_cents
      from partner_rates r where r.vehicle_id = new.vehicle_id;
    if new.multi_day_rate_cents > new.daily_rate_cents then new.multi_day_rate_cents := new.daily_rate_cents; end if;
  end if;
  return new;
end $$;

-- ================================================================ 3. a booking on a partner car
-- Before a booking is written (0093's trigger, on the new basis): the car's multi-day rate with the rates it was priced
-- at; on a partner-rate car the listed rental, the kickback and the discount (kept from when it was made; the listed
-- rental follows the dates and the car). A booking made on 0093's markup keeps it until it moves to another car.
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
      new.partner_discount_bps := app.partner_discount_bps(v.id);
      new.partner_markup_bps := null;
    else
      new.partner_cut_bps := null; new.partner_markup_bps := null; new.partner_discount_bps := null; new.partner_sheet_rental_cents := null;
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
      new.coverage_option := null; new.coverage_confirmed_at := null;
    end if;
  end if;
  return new;
end $$;

-- ================================================================ 4. the split: listed rental, kickback receivable, payable
-- 0093's split, on the new basis. The partner's revenue is the listed rental kept (scaled by what the renter kept of the
-- planned rental: a refund or a chargeback lowers it in proportion, a late return's extra days raise it; our discount,
-- the lead-time adjustment and a discount CarmaCars gave do not change it). The kickback is its percentage of that; the
-- partner is owed the rest. Kilometre overage, fees and taxes stay with CarmaCars. A booking still on 0093's markup keeps
-- 0093's split (the overage shared). A part already on a statement is not rewritten: a later refund's share goes on the
-- next statement.
create or replace function app.compute_booking_split_pre0156(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s booking_splits;
  v_before uuid[];
  v_planned bigint;
  v_base bigint;
  v_old boolean;
  v_rev bigint; v_share bigint; v_pay bigint; v_prior bigint; v_delta bigint;
  n integer;
begin
  select * into b from bookings where id = p_booking;
  select coalesce(array_agg(id), '{}') into v_before from owner_deductions where booking_id = p_booking;
  update booking_splits set partner_markup_cents = 0, partner_rate_basis = false, partner_sheet_cents = null, partner_kickback_cents = 0,
         owner_revenue_cents = rental_charge_cents + mileage_overage_cents - kickback_cents, company_share_cents = 0,
         owner_payout_cents = rental_charge_cents + mileage_overage_cents - kickback_cents
   where booking_id = p_booking and owner_statement_id is null and partner_rate_basis;
  perform app.compute_booking_split_pre0093(p_booking);
  if b.id is null or b.partner_cut_bps is null or b.partner_sheet_rental_cents is null or b.booking_type::text = 'owner' then return; end if;
  select count(*) into n from booking_splits where booking_id = p_booking;
  if n <> 1 then return; end if;
  select * into s from booking_splits where booking_id = p_booking and vehicle_id = b.vehicle_id;
  if s.booking_id is null then return; end if;
  v_old := b.partner_markup_bps is not null;
  select coalesce(sum(li.amount_cents), 0) into v_planned from booking_line_items li
   where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter
     and li.charge_type in ('rental_charge', 'lead_time', 'non_refundable_discount', 'staff_discount', 'promo_discount');
  v_base := case when v_planned > 0 then round(b.partner_sheet_rental_cents::numeric * greatest(s.rental_charge_cents, 0) / v_planned)::bigint else 0 end;
  v_rev := v_base + case when v_old then s.mileage_overage_cents else 0 end;
  v_share := public.calc_bps(v_rev, b.partner_cut_bps);
  v_pay := v_rev - v_share;
  if s.owner_statement_id is null then
    update booking_splits set partner_rate_basis = true, partner_sheet_cents = v_base, partner_kickback_cents = v_share,
           partner_markup_cents = rental_charge_cents + mileage_overage_cents - kickback_cents - v_rev,
           owner_revenue_cents = v_rev, company_share_bps = b.partner_cut_bps, company_share_cents = v_share, owner_payout_cents = v_pay
     where booking_id = p_booking and vehicle_id = s.vehicle_id;
  elsif s.partner_rate_basis then
    delete from owner_deductions where booking_id = p_booking and vehicle_id = s.vehicle_id and kind in ('refund_share', 'chargeback_share')
       and status = 'open' and not (id = any (v_before));
    select coalesce(sum(amount_cents), 0) into v_prior from owner_deductions
     where booking_id = p_booking and vehicle_id = s.vehicle_id and kind in ('refund_share', 'chargeback_share') and status <> 'waived';
    v_delta := s.owner_payout_cents - v_pay - v_prior;
    if v_delta > 0 then
      insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, booking_id)
      values (s.owner_id, s.vehicle_id, case when s.chargeback_cents > 0 then 'chargeback_share' else 'refund_share' end,
              format('Booking %s: the partner''s share of a later %s (on the listed rate)', b.booking_number,
                     case when s.chargeback_cents > 0 then 'chargeback' else 'refund' end),
              v_delta, app.today(), p_booking);
    end if;
  end if;
end $$;

-- The partner's statement: each rental at the listed rate, the kickback and the amount payable; never the renter's price.
select pg_temp.patch_fn('app.build_owner_statement_pre0156(uuid, date, uuid)'::regprocedure,
  $o$description = l.description || format(': at your sheet rate %s, CarmaCars %s', app.fmt_money(s.partner_sheet_cents), app.fmt_pct(s.company_share_bps))$o$,
  $n$description = l.description || format(': at your listed rate %s, less the %s kickback to CarmaCars (%s), payable to you %s',
                                              app.fmt_money(s.partner_sheet_cents), app.fmt_pct(s.company_share_bps), app.fmt_money(s.company_share_cents), app.fmt_money(s.owner_payout_cents))$n$);

-- ================================================================ 5. Admin
-- The partner's pricing: the discount and the kickback (empty: Program settings) and the basis. Every car follows.
create or replace function app.partner_pricing_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  pr partners;
  c record;
  v_dc integer := nullif(p ->> 'discount_bps', '')::integer;
  v_cm integer := nullif(coalesce(p ->> 'kickback_bps', p ->> 'commission_bps'), '')::integer;
begin
  perform app.assert_admin(p_by);
  select * into pr from partners where id = nullif(p ->> 'id', '')::uuid for update;
  if pr.id is null then raise exception 'Partner not found' using errcode = 'P0002'; end if;
  if v_dc is not null and (v_dc < 0 or v_dc > 9000) then raise exception 'The discount is between 0%% and 90%%' using errcode = '22023'; end if;
  if v_cm is not null and (v_cm < 0 or v_cm > 10000) then raise exception 'The kickback is between 0%% and 100%%' using errcode = '22023'; end if;
  if coalesce(p ->> 'payout_basis', pr.payout_basis) not in ('renter_price', 'partner_rate') then raise exception 'Unknown basis' using errcode = '22023'; end if;
  update partners set discount_bps = case when p ? 'discount_bps' then v_dc else discount_bps end,
         commission_bps = case when p ? 'kickback_bps' or p ? 'commission_bps' then v_cm else commission_bps end,
         payout_basis = coalesce(nullif(p ->> 'payout_basis', ''), payout_basis)
   where id = pr.id returning * into pr;
  for c in select v.id from vehicles v join partner_rates r on r.vehicle_id = v.id where v.partner_id = pr.id and v.retired_at is null loop
    perform app.partner_rates_apply(c.id, p_by);
  end loop;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'partner_pricing', 'partners', pr.id::text, jsonb_build_object('discount_bps', pr.discount_bps, 'kickback_bps', pr.commission_bps, 'payout_basis', pr.payout_basis));
  return app.partner_row(pr);
end $$;

-- One partner car: its listed rates, its own discount and kickback (empty: the partner's), the two flags, the year.
create or replace function app.partner_car_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  r partner_rates;
  v_b bigint := nullif(p ->> 'base_cents', '')::bigint;
  v_m bigint := nullif(p ->> 'multi_day_cents', '')::bigint;
  v_l bigint := nullif(p ->> 'long_term_cents', '')::bigint;
  v_kb text := case when p ? 'kickback_bps' then p ->> 'kickback_bps' when p ? 'commission_bps' then p ->> 'commission_bps' end;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for update;
  if v.id is null or v.supply_type <> 'partner' then raise exception 'Choose a partner car' using errcode = '22023'; end if;
  select * into r from partner_rates where vehicle_id = v.id;
  v_b := coalesce(v_b, r.base_cents); v_m := coalesce(v_m, r.multi_day_cents, v_b); v_l := coalesce(v_l, r.long_term_cents, v_m);
  if v_b is null or v_b <= 0 or v_m <= 0 or v_l <= 0 then raise exception 'Enter the partner''s three listed rates a day (1 to 2 days, 3 or more, 7 or more)' using errcode = '22023'; end if;
  if v_m > v_b or v_l > v_m then raise exception 'The rate a day goes down with the length: 1 to 2 days, then 3 or more, then 7 or more' using errcode = '22023'; end if;
  if (p ? 'discount_bps') and nullif(p ->> 'discount_bps', '')::integer not between 0 and 9000 then raise exception 'The discount is between 0%% and 90%%' using errcode = '22023'; end if;
  if v_kb is not null and nullif(v_kb, '')::integer not between 0 and 10000 then raise exception 'The kickback is between 0%% and 100%%' using errcode = '22023'; end if;
  if nullif(p ->> 'year', '') is not null and (p ->> 'year')::integer not between 1980 and 2100 then raise exception 'Enter the model year' using errcode = '22023'; end if;
  insert into partner_rates (vehicle_id, base_cents, multi_day_cents, long_term_cents, source, updated_by)
  values (v.id, v_b, v_m, v_l, coalesce(nullif(p ->> 'source', ''), 'Admin'), p_by)
  on conflict (vehicle_id) do update set base_cents = excluded.base_cents, multi_day_cents = excluded.multi_day_cents, long_term_cents = excluded.long_term_cents,
    source = excluded.source, updated_by = excluded.updated_by;
  update vehicles set partner_discount_bps = case when p ? 'discount_bps' then nullif(p ->> 'discount_bps', '')::integer else partner_discount_bps end,
         commission_bps = case when v_kb is not null then nullif(v_kb, '')::integer else commission_bps end,
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
    'kickback_bps', v.commission_bps, 'kickback_effective_bps', app.partner_commission_bps(v.id),
    'discount_bps', v.partner_discount_bps, 'discount_effective_bps', app.partner_discount_bps(v.id),
    'insurance_included', v.insurance_included, 'no_credit_card', v.no_credit_card,
    'base_cents', r.base_cents, 'multi_day_cents', r.multi_day_cents, 'long_term_cents', r.long_term_cents,
    'renter_daily_cents', rc.daily_rate_cents, 'renter_weekend_cents', rc.weekend_rate_cents, 'renter_multi_day_cents', rc.multi_day_rate_cents,
    'renter_long_term_cents', case when rc.weekly_rate_cents is not null then round(rc.weekly_rate_cents / 7.0)::bigint end,
    'listing_status', l.status, 'slug', l.slug, 'real_photos', exists (select 1 from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status <> 'rejected'))
    from vehicles v
    left join partner_rates r on r.vehicle_id = v.id
    left join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
    left join vehicle_listings l on l.vehicle_id = v.id
   where v.id = p_vehicle
$$;

-- Admin > Partners > a partner: the discount and the kickback, and the money: each rental's listed amount, kickback
-- receivable, amount payable and our own part; the totals not yet on a statement.
alter function app.partner_detail(uuid, uuid) rename to partner_detail_pre0361;
create function app.partner_detail(p_by uuid, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  d jsonb := app.partner_detail_pre0361(p_by, p_id);
  pr partners;
begin
  if d is null then return d; end if;
  select * into pr from partners where id = p_id;
  return d || jsonb_build_object(
    'discount_bps', pr.discount_bps, 'discount_effective_bps', coalesce(pr.discount_bps, (app.settings()).partner_discount_bps),
    'kickback_bps', pr.commission_bps, 'kickback_effective_bps', coalesce(pr.commission_bps, (app.settings()).partner_commission_bps),
    'money', jsonb_build_object(
      'rentals', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'vehicle', app.vehicle_name(s.vehicle_id),
                     'pickup_at', b.pickup_at, 'listed_cents', s.partner_sheet_cents, 'kickback_bps', s.company_share_bps, 'kickback_cents', s.partner_kickback_cents,
                     'payable_cents', s.owner_payout_cents, 'rental_cents', s.rental_charge_cents, 'ours_cents', s.partner_markup_cents,
                     'on_statement', s.owner_statement_id is not null, 'markup_model', b.partner_markup_bps is not null) order by b.pickup_at desc)
                   from (select x.*, b0.pickup_at from booking_splits x join bookings b0 on b0.id = x.booking_id
                          where x.owner_id = pr.owner_id and x.partner_rate_basis and x.status <> 'reversed'
                          order by b0.pickup_at desc limit 50) s join bookings b on b.id = s.booking_id), '[]'::jsonb),
      'open_listed_cents', (select coalesce(sum(s.partner_sheet_cents), 0) from booking_splits s where s.owner_id = pr.owner_id and s.partner_rate_basis and s.status <> 'reversed' and s.owner_statement_id is null),
      'open_kickback_cents', (select coalesce(sum(s.partner_kickback_cents), 0) from booking_splits s where s.owner_id = pr.owner_id and s.partner_rate_basis and s.status <> 'reversed' and s.owner_statement_id is null),
      'open_payable_cents', (select coalesce(sum(s.owner_payout_cents), 0) from booking_splits s where s.owner_id = pr.owner_id and s.partner_rate_basis and s.status <> 'reversed' and s.owner_statement_id is null)));
end $$;

-- The partner agreement's facts carry the discount (web/src/features/partner/agreement.ts, partner-v4)
select pg_temp.patch_fn('app.partner_agreement_facts(uuid)'::regprocedure,
  $o$    'markup_bps', coalesce(r.markup_bps, (app.settings()).partner_markup_bps),$o$,
  $n$    'discount_bps', coalesce(r.discount_bps, (app.settings()).partner_discount_bps),$n$);
select pg_temp.patch_fn('app.partner_agreement_facts(uuid)'::regprocedure,
  $o$'markup_bps', app.partner_markup_bps(v.id),$o$,
  $n$'discount_bps', app.partner_discount_bps(v.id),$n$);

-- ================================================================ 6. the data
-- the partners: no markup; a partner that had one takes the 10% discount in its place (01 Motors); the kickback stays
update partners set discount_bps = (select partner_discount_bps from program_settings order by effective_from desc limit 1)
 where markup_bps is not null and discount_bps is null;
update partners set markup_bps = null where markup_bps is not null;
update vehicles set partner_markup_bps = null where partner_markup_bps is not null;
-- each partner car's rate card from its listed rates
do $$
declare
  c record;
begin
  for c in select v.id from vehicles v join partner_rates r on r.vehicle_id = v.id where v.retired_at is null order by v.id loop
    perform app.partner_rates_apply(c.id, null);
  end loop;
end $$;
-- requests not yet offered on a partner car: the new rates and basis (a price typed by hand stays). Offers out and
-- confirmed bookings keep their locked prices.
do $$
declare
  b bookings;
  rc rate_cards;
  r record;
begin
  for b in select x.* from bookings x where x.partner_markup_bps is not null and x.status::text in ('requested', 'tentative') order by x.id loop
    select * into rc from rate_cards c where c.vehicle_id = b.vehicle_id and c.effective_from <= now() and (c.effective_to is null or c.effective_to > now());
    if rc.id is null then continue; end if;
    select * into r from public.calc_rental_charge(b.pickup_at, b.billable_days, rc.daily_rate_cents, rc.weekend_rate_cents, rc.weekly_rate_cents,
                                                   rc.monthly_rate_cents, 'America/Toronto', rc.multi_day_rate_cents);
    update bookings
       set rate_card_id = rc.id, daily_rate_cents = rc.daily_rate_cents, weekend_rate_cents = rc.weekend_rate_cents,
           weekly_rate_cents = rc.weekly_rate_cents, monthly_rate_cents = rc.monthly_rate_cents, multi_day_rate_cents = rc.multi_day_rate_cents,
           rate_applied = r.rate_applied, daily_days = r.daily_days, weekend_days = r.weekend_days,
           rental_charge_cents = case when b.custom_price_at is null then r.rental_charge_cents else b.rental_charge_cents end,
           discount_cents = case when b.booking_type::text = 'non_refundable'
                                 then public.calc_bps(case when b.custom_price_at is null then r.rental_charge_cents else b.rental_charge_cents end,
                                                      (app.settings(app.local_date(b.booked_at))).non_refundable_discount_bps) else 0 end,
           partner_markup_bps = null, partner_discount_bps = app.partner_discount_bps(b.vehicle_id), partner_cut_bps = app.partner_commission_bps(b.vehicle_id)
     where id = b.id;
    perform app.sync_booking_price(b.id);
  end loop;
end $$;

-- ================================================================ privileges
do $$
declare
  g text;
begin
  execute 'revoke all on function app.partner_detail(uuid, uuid) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.partner_detail_pre0361(uuid, uuid)'::regprocedure, 'execute') then
      execute format('grant execute on function app.partner_detail(uuid, uuid) to %I', g);
    end if;
  end loop;
  execute 'revoke all on function app.partner_detail_pre0361(uuid, uuid) from public, anon, authenticated';
  execute 'grant execute on function app.partner_detail_pre0361(uuid, uuid) to service_role';
end $$;
revoke all on function app.partner_discount_bps(uuid, date) from public, anon, authenticated;
grant execute on function app.partner_discount_bps(uuid, date) to service_role;
grant execute on function app.partner_selling_cents(bigint, integer) to anon, authenticated, service_role;
