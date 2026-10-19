-- 0058_staff_commissions.sql
-- The owner's decisions of October 18, 2026 on staff commissions (docs/changes/2026-10-18-staff-commissions.md):
--   1. rates: staff outside the Sales function (customer service, finance, fleet, field staff) earn a flat
--      staff_commission_bps (10% by default) of the rental charge of each rental they sourced. Sales earns by tier on the
--      rental days of the completed, paid, sourced rentals ending in a calendar month: under sales_tier_mid_days (50) days
--      sales_tier_low_bps (10%), from 50 sales_tier_mid_bps (15%), from sales_tier_high_days (100, also the month's target)
--      sales_tier_high_bps (20%); the month's tier applies to all of that month's rentals, recalculated as rentals are added
--      or refunded and once more after the month ends. An Admin may give one person a flat rate (staff_profiles.commission_bps).
--      The rental charge is counted like booked revenue in My sales (app.sales_revenue_cents: before tax, after discounts,
--      net of refunds and cancellations). Earned when the rental is completed and paid in full; none on a cancelled,
--      refunded, charged-back or unpaid booking, nor on a staff member's own or household rental. A later refund or
--      chargeback reverses it, or the difference when a month drops below a tier (taken off the next payout once paid).
--   2. every staff function (customer service, finance, fleet, sales) and field staff add rentals; assistants of every
--      function take quotes. Each rental, quote and offer a staff member enters carries a required choice: "I sourced
--      this client" or "Entered for CarmaCars". A website request earns nothing unless an Admin credits someone. An Admin
--      may change the sourced flag and the person credited, with a reason (kept in the booking's history and the audit log).
--   3. custom prices: any staff member may type the rental charge on a rental or a quote, with a reason; the rate-sheet
--      price is kept beside it; a price under the floor (custom_price_floor_daily_cents, no floor by default) or a discount
--      over custom_price_max_discount_bps (20% by default) is flagged on the booking and in Admin To do, never blocked.
--   4. commissions accrue per person; an Admin approves them (one by one or together; a Sales month once it has ended)
--      before anything is paid; an approved commission is paid by hand (e-Transfer, bank transfer, Wise, cash, other, or on
--      the monthly pay statement) with its method, reference and date. Nothing is paid automatically. Staff are told when a
--      commission is approved and paid.
--   5. owners: every kickback on a booking is deducted before Owner Revenue (Enrollment Agreement 8.1 and 8.3, which now
--      name Staff Commissions as kickbacks): on a program owner's car the staff commissions (Sales tiers or the flat rate,
--      field staff referral fees included) and an Owner's Referral Kickback are expenses of the booking before the Revenue
--      Share, each its own line on the owner statement. A change after a statement (a refund, the month's tier) goes on the
--      next statement as an adjustment line. A partner's car: from CarmaCars' own commission. A CarmaCars-owned car: a
--      CarmaCars expense.
--   6. the field staff referral fee becomes the same commission: a referral code on a booking credits the field staff
--      member as having sourced it.
-- No applied migration is edited.

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists staff_commission_bps integer not null default 1000 check (staff_commission_bps between 0 and 10000),
  add column if not exists sales_tier_low_bps integer not null default 1000 check (sales_tier_low_bps between 0 and 10000),
  add column if not exists sales_tier_mid_bps integer not null default 1500 check (sales_tier_mid_bps between 0 and 10000),
  add column if not exists sales_tier_high_bps integer not null default 2000 check (sales_tier_high_bps between 0 and 10000),
  add column if not exists sales_tier_mid_days integer not null default 50 check (sales_tier_mid_days between 1 and 1000),
  add column if not exists sales_tier_high_days integer not null default 100 check (sales_tier_high_days between 1 and 1000),
  add column if not exists custom_price_floor_daily_cents bigint check (custom_price_floor_daily_cents is null or custom_price_floor_daily_cents >= 0),
  add column if not exists custom_price_max_discount_bps integer not null default 2000 check (custom_price_max_discount_bps between 0 and 10000);
alter table program_settings drop constraint if exists program_settings_sales_tiers_check;
alter table program_settings add constraint program_settings_sales_tiers_check check (sales_tier_high_days > sales_tier_mid_days);
comment on column program_settings.staff_commission_bps is 'Staff commission outside the Sales function (customer service, finance, fleet, field staff; 0058): the share of the rental charge of a rental they sourced, 10% by default. It is also the field staff referral fee';
comment on column program_settings.sales_tier_low_bps is 'Sales commission under sales_tier_mid_days rental days in the month (0058), 10% by default';
comment on column program_settings.sales_tier_mid_bps is 'Sales commission from sales_tier_mid_days rental days in the month (0058), 15% by default';
comment on column program_settings.sales_tier_high_bps is 'Sales commission from sales_tier_high_days rental days in the month (0058), 20% by default';
comment on column program_settings.sales_tier_mid_days is 'Rental days in a month (completed, paid, sourced rentals ending that month) for the middle Sales tier (0058), 50 by default';
comment on column program_settings.sales_tier_high_days is 'Rental days in a month for the top Sales tier, and the month''s target on My sales and the scorecard (0058), 100 by default';
comment on column program_settings.custom_price_floor_daily_cents is 'A rental charge typed by hand under this amount a day is flagged for an Admin (0058). Empty: no floor';
comment on column program_settings.custom_price_max_discount_bps is 'A rental charge typed by hand more than this far under the rate sheet is flagged for an Admin (0058), 20% by default';

alter table staff_profiles
  add column if not exists commission_bps integer check (commission_bps is null or commission_bps between 0 and 10000),
  add column if not exists home_address text,
  add column if not exists home_postal_code text;
comment on column staff_profiles.commission_bps is 'A flat commission rate an Admin set for this person (0058), in place of the Program setting or the Sales tiers; empty: the Program settings';
comment on column staff_profiles.home_address is 'Home address (0058), used only to recognize a household rental, which earns no commission';
comment on column staff_profiles.home_postal_code is 'Home postal code (0058), used only to recognize a household rental';

-- ================================================================ 2. sourced or entered for CarmaCars
alter table bookings
  add column if not exists sales_sourced boolean not null default false,
  add column if not exists sales_choice text check (sales_choice in ('sourced', 'for_carmacars')),
  add column if not exists sales_choice_by uuid references users(id),
  add column if not exists sales_choice_at timestamptz,
  add column if not exists sales_claim_by uuid references users(id),
  add column if not exists sales_claim_at timestamptz,
  add column if not exists rate_sheet_rental_cents bigint,
  add column if not exists custom_price_reason text,
  add column if not exists custom_price_by uuid references users(id),
  add column if not exists custom_price_at timestamptz,
  add column if not exists price_flags text[] not null default '{}',
  add column if not exists price_reviewed_at timestamptz,
  add column if not exists price_reviewed_by uuid references users(id),
  add column if not exists price_review_note text;
alter table bookings drop constraint if exists bookings_sales_source_check;
alter table bookings add constraint bookings_sales_source_check check (sales_source in ('quote', 'offer', 'manual_rental', 'admin', 'referral'));
alter table bookings drop constraint if exists bookings_sales_sourced_credit;
alter table bookings add constraint bookings_sales_sourced_credit check (not sales_sourced or sales_staff_id is not null);
alter table bookings drop constraint if exists bookings_price_flags_check;
alter table bookings add constraint bookings_price_flags_check check (price_flags <@ array['below_floor', 'discount_over_limit']::text[]);
comment on column bookings.sales_sourced is 'The person credited (sales_staff_id) sourced this client and earns the staff commission (0058). False: entered for CarmaCars, or a website request no Admin credited';
comment on column bookings.sales_choice is 'What the staff member who entered the rental, quote or offer chose (0058): sourced ("I sourced this client") or for_carmacars ("Entered for CarmaCars")';
comment on column bookings.sales_claim_by is 'A staff member said "I sourced this client" on an offer for a website request (0058): waiting for an Admin to credit them or not';
comment on column bookings.rate_sheet_rental_cents is 'The rate-sheet rental charge when a price was typed by hand (0058); rental_charge_cents holds the price charged';
comment on column bookings.price_flags is 'A price typed by hand under the floor (below_floor) or past the discount limit (discount_over_limit): flagged for an Admin, never blocked (0058)';
create index if not exists bookings_price_flags_idx on bookings (custom_price_at) where price_flags <> '{}' and price_reviewed_at is null;
create index if not exists bookings_sales_claim_idx on bookings (sales_claim_at) where sales_claim_by is not null;

drop trigger if exists bookings_guard_commission_columns on bookings;
create trigger bookings_guard_commission_columns before update on bookings
  for each row execute function app.guard_admin_columns('sales_sourced', 'sales_choice', 'sales_choice_by', 'sales_choice_at', 'sales_claim_by', 'sales_claim_at',
    'rate_sheet_rental_cents', 'custom_price_reason', 'custom_price_by', 'custom_price_at', 'price_flags', 'price_reviewed_at', 'price_reviewed_by', 'price_review_note');

-- Staff who may be credited: an active assistant, an Admin or active field staff.
create or replace function app.user_is_sales_staff(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (app.user_is_staff(p_user) or app.user_is_field(p_user))
$$;

-- The choice travels with the transaction (app.sales_choice, set by the functions below for the call that creates the
-- booking). A booking a staff member creates is credited to them (0057's trigger; field staff here) and is sourced when
-- they chose so. A referral code of a field staff member on a booking nobody sourced credits that person as its source
-- (the referral fee is the commission, 0058).
create or replace function app.bookings_sales_sourced() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_choice text := nullif(current_setting('app.sales_choice', true), '');
  v_field boolean;
begin
  if tg_op = 'INSERT' and new.created_by is not null and new.source not in ('web', 'owner') and new.booking_type <> 'owner' then
    v_field := app.user_is_field(new.created_by);
    if new.sales_staff_id is null and new.sales_source is null and v_field then
      new.sales_staff_id := new.created_by;
      new.sales_source := case when new.added_by_staff then 'manual_rental' else 'quote' end;
      new.sales_attributed_at := coalesce(new.created_at, now());
      new.sales_attributed_by := new.created_by;
    end if;
    if v_choice in ('sourced', 'for_carmacars') and new.sales_staff_id = new.created_by then
      new.sales_choice := v_choice;
      new.sales_choice_by := new.created_by;
      new.sales_choice_at := now();
      new.sales_sourced := v_choice = 'sourced';
    end if;
  end if;
  -- a field staff member's referral code: they sourced the client, unless someone already did
  if new.referrer_type = 'field_staff' and new.referrer_staff_id is not null and not new.sales_sourced
     and (tg_op = 'INSERT' or old.referrer_staff_id is distinct from new.referrer_staff_id)
     and new.booking_type <> 'owner' and (new.sales_source is distinct from 'admin') then
    new.sales_staff_id := new.referrer_staff_id;
    new.sales_source := 'referral';
    new.sales_sourced := true;
    new.sales_attributed_at := coalesce(new.sales_attributed_at, new.created_at, now());
    new.sales_attributed_by := new.referrer_staff_id;
  end if;
  return new;
end $$;
drop trigger if exists bookings_sales_sourced on bookings;
create trigger bookings_sales_sourced before insert or update of referrer_staff_id on bookings
  for each row execute function app.bookings_sales_sourced();

-- The first offer on a request nobody is credited with still credits its sender for tracking (0057); a field staff
-- member's referral credited at insert is kept.

-- A field staff member's referral earns the staff commission (0058), deducted before Owner Revenue as a Staff Commission
-- on a program owner's car (section 9); the 20% field staff Referral Kickback of 0007 is not taken as well. Only an Owner's
-- referral is a Referral Kickback.
alter function app.kickback_ineligible_reason(uuid) rename to kickback_ineligible_reason_0007;
create or replace function app.kickback_ineligible_reason(p_booking uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
begin
  if exists (select 1 from bookings b where b.id = p_booking and b.referrer_type = 'field_staff') then
    return 'staff referral: earns the staff commission instead';
  end if;
  return app.kickback_ineligible_reason_0007(p_booking);
end $$;

-- ================================================================ 3. custom prices
-- The flags of a price typed by hand: under the floor a day, or a discount past the limit from the rate sheet.
create or replace function app.custom_price_flags(p_cents bigint, p_rate_sheet bigint, p_days integer) returns text[]
language sql stable security definer set search_path = public, app as $$
  select array_remove(array[
    case when (app.settings()).custom_price_floor_daily_cents is not null and p_cents < (app.settings()).custom_price_floor_daily_cents * greatest(coalesce(p_days, 1), 1)
         then 'below_floor' end,
    case when coalesce(p_rate_sheet, 0) > 0 and (p_rate_sheet - p_cents) * 10000 > p_rate_sheet * (app.settings()).custom_price_max_discount_bps
         then 'discount_over_limit' end], null)
$$;

-- The rate-sheet rental charge of a booking, from the rates it carries (as app.adjust_booking computes it).
create or replace function app.booking_rate_sheet_cents(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select (public.calc_rental_charge(b.pickup_at, b.billable_days, b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents)).rental_charge_cents
    from bookings b where b.id = p_booking
$$;

-- Record a price typed by hand on a booking whose rental_charge_cents already holds it (or set it now when p_set).
-- p_rate_sheet: the rate-sheet price beside it. The same price as the rate sheet clears the custom price.
create or replace function app.record_custom_price(p_booking uuid, p_by uuid, p_cents bigint, p_rate_sheet bigint, p_reason text, p_set boolean default false)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_flags text[];
begin
  select * into b from bookings where id = p_booking for update;
  if p_cents is null or p_cents < 0 then raise exception 'Enter the price as an amount' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for the price' using errcode = '22023'; end if;
  if p_set then
    update bookings set rental_charge_cents = p_cents,
           discount_cents = case when booking_type = 'non_refundable' then public.calc_bps(p_cents, (app.settings(app.local_date(b.booked_at))).non_refundable_discount_bps) else 0 end
     where id = p_booking;
  end if;
  if p_rate_sheet is not null and p_cents = p_rate_sheet then
    update bookings set rate_sheet_rental_cents = null, custom_price_reason = null, custom_price_by = null, custom_price_at = null, price_flags = '{}',
           price_reviewed_at = null, price_reviewed_by = null, price_review_note = null where id = p_booking;
  else
    v_flags := app.custom_price_flags(p_cents, p_rate_sheet, b.billable_days);
    update bookings set rate_sheet_rental_cents = p_rate_sheet, custom_price_reason = btrim(p_reason), custom_price_by = p_by, custom_price_at = now(),
           price_flags = v_flags, price_reviewed_at = null, price_reviewed_by = null, price_review_note = null
     where id = p_booking;
    perform app.log_booking_event(p_booking, 'custom_price', null, b.status::text, null,
      format('Price typed by hand: %s (rate sheet %s). %s', app.fmt_money(p_cents), coalesce(app.fmt_money(p_rate_sheet), 'none'), btrim(p_reason)), p_by, 'staff',
      jsonb_build_object('cents', p_cents, 'rate_sheet_cents', p_rate_sheet, 'reason', btrim(p_reason), 'flags', to_jsonb(v_flags)));
  end if;
  if p_set then perform app.sync_booking_price(p_booking); end if;
end $$;

-- 0016's adjust_booking, with prices typed by hand open to every staff function (0058): rental_charge_cents with a
-- reason (price_reason; an Admin's falls back on the note). The rate-sheet price is kept beside it. A custom price stays
-- while the car, dates and rate type stay; changing one of those goes back to the rate sheet.
alter function app.adjust_booking(uuid, uuid, jsonb, text) rename to adjust_booking_0016;
create or replace function app.adjust_booking(p_booking uuid, p_by uuid, p_changes jsonb, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  b0 bookings;
  b bookings;
  v_custom bigint := nullif(p_changes ->> 'rental_charge_cents', '')::bigint;
  v_reason text := nullif(btrim(coalesce(p_changes ->> 'price_reason', '')), '');
  v_changes jsonb := coalesce(p_changes, '{}'::jsonb) - 'price_reason';
  v_admin boolean := app.user_is_admin(p_by);
begin
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' then
    raise exception 'Give the changes as a JSON object' using errcode = '22023';
  end if;
  select * into b0 from bookings where id = p_booking;
  if v_custom is not null and not v_admin then
    if not app.user_is_sales_staff(p_by) then raise exception 'Only staff adjust a booking request' using errcode = '42501'; end if;
    if v_reason is null then raise exception 'Give the reason for the price typed by hand' using errcode = '22023'; end if;
  end if;
  -- the rates price the booking first; a typed price goes on top
  v_changes := v_changes - 'rental_charge_cents';
  perform app.adjust_booking_0016(p_booking, p_by, v_changes, p_note);
  select * into b from bookings where id = p_booking;
  if v_custom is not null then
    perform app.record_custom_price(p_booking, p_by, v_custom, b.rental_charge_cents, coalesce(v_reason, p_note, 'Set by an Admin'), true);
  elsif b0.custom_price_at is not null then
    if b.vehicle_id = b0.vehicle_id and b.pickup_at = b0.pickup_at and b.return_at = b0.return_at and b.booking_type = b0.booking_type then
      -- unchanged terms: the typed price stays
      update bookings set rental_charge_cents = b0.rental_charge_cents,
             discount_cents = case when booking_type = 'non_refundable' then public.calc_bps(b0.rental_charge_cents, (app.settings(app.local_date(b.booked_at))).non_refundable_discount_bps) else 0 end,
             rate_sheet_rental_cents = b.rental_charge_cents,
             price_flags = app.custom_price_flags(b0.rental_charge_cents, b.rental_charge_cents, b.billable_days)
       where id = p_booking;
      perform app.sync_booking_price(p_booking);
    else
      update bookings set rate_sheet_rental_cents = null, custom_price_reason = null, custom_price_by = null, custom_price_at = null, price_flags = '{}',
             price_reviewed_at = null, price_reviewed_by = null, price_review_note = null where id = p_booking;
      perform app.log_booking_event(p_booking, 'custom_price', null, b.status::text, null,
        'The car, dates or rate type changed: the price is the rate sheet''s again', p_by, 'staff', jsonb_build_object('cleared', true));
    end if;
  end if;
end $$;

-- An assistant may type the rental charge with its reason (0058); the rest of 0031's rule stands.
create or replace function app.va_guard_booking_edit(p_fn text, p jsonb) returns void
language plpgsql stable security definer set search_path = public, app as $$
declare
  k text;
begin
  if jsonb_typeof(coalesce(p -> 'changes', '{}'::jsonb)) <> 'object' then raise exception 'The changes are a list of columns' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(coalesce(p -> 'changes', '{}'::jsonb)) loop
    if k not in ('vehicle_id', 'pickup_at', 'return_at', 'booking_type', 'km_allowance_per_day', 'bill_to', 'insurer_id', 'insurer_claim_number',
                 'insurer_adjuster_name', 'insurer_adjuster_email', 'insurer_adjuster_phone', 'insurer_authorized_until', 'insurer_authorized_days', 'dates_provisional',
                 'rental_charge_cents', 'price_reason') then
      raise exception 'Only an Admin changes %: ask an Admin from the task', replace(k, '_', ' ') using errcode = '42501';
    end if;
  end loop;
  if p -> 'changes' ? 'rental_charge_cents' and nullif(btrim(coalesce(p #>> '{changes,price_reason}', '')), '') is null then
    raise exception 'Give the reason for the price typed by hand' using errcode = '22023';
  end if;
  if p ? 'fee_terms' or p ? 'blocks_calendar' then
    raise exception 'Only an Admin changes fees or the calendar switch on a booking' using errcode = '42501';
  end if;
  if p ? 'coverage_cents' and p_fn <> 'cs' then
    raise exception 'Only customer service or an Admin prices coverage' using errcode = '42501';
  end if;
  if p ->> 'expires_at' is not null and (p ->> 'expires_at')::timestamptz > now() + interval '48 hours 5 minutes' then
    raise exception 'An assistant''s offer is open for 48 hours at most' using errcode = '23514';
  end if;
end $$;

-- An Admin marks a flagged price as reviewed. p: {booking, note}
create or replace function app.price_review(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking' for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.custom_price_at is null then raise exception 'This booking has no price typed by hand' using errcode = '23514'; end if;
  update bookings set price_reviewed_at = now(), price_reviewed_by = p_by, price_review_note = nullif(btrim(coalesce(p ->> 'note', '')), '') where id = b.id;
  perform app.log_booking_event(b.id, 'custom_price', null, b.status::text, null,
    'Price reviewed by an Admin' || coalesce('. ' || nullif(btrim(coalesce(p ->> 'note', '')), ''), ''), p_by, 'staff', jsonb_build_object('reviewed', true));
  return jsonb_build_object('booking_number', b.booking_number, 'reviewed', true);
end $$;

-- ================================================================ 4. rentals added by hand: every staff function and field staff
-- Who may add one (0058): an Admin (everything); an assistant of any function (customer service, finance, fleet, sales:
-- the rate sheet or a price typed with its reason, the promo codes and ways of payment the settings allow, never over a
-- clash, never a past rental, a payment received within their single limit); field staff (the same, with a payment link
-- or the saved card only: they take no payment themselves, Field Staff Agreement 6.1; they type the renter's details
-- and do not search renters). Returns 'admin', 'va', 'field' or null.
create or replace function app.manual_rental_role(p_by uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when app.user_is_admin(p_by) then 'admin' when app.user_is_field(p_by) then 'field' when app.user_is_staff(p_by) then 'va' end
$$;

-- 0016's staff check, plus field staff for the length of the call that adds their own rental (app.field_rental_by, set
-- only by app.manual_rental_create): the payment link of that rental is an offer sent in their name.
create or replace function app.user_is_staff(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_user) or exists (
    select 1 from user_roles r join users u on u.id = r.user_id
      join staff_profiles sp on sp.user_id = r.user_id and sp.staff_type = 'va' and sp.is_active
     where r.user_id = p_user and r.role = 'va' and u.status = 'active')
    or coalesce(p_user is not null and nullif(current_setting('app.field_rental_by', true), '') = p_user::text and app.user_is_field(p_user), false)
$$;

-- Field staff do not search renters (they type the renter's details; an existing renter is found by email).
alter function app.manual_rental_renters(uuid, text) rename to manual_rental_renters_0046;
create or replace function app.manual_rental_renters(p_by uuid, p_q text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.manual_rental_role(p_by) = 'field' then
    raise exception 'Type the renter''s details: a renter already on file is found by their email' using errcode = '42501';
  end if;
  return app.manual_rental_renters_0046(p_by, p_q);
end $$;

-- 0046's quote, with what each role may do now (a price typed by hand for everyone, the floor and discount limit that
-- flag it, the required choice, field staff's ways of payment).
create or replace function app.manual_rental_quote(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_role text := app.manual_rental_role(p_by);
  v vehicles;
  v_from timestamptz := (p ->> 'pickup_at')::timestamptz;
  v_to timestamptz := (p ->> 'return_at')::timestamptz;
  v_buffer interval := make_interval(mins => coalesce(app.turnaround_minutes(nullif(p ->> 'vehicle_id', '')::uuid), 0));
  v_quote jsonb;
  v_clash jsonb;
  s program_settings := app.settings();
  v_past boolean := coalesce((p ->> 'past')::boolean, false);
begin
  if v_role is null then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Choose the car' using errcode = '22023'; end if;
  if v_from is null or v_to is null or v_to <= v_from then raise exception 'The return must be after the pickup' using errcode = '22023'; end if;
  v_quote := app.price_quote(v.id, v_from, v_to, jsonb_build_object('booking_type', coalesce(p ->> 'booking_type', 'standard'),
               'pickup_method', coalesce(p ->> 'pickup_method', 'collected'), 'return_method', coalesce(p ->> 'return_method', 'returned'),
               'drivers', coalesce(p -> 'drivers', '[]'::jsonb), 'extras', coalesce(p -> 'extras', '{}'::jsonb),
               'coverage_option', coalesce(nullif(p ->> 'coverage_option', '')::integer, 1),
               'promo_code', case when v_role = 'admin' or s.manual_rental_va_promo then nullif(p ->> 'promo_code', '') end));
  -- what is in the way: blocking bookings and calendar blocks, with the turnaround either side; real rentals for a past one
  select coalesce(jsonb_agg(x order by x ->> 'starts_at'), '[]'::jsonb) into v_clash from (
    select jsonb_build_object('kind', 'booking', 'booking_number', b.booking_number, 'status', b.status, 'starts_at', b.pickup_at, 'ends_at', b.return_at,
                              'renter', (select split_part(r.legal_name, ' ', 1) from renters r where r.id = b.renter_id),
                              'overlaps', b.pickup_at < v_to and b.return_at > v_from) as x
      from bookings b
     where b.vehicle_id = v.id and not app.booking_is_placeholder(b.id)
       and ((not v_past and b.status in ('confirmed', 'on_rent') and b.blocks_calendar) or (v_past and b.status in ('confirmed', 'on_rent', 'returned', 'closed')))
       and b.pickup_at < v_to + v_buffer and coalesce(b.checked_in_at, b.return_at) > v_from - v_buffer
    union all
    select jsonb_build_object('kind', 'block', 'reason', k.reason, 'starts_at', k.starts_at, 'ends_at', k.ends_at, 'overlaps', true)
      from vehicle_calendar_blocks k
     where not v_past and k.vehicle_id = v.id and k.removed_at is null and k.starts_at < v_to and coalesce(k.ends_at, 'infinity'::timestamptz) > v_from) q;
  return jsonb_build_object(
    'role', v_role, 'vehicle', jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'supply_type', v.supply_type, 'retired', v.retired_at is not null,
                                                  'bookable', app.vehicle_bookable(v.id)),
    'free', jsonb_array_length(v_clash) = 0, 'clashes', v_clash, 'turnaround_minutes', extract(epoch from v_buffer) / 60,
    'quote', v_quote,
    'payment_modes', case when v_role = 'admin' then to_jsonb(array['other_way', 'link', 'card', 'unpaid']) when v_role = 'field' then to_jsonb(array['link', 'card'])
                           else to_jsonb(s.manual_rental_va_payment_modes) end,
    'may_override_price', true, 'rate_sheet_cents', (v_quote ->> 'rental_charge_cents')::bigint, 'billable_days', (v_quote ->> 'billable_days')::integer,
    'price_floor_daily_cents', s.custom_price_floor_daily_cents, 'price_max_discount_bps', s.custom_price_max_discount_bps,
    'choice_required', v_role <> 'admin', 'may_search_renters', v_role <> 'field', 'may_override_clash', v_role = 'admin', 'may_record_past', v_role = 'admin',
    'may_promo', v_role = 'admin' or s.manual_rental_va_promo,
    'single_limit_cents', (select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by),
    'card', case when nullif(p ->> 'renter_id', '') is not null then
              (select jsonb_build_object('id', pm.id, 'brand', pm.card_brand, 'last4', pm.card_last4) from payment_methods pm
                 join payment_method_secrets sc on sc.payment_method_id = pm.id
                where pm.renter_id = (p ->> 'renter_id')::uuid and pm.status = 'active' and sc.processor_method_id is not null
                order by pm.created_at desc limit 1) end);
end $$;

-- 0046's rental, with the price typed by hand open to every role and field staff's limits (0058).
create or replace function app.manual_rental_create_0058(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_role text := app.manual_rental_role(p_by);
  s program_settings := app.settings();
  v vehicles;
  rc rate_cards;
  u users;
  rn renters;
  dr drivers;
  b bookings;
  pm payment_methods;
  r jsonb := coalesce(p -> 'renter', '{}'::jsonb);
  pay jsonb := coalesce(p -> 'payment', '{}'::jsonb);
  v_mode text := coalesce(nullif(p #>> '{payment,mode}', ''), 'unpaid');
  v_from timestamptz := (p ->> 'pickup_at')::timestamptz;
  v_to timestamptz := (p ->> 'return_at')::timestamptz;
  v_past boolean := coalesce((p ->> 'past')::boolean, false);
  v_type text := coalesce(nullif(p ->> 'booking_type', ''), 'standard');
  v_source text := coalesce(nullif(p ->> 'source', ''), 'phone');
  v_clash_reason text := nullif(btrim(coalesce(p ->> 'clash_reason', '')), '');
  v_price_reason text := nullif(btrim(coalesce(p ->> 'price_reason', '')), '');
  v_override bigint := nullif(p ->> 'rental_charge_cents', '')::bigint;
  v_deposit bigint := nullif(p ->> 'deposit_cents', '')::bigint;
  v_cover integer := coalesce(nullif(p ->> 'coverage_option', '')::integer, 1);
  v_seats integer := coalesce((p -> 'extras' ->> 'baby_seats')::integer, 0);
  v_adds jsonb := case when jsonb_typeof(p -> 'additional_drivers') = 'array' then p -> 'additional_drivers' else '[]'::jsonb end;
  v_free boolean;
  v_overlap boolean;
  v_days integer;
  v_rate record;
  v_rental bigint;
  v_id uuid := gen_random_uuid();
  v_number text;
  v_email text := lower(nullif(btrim(coalesce(r ->> 'email', '')), ''));
  v_name text := nullif(btrim(coalesce(r ->> 'full_name', '')), '');
  v_dob date := nullif(r ->> 'date_of_birth', '')::date;
  v_age integer;
  a jsonb;
  v_a_age integer;
  v_driver uuid;
  v_status booking_status;
  v_pay uuid;
  v_amount bigint;
  v_method text;
  v_ref text := nullif(btrim(coalesce(pay ->> 'reference', '')), '');
  v_on date := coalesce(nullif(pay ->> 'received_on', '')::date, app.today());
  v_limit bigint;
  v_version integer;
  v_charge jsonb;
  v_promo_problem text;
begin
  if v_role is null then raise exception 'Only an Admin or a staff member adds a rental' using errcode = '42501'; end if;
  -- what an assistant or field staff may not do (0058: they may type a price, with its reason)
  if v_role in ('va', 'field') then
    if v_past then raise exception 'Recording a past rental is for an Admin' using errcode = '42501'; end if;
    if v_deposit is not null then raise exception 'The Deposit comes from the rate sheet: an Admin changes it' using errcode = '42501'; end if;
    if v_clash_reason is not null then raise exception 'The car is not free for these dates: an Admin decides on a clash' using errcode = '42501'; end if;
    -- field staff take no payment themselves (Field Staff Agreement 6.1): a payment link or the saved card only
    if not v_mode = any (case when v_role = 'field' then array['link', 'card'] else s.manual_rental_va_payment_modes end) then
      raise exception 'Taking payment that way on a rental added by hand is for an Admin' using errcode = '42501';
    end if;
    if nullif(p ->> 'promo_code', '') is not null and not s.manual_rental_va_promo then
      raise exception 'Promo codes on a rental added by hand are for an Admin' using errcode = '42501';
    end if;
  end if;
  if v_mode not in ('other_way', 'link', 'card', 'unpaid') then raise exception 'Choose how the rental is paid' using errcode = '22023'; end if;
  if v_past and v_mode in ('link', 'card') then raise exception 'A past rental is paid another way or recorded as unpaid' using errcode = '22023'; end if;
  if v_mode = 'link' and coalesce((p ->> 'do_not_email')::boolean, false) then
    raise exception 'A payment link is sent by email: untick "Do not email the renter", or record the payment another way' using errcode = '22023';
  end if;
  if v_source not in ('phone', 'walk_in', 'turo', 'partner', 'insurer', 'email', 'other') then raise exception 'Choose where the rental came from' using errcode = '22023'; end if;
  if v_source = 'other' and nullif(btrim(coalesce(p ->> 'source_note', '')), '') is null then raise exception 'Say where the rental came from' using errcode = '22023'; end if;
  if v_type not in ('standard', 'non_refundable') then raise exception 'A rental is standard or non-refundable' using errcode = '22023'; end if;
  if v_cover not in (1, 2, 3) then raise exception 'Choose how damage to the car is covered (option 1, 2 or 3)' using errcode = '22023'; end if;
  if v_override is not null and (v_override < 0 or v_price_reason is null) then raise exception 'A price typed by hand needs its reason' using errcode = '22023'; end if;

  -- the dates
  if v_from is null or v_to is null or v_to <= v_from then raise exception 'The return must be after the pickup' using errcode = '22023'; end if;
  v_days := public.calc_billable_days(v_from, v_to);
  if v_days > s.max_rental_days then
    raise exception 'A rental is 1 to % days; % asked. Longer stays renew with a new booking.', s.max_rental_days, v_days using errcode = '22023';
  end if;
  if v_past then
    if v_to > now() then raise exception 'A past rental has its return in the past' using errcode = '22023'; end if;
    if v_from < now() - make_interval(days => s.manual_rental_past_max_days) then
      raise exception 'A past rental goes back at most % days', s.manual_rental_past_max_days using errcode = '22023';
    end if;
  elsif v_to <= now() then
    raise exception 'The return is in the past: tick "Record a past rental" to keep it as completed' using errcode = '22023';
  elsif v_from < now() - interval '1 hour' then
    raise exception 'The pickup is more than an hour ago: record it as a past rental, or start it now' using errcode = '22023';
  end if;

  -- the car
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for no key update;
  if v.id is null then raise exception 'Choose the car' using errcode = '22023'; end if;
  if not v_past and not coalesce(app.vehicle_bookable(v.id), false) then
    raise exception '% is not open for new bookings (%)', app.vehicle_name(v.id), case when v.retired_at is not null then 'retired' else replace(v.status::text, '_', ' ') end using errcode = '23514';
  end if;
  select * into rc from rate_cards x where x.vehicle_id = v.id and x.effective_from <= now() and (x.effective_to is null or x.effective_to > now());
  if rc.id is null and v_override is null then raise exception 'This car has no rates set: set its rates first' using errcode = '23514'; end if;

  -- free for the dates, the turnaround included (a past rental: no other real rental at the same time)
  if v_past then
    v_free := not exists (select 1 from bookings x where x.vehicle_id = v.id and x.status in ('on_rent', 'returned', 'closed', 'confirmed')
                             and not app.booking_is_placeholder(x.id) and x.pickup_at < v_to and coalesce(x.checked_in_at, x.return_at) > v_from);
    v_overlap := false;
  else
    v_free := app.vehicle_is_available(v.id, v_from, v_to);
    v_overlap := exists (select 1 from bookings x where x.vehicle_id = v.id and x.status in ('confirmed', 'on_rent') and x.blocks_calendar
                            and x.rental_window && tstzrange(v_from, v_to, '[)'));
  end if;
  if not v_free and v_clash_reason is null then
    raise exception 'The car is not free for these dates (another rental, a calendar block or the turnaround between trips)%',
      case when v_role = 'admin' then ': give the reason to add it over the clash' else '' end using errcode = '23P01';
  end if;

  -- the renter: found, or made from what staff typed
  if nullif(p ->> 'renter_id', '') is not null then
    select * into rn from renters where id = (p ->> 'renter_id')::uuid;
    if rn.id is null then raise exception 'Renter not found' using errcode = 'P0002'; end if;
    select * into u from users where id = rn.user_id;
    select * into dr from drivers where renter_id = rn.id and is_account_holder;
  else
    if v_name is null or v_dob is null then raise exception 'Enter the renter''s full legal name and date of birth' using errcode = '22023'; end if;
    if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the renter''s email address' using errcode = '22023'; end if;
    if nullif(btrim(coalesce(r ->> 'mobile', '')), '') is null then raise exception 'Enter the renter''s phone number' using errcode = '22023'; end if;
    select * into u from users where lower(email) = v_email;
    if u.id is null then
      insert into users (email, phone, full_name) values (v_email, btrim(r ->> 'mobile'), v_name) returning * into u;
    end if;
    insert into user_roles (user_id, role) values (u.id, 'renter') on conflict do nothing;
    select * into rn from renters where user_id = u.id;
    if rn.id is null then
      insert into renters (user_id, legal_name, date_of_birth, mobile, email, address_line1, city, province, postal_code)
      values (u.id, v_name, v_dob, btrim(r ->> 'mobile'), v_email, nullif(btrim(r ->> 'address_line1'), ''), nullif(btrim(r ->> 'city'), ''),
              nullif(btrim(r ->> 'province'), ''), upper(nullif(btrim(r ->> 'postal_code'), '')))
      returning * into rn;
    end if;
    select * into dr from drivers where renter_id = rn.id and is_account_holder;
  end if;
  if rn.is_blocked then raise exception '% is blocked from renting: an Admin lifts the block first', rn.legal_name using errcode = '23514'; end if;
  if dr.id is null then
    insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, mobile, email)
    values (rn.id, true, rn.user_id, rn.legal_name, coalesce(rn.date_of_birth, v_dob), nullif(btrim(r ->> 'licence_number'), ''),
            upper(coalesce(nullif(btrim(r ->> 'licence_class'), ''), 'G')), coalesce(nullif(btrim(r ->> 'licence_issuer'), ''), 'ON'),
            nullif(r ->> 'licence_expiry', '')::date, rn.mobile, rn.email)
    returning * into dr;
  elsif nullif(btrim(r ->> 'licence_number'), '') is not null and dr.licence_number is null then
    update drivers set licence_number = btrim(r ->> 'licence_number'), licence_class = upper(coalesce(nullif(btrim(r ->> 'licence_class'), ''), licence_class, 'G')),
           licence_issuer = coalesce(nullif(btrim(r ->> 'licence_issuer'), ''), licence_issuer, 'ON'),
           licence_expiry = coalesce(nullif(r ->> 'licence_expiry', '')::date, licence_expiry)
     where id = dr.id returning * into dr;
  end if;
  v_age := app.age_on(coalesce(dr.date_of_birth, rn.date_of_birth), app.local_date(v_from));
  if v_age < s.min_renter_age then raise exception 'Every driver must be % or older at pickup', s.min_renter_age using errcode = '23514'; end if;
  if app.age_band(v_age) = '18_to_20' and not v.allows_18_to_20 then raise exception 'This car is for drivers % and over', s.standard_min_age using errcode = '23514'; end if;
  if jsonb_array_length(v_adds) > s.max_additional_drivers then
    raise exception 'A booking may name up to % additional drivers', s.max_additional_drivers using errcode = '22023';
  end if;

  -- the booking, with the rate sheet (or the Admin's price) and the source
  if v_clash_reason is not null and v_role = 'admin' and not v_past then
    perform set_config('app.manual_rental_override', 'on', true);
  end if;
  select * into v_rate from public.calc_rental_charge(v_from, v_days, coalesce(rc.daily_rate_cents, 0), coalesce(rc.weekend_rate_cents, 0),
                                                       coalesce(rc.weekly_rate_cents, 0), coalesce(rc.monthly_rate_cents, 0));
  v_rental := coalesce(v_override, v_rate.rental_charge_cents);
  v_number := 'CC-' || nextval('booking_number_seq');
  v_status := case when v_past then 'closed' when v_mode = 'link' then 'requested' else 'confirmed' end;
  insert into bookings (id, booking_number, booking_type, status, vehicle_id, renter_id, source, booked_at, requested_at, request_note,
      pickup_at, return_at, original_return_at, pickup_method, return_method, pickup_place, return_place, billable_days,
      rate_card_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days,
      rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km,
      deposit_cents, deductible_cents, hst_bps, created_by, coverage_option,
      blocks_calendar, blocks_calendar_reason, blocks_calendar_changed_by, blocks_calendar_changed_at,
      confirmed_at, handed_over_at, checked_in_at,
      added_by_staff, added_mode, payment_mode, do_not_email, clash_override_reason, notes, request_details)
  values (v_id, v_number, v_type::booking_type, v_status, v.id, rn.id,
      case when v_source in ('walk_in', 'turo', 'partner', 'insurer', 'phone', 'email', 'other') then v_source else 'staff' end,
      now(), now(), nullif(btrim(coalesce(p ->> 'note', '')), ''),
      v_from, v_to, v_to, coalesce(nullif(p ->> 'pickup_method', ''), 'collected'), coalesce(nullif(p ->> 'return_method', ''), 'returned'),
      nullif(btrim(coalesce(p ->> 'pickup_place', '')), ''), nullif(btrim(coalesce(p ->> 'return_place', '')), ''), v_days,
      rc.id, coalesce(rc.daily_rate_cents, 0), coalesce(rc.weekend_rate_cents, 0), coalesce(rc.weekly_rate_cents, 0), coalesce(rc.monthly_rate_cents, 0),
      v_rate.rate_applied, v_rate.daily_days, v_rate.weekend_days,
      v_rental, case when v_type = 'non_refundable' then public.calc_bps(v_rental, s.non_refundable_discount_bps) else 0 end,
      coalesce(rc.km_allowance_per_day, 0), coalesce(rc.km_allowance_per_day, 0) * v_days, coalesce(rc.overage_cents_per_km, 0),
      coalesce(v_deposit, rc.deposit_cents, 0), s.deductible_cents, s.hst_bps, p_by, v_cover,
      not (v_overlap and v_clash_reason is not null),
      case when v_overlap and v_clash_reason is not null then 'Added over a clash: ' || v_clash_reason end,
      case when v_overlap and v_clash_reason is not null then p_by end,
      case when v_overlap and v_clash_reason is not null then now() end,
      case when v_status in ('confirmed', 'closed') then now() end,
      case when v_past then v_from end, case when v_past then v_to end,
      true, case when v_past then 'past' else 'future' end, v_mode, coalesce((p ->> 'do_not_email')::boolean, false), v_clash_reason,
      concat_ws(E'\n', case when v_price_reason is not null then 'Price set by hand: ' || v_price_reason end,
                       case when nullif(btrim(coalesce(p ->> 'source_note', '')), '') is not null then 'Source: ' || btrim(p ->> 'source_note') end),
      jsonb_build_object('added_by_staff', true, 'source', v_source, 'source_note', nullif(btrim(coalesce(p ->> 'source_note', '')), ''),
                         'extras', jsonb_build_object('winter_tire', coalesce((p -> 'extras' ->> 'winter_tire')::boolean, false), 'baby_seats', v_seats),
                         'coverage_option', v_cover, 'price_reason', v_price_reason, 'clash_reason', v_clash_reason, 'past', v_past))
  returning * into b;

  -- drivers, as the agreement will print them
  insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, age_at_pickup, age_band)
  values (b.id, dr.id, 'renter', dr.full_name, dr.date_of_birth, dr.licence_number, dr.licence_class, dr.licence_issuer, dr.licence_expiry, v_age, app.age_band(v_age));
  for a in select value from jsonb_array_elements(v_adds) loop
    if nullif(btrim(coalesce(a ->> 'full_name', '')), '') is null or nullif(a ->> 'date_of_birth', '') is null then
      raise exception 'Each additional driver needs a full name and a date of birth' using errcode = '22023';
    end if;
    v_a_age := app.age_on((a ->> 'date_of_birth')::date, app.local_date(v_from));
    if v_a_age < s.min_renter_age then raise exception 'Every driver must be % or older at pickup', s.min_renter_age using errcode = '23514'; end if;
    if app.age_band(v_a_age) = '18_to_20' and not v.allows_18_to_20 then raise exception 'This car is for drivers % and over', s.standard_min_age using errcode = '23514'; end if;
    select d.id into v_driver from drivers d where d.renter_id = rn.id and not d.is_account_holder and d.date_of_birth = (a ->> 'date_of_birth')::date
       and lower(regexp_replace(d.full_name, '\s+', ' ', 'g')) = lower(regexp_replace(btrim(a ->> 'full_name'), '\s+', ' ', 'g')) limit 1;
    if v_driver is null then
      insert into drivers (renter_id, full_name, date_of_birth, licence_number, licence_class, licence_issuer, email)
      values (rn.id, btrim(a ->> 'full_name'), (a ->> 'date_of_birth')::date, nullif(btrim(a ->> 'licence_number'), ''), 'G', 'ON',
              lower(nullif(btrim(a ->> 'email'), '')))
      returning id into v_driver;
    end if;
    insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, age_at_pickup, age_band)
    select b.id, d.id, 'additional', d.full_name, d.date_of_birth, d.licence_number, d.licence_class, d.licence_issuer, d.licence_expiry, v_a_age, app.age_band(v_a_age)
      from drivers d where d.id = v_driver;
    v_driver := null;
  end loop;

  -- the fee terms of today, the places, the price lines
  insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, cap_cents, percent_bps, source)
  select b.id, x.code, t.amount_cents, t.cap_cents, t.percent_bps, t.source
    from unnest(array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold']) x(code)
    cross join lateral public.effective_fee(x.code, v.id, app.today()) t
  on conflict (booking_id, fee_type_code) do nothing;
  perform app.apply_booking_places(b.id, p);
  if nullif(btrim(coalesce(p ->> 'promo_code', '')), '') is not null then
    v_promo_problem := app.promo_code_problem(p ->> 'promo_code', rn.id, b.id);
    if v_promo_problem is not null then raise exception 'Promo code: %', v_promo_problem using errcode = '23514'; end if;
    perform app.apply_promo_code(b.id, p ->> 'promo_code', p_by);
  end if;
  perform app.sync_booking_price(b.id);
  select * into b from bookings where id = b.id;
  perform app.log_booking_event(b.id, 'added_by_staff', null, b.status::text, null, nullif(btrim(coalesce(p ->> 'note', '')), ''), p_by, 'staff',
    jsonb_build_object('source', v_source, 'payment_mode', v_mode, 'past', v_past, 'price_reason', v_price_reason, 'clash_reason', v_clash_reason,
                       'total_cents', b.total_due_at_booking_cents));

  -- payment
  if v_mode = 'other_way' then
    v_method := coalesce(nullif(pay ->> 'method', ''), 'e_transfer');
    v_amount := coalesce(nullif(pay ->> 'amount_cents', '')::bigint, b.renter_due_at_booking_cents);
    if v_method not in ('e_transfer', 'cheque', 'cash', 'bank_transfer', 'other') then
      raise exception 'Choose how it was paid: e-Transfer, cheque, cash, bank transfer or another way' using errcode = '22023';
    end if;
    if v_method in ('e_transfer', 'cheque', 'bank_transfer') and (v_ref is null or length(v_ref) < 3) then
      raise exception 'Enter the reference of the payment' using errcode = '22023';
    end if;
    if v_method = 'other' and nullif(btrim(coalesce(pay ->> 'note', '')), '') is null then raise exception 'Say how it was paid' using errcode = '22023'; end if;
    if v_on > app.today() then raise exception 'The date received cannot be in the future' using errcode = '22023'; end if;
    if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount received' using errcode = '22023'; end if;
    if v_role in ('va', 'field') then
      v_limit := coalesce((select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by), 0);
      if v_amount > v_limit then
        raise exception '% is above your single limit of %: an Admin records it', app.fmt_money(v_amount), app.fmt_money(v_limit) using errcode = '42501';
      end if;
    end if;
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
    values (b.id, rn.id, 'booking_total', 'charge', v_method, v_amount, 'succeeded', app.local_midnight(v_on) + interval '12 hours', p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
    values (v_pay, 'offline', v_method || ':' || coalesce(v_ref, v_pay::text), jsonb_strip_nulls(jsonb_build_object('reference', v_ref, 'received_on', v_on,
            'note', nullif(btrim(coalesce(pay ->> 'note', '')), ''), 'recorded_by', p_by, 'manual_rental', true)));
    insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by)
    values (v_pay, 'booking', b.id, rn.id, v_method, v_amount, v_on, v_ref, nullif(btrim(coalesce(pay ->> 'note', '')), ''), p_by);
    -- the booking's charges are paid by it (in full: every line; a part payment leaves them to collect)
    if v_amount >= b.renter_due_at_booking_cents then
      update booking_line_items set payment_id = v_pay where booking_id = b.id and stage = 'booking' and charged_to_renter and voided_at is null and payment_id is null;
    end if;
  elsif v_mode = 'card' then
    select x.* into pm from payment_methods x join payment_method_secrets sc on sc.payment_method_id = x.id
     where x.renter_id = rn.id and x.status = 'active' and sc.processor_method_id is not null order by x.created_at desc limit 1;
    if pm.id is null then raise exception '% has no saved card: send a payment link instead', rn.legal_name using errcode = '23514'; end if;
    update bookings set card_on_file_id = pm.id where id = b.id;
    if b.renter_due_at_booking_cents > 0 then
      v_charge := (select jsonb_build_object('customer_id', sc.processor_customer_id, 'method_id', sc.processor_method_id, 'amount_cents', b.renter_due_at_booking_cents,
                                             'brand', pm.card_brand, 'last4', pm.card_last4)
                     from payment_method_secrets sc where sc.payment_method_id = pm.id);
    end if;
  elsif v_mode = 'link' then
    -- the standard flow from here: the offer (the email with the link), the renter signs and pays online
    v_version := app.send_offer(b.id, p_by, nullif(btrim(coalesce(p ->> 'message', '')), ''),
                                now() + make_interval(hours => least(s.offer_expiry_hours, 72)));
    perform app.approve_offer(b.id, v_version, p_by);
  end if;

  -- a past rental: its split, so the owner's or partner's statement and the company statement include it
  if v_past then
    perform app.compute_booking_split(b.id);
    if b.booking_type <> 'owner' then
      update renters set first_completed_booking_id = coalesce(first_completed_booking_id, b.id) where id = rn.id;
    end if;
  end if;
  -- a confirmed rental: requests and offers that wanted the same dates go back to customer service with a task
  if b.status = 'confirmed' and b.blocks_calendar then
    perform app.raise_task(p_type => 'reoffer_booking', p_title => format('Offer another car or dates for %s: %s was booked by staff', x.booking_number, app.vehicle_name(v.id)),
        p_booking => x.id, p_vehicle => v.id, p_queue => 'cs', p_created_by => p_by, p_dedupe => 'manual_rental_clash:' || x.id)
      from bookings x where x.vehicle_id = v.id and x.id <> b.id and x.status in ('requested', 'offered', 'pending_payment')
       and x.pickup_at < b.return_at and x.return_at > b.pickup_at;
  end if;

  -- the renter's email and the owner's or partner's notice
  if b.status = 'confirmed' and not b.do_not_email then
    perform app.ntf_emit('renter_rental_added', 'booking', b.id, 'added', jsonb_build_object('booking_id', b.id, 'renter_id', rn.id));
  end if;
  if b.status = 'confirmed' and v.supply_type <> 'company' and b.booking_type <> 'owner' then
    perform app.ntf_emit('owner_new_booking', 'booking', b.id, 'confirmed', jsonb_build_object('booking_id', b.id, 'owner_id', b.owner_id));
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'manual_rental_create', 'bookings', b.id::text,
          jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'vehicle_id', v.id, 'supply_type', v.supply_type, 'renter_id', rn.id,
                             'source', v_source, 'payment_mode', v_mode, 'past', v_past, 'total_cents', b.total_due_at_booking_cents,
                             'rental_charge_cents', b.rental_charge_cents, 'price_reason', v_price_reason, 'clash_reason', v_clash_reason,
                             'blocks_calendar', b.blocks_calendar, 'payment_id', v_pay, 'do_not_email', b.do_not_email, 'role', v_role));
  select * into b from bookings where id = b.id;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'total_cents', b.total_due_at_booking_cents,
                            'due_cents', b.renter_due_at_booking_cents, 'blocks_calendar', b.blocks_calendar, 'payment_id', v_pay, 'charge', v_charge,
                            'renter_id', rn.id, 'renter_has_account', exists (select 1 from users au where au.id = rn.user_id and au.email_verified_at is not null));
end $$;

-- Add the rental (0053's wrapper, plus 0058): the choice "I sourced this client" (sales_choice = sourced) or "Entered
-- for CarmaCars" (for_carmacars) is recorded on the booking; the rate-sheet price is kept beside a price typed by hand,
-- flagged when under the floor or past the discount limit. The door requires the choice from staff (app.ops58); an
-- Admin's rental without one is entered for CarmaCars.
create or replace function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_choice text := coalesce(nullif(p ->> 'sales_choice', ''), 'for_carmacars');
  v_out jsonb;
  b bookings;
begin
  if v_choice not in ('sourced', 'for_carmacars') then raise exception 'Choose "I sourced this client" or "Entered for CarmaCars"' using errcode = '22023'; end if;
  perform set_config('app.sales_choice', v_choice, true);
  -- field staff: the offer of their own rental (a payment link) goes out in their name, as staff's does
  if app.manual_rental_role(p_by) = 'field' then perform set_config('app.field_rental_by', p_by::text, true); end if;
  v_out := app.manual_rental_create_0058(p_by, p - 'sales_choice');
  perform set_config('app.sales_choice', '', true);
  perform set_config('app.field_rental_by', '', true);
  if v_out -> 'charge' is not null and v_out -> 'charge' <> 'null'::jsonb then
    v_out := (v_out - 'charge') || jsonb_build_object('charge', null, 'charge_on_sign', true);
  end if;
  select * into b from bookings where id = (v_out ->> 'booking_id')::uuid;
  if nullif(p ->> 'rental_charge_cents', '') is not null then
    perform app.record_custom_price(b.id, p_by, b.rental_charge_cents, app.booking_rate_sheet_cents(b.id), p ->> 'price_reason', false);
  end if;
  perform app.commission_sync(b.id);
  select * into b from bookings where id = b.id;
  return v_out || jsonb_build_object('sales_choice', b.sales_choice, 'sales_sourced', b.sales_sourced, 'price_flags', to_jsonb(b.price_flags),
                                     'rate_sheet_cents', b.rate_sheet_rental_cents);
end $$;

-- ================================================================ 5. quotes: every assistant
-- 0033's quote, now taken by an assistant of any function or an Admin (0058).
create or replace function app.staff_quote_request(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_set program_settings := app.settings();
  v_email text := lower(btrim(coalesce(p_ ->> 'email', '')));
  v_name text := nullif(btrim(coalesce(p_ ->> 'full_name', '')), '');
  v_mobile text := nullif(btrim(coalesce(p_ ->> 'mobile', '')), '');
  v_dob date := nullif(p_ ->> 'date_of_birth', '')::date;
  v_class text := upper(coalesce(nullif(btrim(p_ ->> 'licence_class'), ''), 'G'));
  v_vehicle uuid := (p_ ->> 'vehicle_id')::uuid;
  v_pickup timestamptz := (p_ ->> 'pickup_at')::timestamptz;
  v_return timestamptz := (p_ ->> 'return_at')::timestamptz;
  v_source text := coalesce(nullif(p_ ->> 'source', ''), 'phone');
  v vehicles;
  u users;
  rn renters;
  dr drivers;
  v_age integer;
  v_booking uuid;
  b bookings;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'An assistant or an Admin takes a quote' using errcode = '42501'; end if;
  if v_source not in ('phone', 'email', 'whatsapp') then raise exception 'Where did the lead come from: phone, email or WhatsApp' using errcode = '22023'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'The lead''s email address is needed' using errcode = '22023'; end if;
  if v_name is null or v_mobile is null or v_dob is null then raise exception 'The lead''s full name, mobile and date of birth are needed' using errcode = '22023'; end if;
  select * into v from vehicles where id = v_vehicle;
  if v.id is null then raise exception 'Choose the car' using errcode = '22023'; end if;
  if v_pickup is null or v_return is null or v_return <= v_pickup then raise exception 'The return must be after the pickup' using errcode = '22023'; end if;
  if v_pickup < now() + make_interval(mins => v_set.booking_min_notice_minutes) then
    raise exception 'The pickup must be at least % minutes from now', v_set.booking_min_notice_minutes using errcode = '22023';
  end if;
  v_age := app.age_on(v_dob, app.local_date(v_pickup));
  if v_age < v_set.min_renter_age then raise exception 'Every driver must be % or older at pickup', v_set.min_renter_age using errcode = '23514'; end if;
  if app.age_band(v_age) = '18_to_20' and not v.allows_18_to_20 then raise exception 'This car is for drivers % and over', v_set.standard_min_age using errcode = '23514'; end if;
  if not v_class = any (select upper(x) from unnest(v_set.accepted_licence_classes) x) then
    raise exception 'A class % licence is needed', array_to_string(v_set.accepted_licence_classes, ' or ') using errcode = '23514';
  end if;

  select * into u from users where lower(email) = v_email;
  if u.id is null then
    insert into users (email, phone, full_name) values (v_email, v_mobile, v_name) returning * into u;
  elsif u.status not in ('active', 'invited') then
    raise exception 'This person cannot book online: ask an Admin' using errcode = '23514';
  end if;
  insert into user_roles (user_id, role) values (u.id, 'renter') on conflict do nothing;
  select * into rn from renters where user_id = u.id;
  if rn.id is null then
    insert into renters (user_id, legal_name, date_of_birth, mobile, email) values (u.id, v_name, v_dob, v_mobile, u.email) returning * into rn;
  end if;
  select * into dr from drivers where renter_id = rn.id and is_account_holder;
  if dr.id is null then
    insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_class, mobile, email)
    values (rn.id, true, u.id, rn.legal_name, coalesce(rn.date_of_birth, v_dob), v_class, coalesce(rn.mobile, v_mobile), u.email) returning * into dr;
  end if;
  v_age := app.age_on(dr.date_of_birth, app.local_date(v_pickup));

  v_booking := app.request_booking(rn.id, v_vehicle, v_pickup, v_return, 'standard'::booking_type, nullif(btrim(coalesce(p_ ->> 'note', '')), ''), v_source, p_by,
                                   null, null, coalesce(nullif(p_ ->> 'pickup_method', ''), 'collected'), coalesce(nullif(p_ ->> 'return_method', ''), 'returned'),
                                   nullif(btrim(coalesce(p_ ->> 'pickup_place', '')), ''), nullif(btrim(coalesce(p_ ->> 'return_place', '')), ''));
  insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, age_at_pickup, age_band)
  values (v_booking, dr.id, 'renter', dr.full_name, dr.date_of_birth, dr.licence_number, dr.licence_class, dr.licence_issuer, dr.licence_expiry, v_age, app.age_band(v_age));
  insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, cap_cents, percent_bps, source)
  select v_booking, x.code, t.amount_cents, t.cap_cents, t.percent_bps, t.source
    from unnest(array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold']) x(code)
    cross join lateral public.effective_fee(x.code, v_vehicle, app.today()) t
  on conflict (booking_id, fee_type_code) do nothing;
  update bookings set request_details = coalesce(request_details, '{}'::jsonb) || jsonb_build_object('submitted_at', now(), 'source', v_source, 'taken_by', p_by,
                        'coverage_option', (p_ ->> 'coverage_option')::integer, 'conflict_at_submit', not app.vehicle_is_available(v_vehicle, v_pickup, v_return, v_booking)),
                      coverage_option = coalesce((p_ ->> 'coverage_option')::integer, coverage_option)
   where id = v_booking;
  perform app.apply_booking_places(v_booking, jsonb_build_object('pickup_method', coalesce(nullif(p_ ->> 'pickup_method', ''), 'collected'),
    'return_method', coalesce(nullif(p_ ->> 'return_method', ''), 'returned'),
    'pickup_location', coalesce(p_ -> 'pickup_location', jsonb_build_object('kind', 'our_location')),
    'return_location', coalesce(p_ -> 'return_location', jsonb_build_object('kind', 'our_location'))));
  perform app.reprice_booking(v_booking);
  select * into b from bookings where id = v_booking;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'renter_id', rn.id,
                            'total_due_at_booking_cents', b.total_due_at_booking_cents);
end $$;

-- A quote with the choice and, if typed, a price with its reason. p: staff_quote_request's, plus sales_choice,
-- rental_charge_cents, price_reason.
create or replace function app.staff_quote_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_choice text := nullif(p ->> 'sales_choice', '');
  v_cents bigint := nullif(p ->> 'rental_charge_cents', '')::bigint;
  v_out jsonb;
  b bookings;
begin
  if v_choice is null and not app.user_is_admin(p_by) then raise exception 'Choose "I sourced this client" or "Entered for CarmaCars"' using errcode = '22023'; end if;
  v_choice := coalesce(v_choice, 'for_carmacars');
  if v_choice not in ('sourced', 'for_carmacars') then raise exception 'Choose "I sourced this client" or "Entered for CarmaCars"' using errcode = '22023'; end if;
  if v_cents is not null and nullif(btrim(coalesce(p ->> 'price_reason', '')), '') is null then raise exception 'Give the reason for the price typed by hand' using errcode = '22023'; end if;
  perform set_config('app.sales_choice', v_choice, true);
  v_out := app.staff_quote_request(p_by, p - 'sales_choice' - 'rental_charge_cents' - 'price_reason');
  perform set_config('app.sales_choice', '', true);
  select * into b from bookings where id = (v_out ->> 'booking_id')::uuid;
  if v_cents is not null then
    perform app.record_custom_price(b.id, p_by, v_cents, b.rental_charge_cents, p ->> 'price_reason', true);
  end if;
  perform app.commission_sync(b.id);
  select * into b from bookings where id = b.id;
  return v_out || jsonb_build_object('sales_choice', b.sales_choice, 'sales_sourced', b.sales_sourced, 'price_flags', to_jsonb(b.price_flags),
    'rental_charge_cents', b.rental_charge_cents, 'rate_sheet_cents', b.rate_sheet_rental_cents, 'total_due_at_booking_cents', b.total_due_at_booking_cents);
end $$;

-- ================================================================ 6. offers: the choice once per booking
-- What the sender of an offer chose, when the booking carries no choice yet. On a request a staff member entered, the
-- choice is theirs. On a website request, "I sourced this client" is a claim an Admin decides (sales_claim_by);
-- "Entered for CarmaCars" is recorded as it is. An Admin's offer needs no choice.
create or replace function app.offer_sales_choice(p_by uuid, p_booking uuid, p_choice text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.sales_choice is not null or b.sales_claim_by is not null then return; end if;
  if p_choice is null then
    if app.user_is_admin(p_by) then return; end if;
    raise exception 'Choose "I sourced this client" or "Entered for CarmaCars"' using errcode = '22023';
  end if;
  if p_choice not in ('sourced', 'for_carmacars') then raise exception 'Choose "I sourced this client" or "Entered for CarmaCars"' using errcode = '22023'; end if;
  if p_choice = 'for_carmacars' then
    update bookings set sales_choice = 'for_carmacars', sales_choice_by = p_by, sales_choice_at = now() where id = b.id;
  elsif b.created_by = p_by and b.source not in ('web', 'owner') then
    update bookings set sales_choice = 'sourced', sales_choice_by = p_by, sales_choice_at = now(), sales_sourced = (sales_staff_id = p_by) where id = b.id;
  else
    update bookings set sales_claim_by = p_by, sales_claim_at = now() where id = b.id;
    perform app.log_booking_event(b.id, 'sales_credit', null, b.status::text, null,
      format('%s says they sourced this client: an Admin decides', (select coalesce(u.full_name, u.email) from users u where u.id = p_by)), p_by, 'staff',
      jsonb_build_object('claim', p_by));
  end if;
end $$;

-- An Admin decides a claim: credit the staff member as having sourced the client, or not. p: {booking, accept, reason}
create or replace function app.sales_claim_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_accept boolean := coalesce((p ->> 'accept')::boolean, false);
  v_who text;
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking' for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.sales_claim_by is null then raise exception 'Nobody claims this booking' using errcode = '23514'; end if;
  if v_reason is null then raise exception 'Say why' using errcode = '22023'; end if;
  v_who := (select coalesce(u.full_name, u.email) from users u where u.id = b.sales_claim_by);
  if v_accept then
    update bookings set sales_staff_id = b.sales_claim_by, sales_source = 'admin', sales_sourced = true, sales_attributed_by = p_by,
           sales_attributed_at = coalesce(sales_attributed_at, now()), sales_choice = 'sourced', sales_choice_by = b.sales_claim_by,
           sales_choice_at = b.sales_claim_at, sales_claim_by = null, sales_claim_at = null
     where id = b.id;
  else
    update bookings set sales_claim_by = null, sales_claim_at = null where id = b.id;
  end if;
  perform app.log_booking_event(b.id, 'sales_credit', null, b.status::text, null,
    format('Claim by %s %s. %s', v_who, case when v_accept then 'accepted: credited as having sourced the client' else 'not accepted' end, v_reason), p_by, 'staff',
    jsonb_build_object('claim', b.sales_claim_by, 'accept', v_accept, 'reason', v_reason));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'sales_claim_decide', 'bookings', b.id::text, jsonb_build_object('staff', b.sales_claim_by, 'accept', v_accept, 'reason', v_reason));
  perform app.commission_sync(b.id);
  return jsonb_build_object('booking_number', b.booking_number, 'accepted', v_accept);
end $$;

-- An Admin gives a booking's credit to another staff member (or nobody), and says whether they sourced the client, with
-- a reason (0057's reassignment, plus the sourced flag and field staff). p: {booking, staff, sourced, reason}
create or replace function app.sales_reassign(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_staff uuid := nullif(nullif(p ->> 'staff', ''), 'none')::uuid;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_sourced boolean;
  v_from text;
  v_to text;
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking' for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_reason is null then raise exception 'Say why the credit changes' using errcode = '22023'; end if;
  if v_staff is not null and not app.user_is_sales_staff(v_staff) then raise exception 'Choose an active staff member' using errcode = '22023'; end if;
  v_sourced := v_staff is not null and coalesce(nullif(p ->> 'sourced', '')::boolean, case when v_staff = b.sales_staff_id then b.sales_sourced else false end);
  if v_staff is not distinct from b.sales_staff_id and v_sourced = b.sales_sourced and b.sales_source is not null then
    raise exception 'The booking is already credited that way' using errcode = '22023';
  end if;
  v_from := (select coalesce(u.full_name, u.email) from users u where u.id = b.sales_staff_id);
  v_to := (select coalesce(u.full_name, u.email) from users u where u.id = v_staff);
  update bookings
     set sales_staff_id = v_staff, sales_source = 'admin', sales_attributed_by = p_by, sales_sourced = v_sourced,
         sales_attributed_at = coalesce(sales_attributed_at, now()),
         sales_claim_by = case when sales_claim_by = v_staff and v_sourced then null else sales_claim_by end,
         sales_claim_at = case when sales_claim_by = v_staff and v_sourced then null else sales_claim_at end
   where id = b.id;
  perform app.log_booking_event(b.id, 'sales_credit', null, b.status::text, null,
    format('Sales credit: %s%s to %s%s. %s', coalesce(v_from, 'nobody'), case when b.sales_sourced then ' (sourced)' else '' end,
           coalesce(v_to, 'nobody'), case when v_sourced then ' (sourced)' when v_staff is not null then ' (entered for CarmaCars)' else '' end, v_reason), p_by, 'staff',
    jsonb_build_object('from', b.sales_staff_id, 'to', v_staff, 'sourced_from', b.sales_sourced, 'sourced_to', v_sourced, 'reason', v_reason));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'sales_reassign', 'bookings', b.id::text, jsonb_build_object('staff', b.sales_staff_id, 'sourced', b.sales_sourced),
          jsonb_build_object('staff', v_staff, 'sourced', v_sourced, 'reason', v_reason));
  perform app.commission_sync(b.id);
  return jsonb_build_object('booking_number', b.booking_number, 'sales_staff_id', v_staff, 'name', v_to, 'sourced', v_sourced);
end $$;

-- The staff an Admin may credit a booking to: active assistants, Admins and field staff.
create or replace function app.sales_staff_options(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', coalesce(u.full_name, u.email),
                     'function', coalesce(sp.va_function::text, case when sp.staff_type = 'field' then 'field' end, 'admin')) order by coalesce(u.full_name, u.email))
                     from users u left join staff_profiles sp on sp.user_id = u.id
                    where app.user_is_sales_staff(u.id)), '[]'::jsonb);
end $$;

-- ================================================================ 7. commissions
create table staff_commission_payouts (
  id            uuid primary key default gen_random_uuid(),
  staff_id      uuid not null references users(id),
  method        text not null check (method in ('e_transfer', 'bank_transfer', 'wise', 'cash', 'other', 'pay_statement')),
  reference     text,
  paid_on       date not null,
  pay_period    date,
  amount_cents  bigint not null check (amount_cents > 0),
  note          text,
  recorded_by   uuid not null references users(id),
  created_at    timestamptz not null default now(),
  check (method <> 'pay_statement' or pay_period is not null),
  check (method <> 'other' or nullif(btrim(coalesce(note, '')), '') is not null)
);
comment on table staff_commission_payouts is 'A payment of approved staff commissions made by hand by an Admin (0058): method, reference, date; or the month''s pay statement. Never paid automatically.';
create index staff_commission_payouts_staff_idx on staff_commission_payouts (staff_id, paid_on);

create table staff_commissions (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid not null references bookings(id),
  staff_id       uuid not null references users(id),
  kind           text not null default 'commission' check (kind in ('commission', 'clawback', 'adjustment')),
  clawback_of    uuid references staff_commissions(id),
  scheme         text check (scheme in ('flat', 'sales_tier', 'override')),
  month          date not null check (month = date_trunc('month', month)::date),
  rental_days    integer not null default 0,
  tier_days      integer,
  base_cents     bigint not null default 0,
  rate_bps       integer not null default 0,
  amount_cents   bigint not null default 0,
  status         text not null check (status in ('accruing', 'pending_approval', 'approved', 'paid', 'reversed', 'void')),
  reason         text,
  note           text,
  earned_at      timestamptz,
  approved_at    timestamptz,
  approved_by    uuid references users(id),
  payout_id      uuid references staff_commission_payouts(id),
  paid_at        timestamptz,
  reversed_at    timestamptz,
  reversed_by    uuid references users(id),
  admin_reversed boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check ((kind = 'clawback') = (amount_cents < 0) or (kind <> 'clawback' and amount_cents = 0)),
  check (kind = 'commission' or clawback_of is not null),
  check ((status = 'paid') = (payout_id is not null))
);
comment on table staff_commissions is 'Staff commissions (0058): one row per sourced booking and staff member (kind commission), its status from accruing (not earned yet) to pending approval, approved and paid, or reversed and void; clawbacks (negative, taken off the next payout) and adjustments after a payment.';
create unique index staff_commissions_one_idx on staff_commissions (booking_id, staff_id) where kind = 'commission';
create index staff_commissions_staff_idx on staff_commissions (staff_id, month, status);
create index staff_commissions_status_idx on staff_commissions (status) where status in ('pending_approval', 'approved');

alter table staff_commissions enable row level security;
alter table staff_commission_payouts enable row level security;
create policy admin_all on staff_commissions for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on staff_commission_payouts for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy own_select on staff_commissions for select to authenticated using (staff_id = app.uid());
create policy own_select on staff_commission_payouts for select to authenticated using (staff_id = app.uid());
revoke all on staff_commissions, staff_commission_payouts from anon, authenticated;
grant select on staff_commissions, staff_commission_payouts to authenticated;
grant all on staff_commissions, staff_commission_payouts to service_role;

-- Paid in full: every charge to the renter on the booking is covered by a payment that went through, and no statement
-- is left unpaid.
create or replace function app.booking_paid_in_full(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((
    select (select coalesce(sum(li.amount_cents + li.hst_cents), 0) from booking_line_items li
             where li.booking_id = b.id and li.voided_at is null and li.charged_to_renter
               and not exists (select 1 from payments py where py.id = li.payment_id and py.status = 'succeeded'))
           <= (select coalesce(sum(py.amount_cents), 0) from payments py
                where py.booking_id = b.id and py.status = 'succeeded' and py.kind in ('charge', 'capture') and py.purpose <> 'deposit'
                  and not exists (select 1 from booking_line_items l2 where l2.payment_id = py.id))
       and app.ntf_booking_balance(b.id) = 0
      from bookings b where b.id = p_booking), false)
$$;

-- Why a staff member's commission on a booking is not due: their own rental (the renter or a driver is them, by
-- account, email or phone) or their household's (the renter lives at their home address).
create or replace function app.commission_own_reason(p_booking uuid, p_staff uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  r renters;
  u users;
  sp staff_profiles;
  dig text;
begin
  select * into b from bookings where id = p_booking;
  select * into r from renters where id = b.renter_id;
  select * into u from users where id = p_staff;
  select * into sp from staff_profiles where user_id = p_staff;
  dig := regexp_replace(coalesce(u.phone, ''), '\D', '', 'g');
  if r.user_id = p_staff or lower(coalesce(r.email, '')) = lower(coalesce(u.email, '-'))
     or (length(dig) >= 7 and right(regexp_replace(coalesce(r.mobile, ''), '\D', '', 'g'), 10) = right(dig, 10))
     or exists (select 1 from booking_drivers bd join drivers d on d.id = bd.driver_id
                 where bd.booking_id = b.id and (d.user_id = p_staff or lower(coalesce(d.email, '')) = lower(coalesce(u.email, '-')))) then
    return 'own rental';
  end if;
  if nullif(btrim(coalesce(sp.home_postal_code, '')), '') is not null
     and upper(regexp_replace(coalesce(r.postal_code, ''), '\s', '', 'g')) = upper(regexp_replace(sp.home_postal_code, '\s', '', 'g'))
     and (nullif(btrim(coalesce(sp.home_address, '')), '') is null
          or lower(regexp_replace(coalesce(r.address_line1, ''), '[^A-Za-z0-9]', '', 'g')) = lower(regexp_replace(split_part(sp.home_address, ',', 1), '[^A-Za-z0-9]', '', 'g'))) then
    return 'household rental';
  end if;
  return null;
end $$;

-- The base of a commission: the booked revenue of My sales (app.sales_revenue_cents), for a booking that went ahead
-- even when it carries no confirmation time (a rental recorded after the fact).
create or replace function app.commission_base_cents(p_booking uuid) returns bigint
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_net bigint;
  v_other bigint;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return 0; end if;
  if b.confirmed_at is not null then return app.sales_revenue_cents(p_booking); end if;
  if b.status not in ('confirmed', 'on_rent', 'returned', 'closed') then return 0; end if;
  v_net := greatest(b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents, 0);
  select coalesce(sum(round(r.amount_cents * 10000.0 / (10000 + b.hst_bps))), 0)::bigint into v_other
    from refunds r where r.booking_id = b.id and r.status in ('approved', 'processing', 'paid')
     and not exists (select 1 from booking_change_requests q where q.refund_id = r.id);
  return greatest(v_net - v_other, 0);
end $$;

-- How a person is paid: a flat rate an Admin set for them, the Sales tiers, or the flat staff rate.
create or replace function app.commission_scheme(p_staff uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when sp.commission_bps is not null then 'override'
              when sp.staff_type = 'va' and sp.va_function::text = 'sales' then 'sales_tier'
              else 'flat' end
    from (select 1) one left join staff_profiles sp on sp.user_id = p_staff
$$;

-- The Sales tier for a month's rental days.
create or replace function app.sales_tier_bps(p_days integer, p_on date default null) returns integer
language sql stable security definer set search_path = public, app as $$
  select case when p_days >= s.sales_tier_high_days then s.sales_tier_high_bps when p_days >= s.sales_tier_mid_days then s.sales_tier_mid_bps else s.sales_tier_low_bps end
    from (select (app.settings(coalesce(p_on, app.today()))).*) s
$$;

-- The rental days that count for a person's month: earned commissions (pending approval, approved or paid, not
-- reversed) of rentals ending that month.
create or replace function app.commission_month_days(p_staff uuid, p_month date) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(c.rental_days), 0)::integer from staff_commissions c
   where c.staff_id = p_staff and c.month = p_month and c.kind = 'commission' and c.status in ('pending_approval', 'approved', 'paid') and c.reversed_at is null
$$;

-- What a person earns on a month's rentals, recomputed whenever one changes and once more after the month ends: the
-- rate (their flat rate, or the month's Sales tier on its rental days) on each rental's base. A commission not paid yet
-- takes the new amount (an approved one goes back for approval if it changes); a paid one gets a clawback of the
-- difference (taken off the next payout) or an adjustment to approve.
create or replace function app.commission_retier(p_staff uuid, p_month date) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_scheme text := app.commission_scheme(p_staff);
  v_days integer := app.commission_month_days(p_staff, p_month);
  v_rate integer;
  c staff_commissions;
  v_amount bigint;
  v_net bigint;
begin
  if p_staff is null or p_month is null then return; end if;
  v_rate := case v_scheme when 'override' then (select sp.commission_bps from staff_profiles sp where sp.user_id = p_staff)
                          when 'sales_tier' then app.sales_tier_bps(v_days, (p_month + interval '1 month' - interval '1 day')::date)
                          else (app.settings((p_month + interval '1 month' - interval '1 day')::date)).staff_commission_bps end;
  for c in select * from staff_commissions x where x.staff_id = p_staff and x.month = p_month and x.kind = 'commission'
                and x.status in ('accruing', 'pending_approval', 'approved', 'paid') for update loop
    v_amount := case when c.reversed_at is null then public.calc_bps(c.base_cents, v_rate) else 0 end;
    if c.status in ('accruing', 'pending_approval') then
      update staff_commissions set scheme = v_scheme, tier_days = v_days, rate_bps = v_rate, amount_cents = v_amount, updated_at = now() where id = c.id;
    elsif c.status = 'approved' then
      if v_amount <> c.amount_cents then
        update staff_commissions set scheme = v_scheme, tier_days = v_days, rate_bps = v_rate, amount_cents = v_amount, status = 'pending_approval',
               approved_at = null, approved_by = null, note = 'The amount changed after it was approved (a refund or the month''s tier): approve it again', updated_at = now()
         where id = c.id;
      else
        update staff_commissions set scheme = v_scheme, tier_days = v_days, updated_at = now() where id = c.id;
      end if;
    else
      -- paid: what was paid less clawbacks plus adjustments, against what is due now
      select c.amount_cents + coalesce(sum(x.amount_cents) filter (where x.status not in ('reversed', 'void')), 0) into v_net
        from staff_commissions x where x.clawback_of = c.id;
      update staff_commissions set tier_days = v_days, updated_at = now() where id = c.id;
      if v_amount < v_net then
        insert into staff_commissions (booking_id, staff_id, kind, clawback_of, scheme, month, rental_days, tier_days, base_cents, rate_bps, amount_cents, status, reason, earned_at)
        values (c.booking_id, p_staff, 'clawback', c.id, v_scheme, p_month, 0, v_days, c.base_cents, v_rate, v_amount - v_net, 'approved',
                coalesce(c.reason, case when c.reversed_at is not null then 'Reversed after it was paid' else 'A refund or the month''s tier lowered it after it was paid' end), now());
      elsif v_amount > v_net then
        insert into staff_commissions (booking_id, staff_id, kind, clawback_of, scheme, month, rental_days, tier_days, base_cents, rate_bps, amount_cents, status, reason, earned_at)
        values (c.booking_id, p_staff, 'adjustment', c.id, v_scheme, p_month, 0, v_days, c.base_cents, v_rate, v_amount - v_net, 'pending_approval',
                'The month''s tier rose after it was paid', now());
      end if;
    end if;
  end loop;
  perform app.commission_split_refresh(p_staff, p_month);
end $$;

-- A commission stops being due (cancelled, refunded, charged back, own or household rental, the credit moved, an
-- Admin's decision): not earned yet, it is void; earned, reversed; paid, it keeps its payment and gets a clawback.
create or replace function app.commission_close(p_id uuid, p_reason text, p_by uuid default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c staff_commissions;
begin
  select * into c from staff_commissions where id = p_id for update;
  if c.id is null or c.status in ('void', 'reversed') or c.reversed_at is not null then return; end if;
  if c.status = 'accruing' then
    update staff_commissions set status = 'void', reason = p_reason, reversed_at = now(), reversed_by = p_by, updated_at = now() where id = c.id;
  elsif c.status in ('pending_approval', 'approved') then
    update staff_commissions set status = 'reversed', reason = p_reason, reversed_at = now(), reversed_by = p_by, updated_at = now() where id = c.id;
  else
    update staff_commissions set reason = p_reason, reversed_at = now(), reversed_by = p_by, updated_at = now() where id = c.id;
  end if;
  perform app.commission_retier(c.staff_id, c.month);
end $$;

-- Bring a booking's commission in step with the booking: who sourced it, whether it is due, its base, its month and
-- rental days, earned or not. Called by the triggers below and by the functions that change the credit.
create or replace function app.commission_sync(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c staff_commissions;
  v_staff uuid;
  v_reason text;
  v_base bigint;
  v_earned boolean;
  v_month date;
  v_old_month date;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return; end if;
  v_staff := case when b.sales_sourced then b.sales_staff_id end;
  if v_staff is null and not exists (select 1 from staff_commissions x where x.booking_id = b.id) then return; end if;
  -- a credit that moved: the earlier person's commission stops
  for c in select * from staff_commissions x where x.booking_id = b.id and x.kind = 'commission' and x.staff_id is distinct from v_staff
             and x.status not in ('void', 'reversed') and x.reversed_at is null loop
    perform app.commission_close(c.id, 'The booking is credited to someone else now');
  end loop;
  if v_staff is null then return; end if;

  v_reason := case when b.booking_type = 'owner' then 'Owner Booking'
                   when b.status in ('cancelled', 'no_show', 'expired', 'declined') then 'Cancelled booking'
                   when exists (select 1 from disputes d where d.booking_id = b.id and d.status = 'lost') then 'Charged back'
                   else app.commission_own_reason(b.id, v_staff) end;
  v_base := case when v_reason is null then app.commission_base_cents(b.id) else 0 end;
  if v_reason is null and b.status in ('returned', 'closed') and v_base <= 0 then v_reason := 'Refunded'; end if;
  v_earned := v_reason is null and b.status in ('returned', 'closed') and app.booking_paid_in_full(b.id)
              and not exists (select 1 from disputes d where d.booking_id = b.id and d.status in ('open', 'evidence_submitted'));
  v_month := app.month_start(app.local_date(coalesce(b.checked_in_at, b.return_at)));

  select * into c from staff_commissions where booking_id = b.id and staff_id = v_staff and kind = 'commission' for update;
  if c.id is null then
    if v_reason is not null then return; end if;
    insert into staff_commissions (booking_id, staff_id, kind, month, rental_days, base_cents, status, earned_at)
    values (b.id, v_staff, 'commission', v_month, coalesce(b.billable_days, 0), v_base,
            case when v_earned then 'pending_approval' else 'accruing' end, case when v_earned then now() end);
    perform app.commission_retier(v_staff, v_month);
    return;
  end if;
  if c.admin_reversed then return; end if;   -- an Admin's decision stands
  if v_reason is not null then
    perform app.commission_close(c.id, v_reason);
    return;
  end if;
  v_old_month := c.month;
  if c.status in ('void', 'reversed') or (c.status = 'paid' and c.reversed_at is not null) then
    -- due again (a cancellation undone, a credit given back)
    update staff_commissions set status = case when c.status = 'paid' then 'paid' when v_earned then 'pending_approval' else 'accruing' end,
           reversed_at = null, reversed_by = null, reason = null, earned_at = case when v_earned then coalesce(earned_at, now()) end,
           month = v_month, rental_days = coalesce(b.billable_days, 0), base_cents = v_base, updated_at = now()
     where id = c.id;
  else
    update staff_commissions set month = case when status = 'paid' then month else v_month end, rental_days = coalesce(b.billable_days, 0), base_cents = v_base,
           status = case when status = 'accruing' and v_earned then 'pending_approval' when status = 'pending_approval' and not v_earned then 'accruing' else status end,
           earned_at = case when status = 'accruing' and v_earned then now() when status = 'pending_approval' and not v_earned then null else earned_at end,
           approved_at = case when status = 'approved' and base_cents <> v_base then null else approved_at end,
           approved_by = case when status = 'approved' and base_cents <> v_base then null else approved_by end,
           note = case when status = 'approved' and base_cents <> v_base then 'The rental charge changed after it was approved: approve it again' else note end,
           updated_at = now()
     where id = c.id;
    update staff_commissions set status = 'pending_approval' where id = c.id and status = 'approved' and approved_at is null;
  end if;
  perform app.commission_retier(v_staff, v_month);
  if v_old_month is distinct from v_month then perform app.commission_retier(v_staff, v_old_month); end if;
end $$;

-- What changes a commission: the booking (status, credit, price), its payments, refunds, disputes and statements.
create or replace function app.commission_sync_trigger() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_booking uuid := case when tg_table_name = 'bookings' then (to_jsonb(new) ->> 'id')::uuid else (to_jsonb(new) ->> 'booking_id')::uuid end;
begin
  if v_booking is not null then perform app.commission_sync(v_booking); end if;
  return null;
end $$;
drop trigger if exists bookings_commission_sync on bookings;
create trigger bookings_commission_sync after insert or update of status, sales_staff_id, sales_sourced, rental_charge_cents, discount_cents, staff_discount_cents,
  promo_discount_cents, checked_in_at, return_at, renter_id on bookings
  for each row when (new.sales_sourced or new.sales_staff_id is not null) execute function app.commission_sync_trigger();
drop trigger if exists payments_commission_sync on payments;
create trigger payments_commission_sync after insert or update of status on payments
  for each row when (new.booking_id is not null) execute function app.commission_sync_trigger();
drop trigger if exists refunds_commission_sync on refunds;
create trigger refunds_commission_sync after insert or update of status on refunds
  for each row execute function app.commission_sync_trigger();
drop trigger if exists disputes_commission_sync on disputes;
create trigger disputes_commission_sync after insert or update of status on disputes
  for each row when (new.booking_id is not null) execute function app.commission_sync_trigger();
drop trigger if exists booking_statements_commission_sync on booking_statements;
create trigger booking_statements_commission_sync after insert or update of sent_at, paid_at on booking_statements
  for each row execute function app.commission_sync_trigger();
drop trigger if exists booking_line_items_commission_sync on booking_line_items;
create trigger booking_line_items_commission_sync after insert or update of payment_id, voided_at on booking_line_items
  for each row execute function app.commission_sync_trigger();
-- the sync of a commission stays in step when a field staff member's rate or function changes
create or replace function app.staff_profiles_commission_retier() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  m date;
begin
  for m in select distinct c.month from staff_commissions c where c.staff_id = new.user_id and c.kind = 'commission' and c.status in ('accruing', 'pending_approval', 'approved') loop
    perform app.commission_retier(new.user_id, m);
  end loop;
  return null;
end $$;
drop trigger if exists staff_profiles_commission_retier on staff_profiles;
create trigger staff_profiles_commission_retier after update of commission_bps, va_function, staff_type on staff_profiles
  for each row execute function app.staff_profiles_commission_retier();

-- ================================================================ 8. approval and payment (Admins)
-- Approve commissions (and adjustments) pending approval, one or many. A Sales month is approved once it has ended (its
-- tier is then known). Staff are told, once per person. p: {ids: [...]} or {staff, month} (everything of that person
-- and month that may be approved)
create or replace function app.commission_approve(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_ids uuid[];
  r record;
  v_n integer := 0;
  v_month0 date := app.month_start(app.today());
begin
  perform app.assert_admin(p_by);
  if jsonb_typeof(p -> 'ids') = 'array' then
    v_ids := array(select (jsonb_array_elements_text(p -> 'ids'))::uuid);
  else
    v_ids := array(select c.id from staff_commissions c where c.staff_id = nullif(p ->> 'staff', '')::uuid and c.status = 'pending_approval'
                     and (nullif(p ->> 'month', '') is null or c.month = (p ->> 'month')::date)
                     and not (c.scheme = 'sales_tier' and c.month >= v_month0));
  end if;
  if coalesce(array_length(v_ids, 1), 0) = 0 then raise exception 'Choose the commissions to approve' using errcode = '22023'; end if;
  if exists (select 1 from staff_commissions c where c.id = any (v_ids) and c.status <> 'pending_approval') then
    raise exception 'Only commissions pending approval can be approved' using errcode = '23514';
  end if;
  if exists (select 1 from staff_commissions c where c.id = any (v_ids) and c.scheme = 'sales_tier' and c.month >= v_month0) then
    raise exception 'A Sales commission is approved after its month ends, when the month''s tier is known' using errcode = '23514';
  end if;
  update staff_commissions set status = 'approved', approved_at = now(), approved_by = p_by, note = null, updated_at = now() where id = any (v_ids);
  for r in select c.staff_id, count(*) as n, sum(c.amount_cents) as total from staff_commissions c where c.id = any (v_ids) group by c.staff_id loop
    v_n := v_n + r.n;
    perform app.emit_event('staff_commission_approved', 'user', r.staff_id,
      jsonb_build_object('staff_id', r.staff_id, 'ids', to_jsonb(array(select c.id from staff_commissions c where c.id = any (v_ids) and c.staff_id = r.staff_id)),
                         'count', r.n, 'amount_cents', r.total),
      'staff_commission_approved:' || r.staff_id || ':' || md5(array_to_string(v_ids, ',')));
  end loop;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'commission_approve', 'staff_commissions', null, jsonb_build_object('ids', to_jsonb(v_ids)));
  return jsonb_build_object('approved', v_n);
end $$;

-- An Admin reverses a commission (a household rental found later, a mistake), with a reason; once paid, the amount is
-- taken off the next payout. p: {id, reason}
create or replace function app.commission_reverse(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c staff_commissions;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  perform app.assert_admin(p_by);
  select * into c from staff_commissions where id = (p ->> 'id')::uuid for update;
  if c.id is null or c.kind <> 'commission' then raise exception 'Commission not found' using errcode = 'P0002'; end if;
  if v_reason is null then raise exception 'Say why the commission is reversed' using errcode = '22023'; end if;
  if c.status in ('void', 'reversed') or c.reversed_at is not null then raise exception 'This commission is already reversed' using errcode = '23514'; end if;
  update staff_commissions set admin_reversed = true where id = c.id;
  perform app.commission_close(c.id, v_reason, p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'commission_reverse', 'staff_commissions', c.id::text, jsonb_build_object('reason', v_reason, 'status_before', c.status));
  return jsonb_build_object('id', c.id, 'reversed', true);
end $$;

-- Record a payment made by hand of a person's approved commissions (with clawbacks and adjustments they carry): method,
-- reference, date, or the monthly pay statement. The total must be above zero; a clawback larger than what is approved
-- waits for the next commissions. p: {staff, ids, method, reference, paid_on, pay_period, note}
create or replace function app.commission_payout_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_staff uuid := nullif(p ->> 'staff', '')::uuid;
  v_ids uuid[];
  v_total bigint;
  v_method text := coalesce(nullif(p ->> 'method', ''), 'e_transfer');
  v_ref text := nullif(btrim(coalesce(p ->> 'reference', '')), '');
  v_on date := coalesce(nullif(p ->> 'paid_on', '')::date, app.today());
  v_period date := case when nullif(p ->> 'pay_period', '') is not null then app.month_start((p ->> 'pay_period')::date) end;
  v_id uuid;
begin
  perform app.assert_admin(p_by);
  if v_staff is null then raise exception 'Choose the staff member' using errcode = '22023'; end if;
  if jsonb_typeof(p -> 'ids') = 'array' then
    v_ids := array(select (jsonb_array_elements_text(p -> 'ids'))::uuid);
  else
    v_ids := array(select c.id from staff_commissions c where c.staff_id = v_staff and c.status = 'approved');
  end if;
  if coalesce(array_length(v_ids, 1), 0) = 0 then raise exception 'Nothing approved to pay' using errcode = '22023'; end if;
  if exists (select 1 from staff_commissions c where c.id = any (v_ids) and (c.staff_id <> v_staff or c.status <> 'approved')) then
    raise exception 'Only approved commissions of this staff member can be paid' using errcode = '23514';
  end if;
  if v_method not in ('e_transfer', 'bank_transfer', 'wise', 'cash', 'other', 'pay_statement') then
    raise exception 'Choose how it was paid: e-Transfer, bank transfer, Wise, cash, another way or the pay statement' using errcode = '22023';
  end if;
  if v_method in ('e_transfer', 'bank_transfer', 'wise') and (v_ref is null or length(v_ref) < 3) then raise exception 'Enter the reference of the payment' using errcode = '22023'; end if;
  if v_method = 'pay_statement' and v_period is null then raise exception 'Choose the month of the pay statement' using errcode = '22023'; end if;
  if v_method = 'other' and nullif(btrim(coalesce(p ->> 'note', '')), '') is null then raise exception 'Say how it was paid' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date paid cannot be in the future' using errcode = '22023'; end if;
  select sum(amount_cents) into v_total from staff_commissions where id = any (v_ids);
  if v_total <= 0 then
    raise exception 'These add up to % after clawbacks: nothing to pay until more commissions are approved', app.fmt_money(v_total) using errcode = '23514';
  end if;
  insert into staff_commission_payouts (staff_id, method, reference, paid_on, pay_period, amount_cents, note, recorded_by)
  values (v_staff, v_method, v_ref, v_on, v_period, v_total, nullif(btrim(coalesce(p ->> 'note', '')), ''), p_by)
  returning id into v_id;
  update staff_commissions set status = 'paid', payout_id = v_id, paid_at = now(), updated_at = now() where id = any (v_ids);
  perform app.emit_event('staff_commission_paid', 'staff_commission_payout', v_id, jsonb_build_object('staff_id', v_staff, 'payout_id', v_id),
    'staff_commission_paid:' || v_id);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'commission_payout_record', 'staff_commission_payouts', v_id::text,
          jsonb_build_object('staff', v_staff, 'ids', to_jsonb(v_ids), 'amount_cents', v_total, 'method', v_method, 'reference', v_ref));
  return jsonb_build_object('payout_id', v_id, 'amount_cents', v_total, 'count', array_length(v_ids, 1));
end $$;

-- An Admin sets one person's flat rate (empty: the Program settings). p: {staff, bps, reason}
create or replace function app.staff_commission_rate_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_staff uuid := nullif(p ->> 'staff', '')::uuid;
  v_bps integer := nullif(p ->> 'bps', '')::integer;
  v_before integer;
begin
  perform app.assert_admin(p_by);
  if not app.user_is_sales_staff(v_staff) then raise exception 'Choose an active staff member' using errcode = '22023'; end if;
  if v_bps is not null and (v_bps < 0 or v_bps > 10000) then raise exception 'A rate is between 0%% and 100%%' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p ->> 'reason', '')), '') is null then raise exception 'Say why' using errcode = '22023'; end if;
  select commission_bps into v_before from staff_profiles where user_id = v_staff;
  update staff_profiles set commission_bps = v_bps where user_id = v_staff;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'staff_commission_rate_set', 'staff_profiles', v_staff::text, jsonb_build_object('commission_bps', v_before),
          jsonb_build_object('commission_bps', v_bps, 'reason', btrim(p ->> 'reason')));
  return jsonb_build_object('staff', v_staff, 'bps', v_bps, 'scheme', app.commission_scheme(v_staff));
end $$;

-- An Admin records a staff member's home address, used only to recognize a household rental. p: {staff, home_address, home_postal_code}
create or replace function app.staff_household_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_staff uuid := nullif(p ->> 'staff', '')::uuid;
begin
  perform app.assert_admin(p_by);
  if not app.user_is_sales_staff(v_staff) then raise exception 'Choose an active staff member' using errcode = '22023'; end if;
  update staff_profiles set home_address = nullif(btrim(coalesce(p ->> 'home_address', '')), ''),
         home_postal_code = upper(nullif(btrim(coalesce(p ->> 'home_postal_code', '')), ''))
   where user_id = v_staff;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'staff_household_set', 'staff_profiles', v_staff::text, jsonb_build_object('home_postal_code', upper(nullif(btrim(coalesce(p ->> 'home_postal_code', '')), ''))));
  return jsonb_build_object('staff', v_staff);
end $$;

-- After a month ends: its tiers once more, and a task for the Admins when commissions wait for approval.
create or replace function app.job_commission_month(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_month date := app.month_start((app.month_start(app.local_date(p_now)) - 1));
  v_run uuid;
  r record;
  v_n integer;
begin
  if app.local_hour(p_now) < 6 then return 'not_due'; end if;
  v_run := app.job_claim('commission-month', v_month::text);
  if v_run is null then return 'already_run'; end if;
  begin
    for r in select distinct staff_id from staff_commissions where month = v_month and kind = 'commission' loop
      perform app.commission_retier(r.staff_id, v_month);
    end loop;
    select count(*) into v_n from staff_commissions where status = 'pending_approval';
    if v_n > 0 then
      perform app.raise_task(p_type => 'approve_commissions', p_title => format('Staff commissions of %s to approve', to_char(v_month, 'FMMonth YYYY')),
        p_detail => format('%s commission(s) wait for approval in Money > Staff commissions. Nothing is paid until you approve it and record the payment.', v_n),
        p_queue => 'admin', p_dedupe => 'approve_commissions:' || v_month);
    end if;
    perform app.job_succeed(v_run, jsonb_build_object('month', v_month, 'pending', v_n));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- ================================================================ 9. owners: commissions are kickbacks, deducted before Owner Revenue
-- Enrollment Agreement 8.1 and 8.3 (reworded in this release to name Staff Commissions): for a program owner's car,
-- Owner Revenue is the booking's revenue less every kickback on it: an Owner's Referral Kickback and every staff
-- commission (the tiered Sales rate or the flat staff rate, field staff referral fees included), as expenses of the booking
-- before the Revenue Share. A partner's car: CarmaCars pays it from its own commission (the partner agreement allows no
-- other deduction). A CarmaCars-owned car: a CarmaCars expense. booking_splits.kickback_cents carries the whole amount
-- deducted (so every statement, total and check stays as it was); staff_commission_cents is the staff commission part.
alter table booking_splits
  add column if not exists staff_commission_cents bigint not null default 0 check (staff_commission_cents >= 0),
  add column if not exists staff_commission_adjusted_cents bigint not null default 0;
comment on column booking_splits.staff_commission_cents is 'The staff commission part of kickback_cents (0058): deducted with the kickbacks before Owner Revenue on a program owner''s car';
comment on column booking_splits.staff_commission_adjusted_cents is 'A change of the staff commission after this part was on an owner statement (0058): the Owner''s share of it went on a later statement as an adjustment line';
alter table owner_statement_lines add column if not exists staff_commission_cents bigint not null default 0;
comment on column owner_statement_lines.staff_commission_cents is 'The staff commission part of kickback_cents on a rental line (0058), printed as its own expense line before Owner Revenue';

alter table owner_deductions drop constraint if exists owner_deductions_kind_check;
alter table owner_deductions add constraint owner_deductions_kind_check check (kind in ('plate_renewal', 'owner_booking_toll', 'owner_booking_ticket', 'lender_handover_cost',
  'claim_shortfall', 'owner_booking_deductible', 'retransfer_fee', 'refund_share', 'chargeback_share', 'kickback_reversal', 'agreed_in_writing', 'staff_commission_adjustment'));
alter table owner_credits drop constraint if exists owner_credits_kind_check;
alter table owner_credits add constraint owner_credits_kind_check check (kind in ('later_rental_revenue', 'correction', 'staff_commission_adjustment'));

-- What the staff commissions on a booking come to now: what is due on each (paid ones net of their clawbacks and
-- adjustments), nothing for a void or reversed one.
create or replace function app.booking_staff_commission_cents(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select greatest(coalesce(sum(c.amount_cents), 0), 0)::bigint from staff_commissions c where c.booking_id = p_booking and c.status not in ('void', 'reversed')
$$;

-- 0025's split, with the staff commissions deducted with the kickbacks (0058).
create or replace function app.compute_booking_split(p_booking uuid)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s booking_splits;
  p record;
  v_set program_settings;
  v_reason text;
  v_rental_total bigint := 0;
  v_kick_total bigint;
  v_kick bigint; v_rev bigint; v_share bigint; v_pay bigint;
  v_counts date; v_done boolean; v_cancelled boolean;
  v_prior bigint; v_delta bigint;
  v_lo bigint := 0;
  v_rental bigint;
  v_vehicles uuid[] := '{}';
  v_ref_total bigint;
  v_comm_total bigint;
  v_comm bigint;
  v_comm_was bigint;
  v_eff bigint;
  v_owner_rental bigint := 0;
  v_lo2 bigint := 0;
begin
  select * into b from bookings where id = p_booking;
  if not found then raise exception 'Booking % not found', p_booking; end if;
  -- an Owner Booking has no Owner Revenue, kickback or payout
  if b.booking_type = 'owner' then
    delete from booking_splits where booking_id = p_booking and owner_statement_id is null;
    return;
  end if;
  v_set := app.settings(app.local_date(b.booked_at));
  v_cancelled := b.status in ('cancelled', 'no_show');
  v_done := b.status in ('returned', 'closed');

  -- the kickback is worked out on the whole rental charge, after refunds and chargebacks
  for p in select * from app.booking_split_parts(p_booking) loop
    v_rental_total := v_rental_total + greatest(p.rental_cents - p.chargeback_cents, 0);
  end loop;
  v_reason := app.kickback_ineligible_reason(p_booking);
  v_ref_total := public.calc_kickback(v_rental_total, v_reason is null, v_set.kickback_bps);
  -- staff commissions (0058): deducted with the kickbacks before Owner Revenue, on a program owner's car only (a partner's
  -- and a CarmaCars-owned car's are CarmaCars' own), shared between the owner cars' parts by their rental charge
  v_comm_total := app.booking_staff_commission_cents(p_booking);
  for p in select * from app.booking_split_parts(p_booking) loop
    if coalesce((select v.supply_type from vehicles v where v.id = p.vehicle_id), 'program_owner') = 'program_owner' then
      v_owner_rental := v_owner_rental + greatest(p.rental_cents - p.chargeback_cents, 0);
    end if;
  end loop;
  if v_owner_rental = 0 then v_comm_total := 0; end if;
  v_kick_total := v_ref_total;

  -- a rental counts in the month it ends; rental charge kept on a cancellation, in the month of cancellation
  if v_cancelled then
    select app.local_date(received_at) into v_counts from booking_cancellations where booking_id = p_booking;
    v_counts := coalesce(v_counts, app.local_date(b.updated_at));
  else
    v_counts := app.local_date(coalesce(b.checked_in_at, b.return_at));
  end if;

  for p in select * from app.booking_split_parts(p_booking) order by ord loop
    -- Owner Revenue lost to a chargeback comes off the rental charge
    v_rental := greatest(p.rental_cents - p.chargeback_cents, 0);
    v_kick := app.cut(v_kick_total, v_lo, v_lo + v_rental, v_rental_total);
    if v_rental_total = 0 then v_kick := 0; end if;
    v_lo := v_lo + v_rental;
    v_comm := 0;
    if v_comm_total > 0 and coalesce((select v.supply_type from vehicles v where v.id = p.vehicle_id), 'program_owner') = 'program_owner' then
      v_comm := least(app.cut(v_comm_total, v_lo2, v_lo2 + v_rental, v_owner_rental), v_rental + p.mileage_cents - v_kick);
      v_lo2 := v_lo2 + v_rental;
    end if;
    v_kick := v_kick + greatest(v_comm, 0);
    select x.owner_revenue_cents, x.company_share_cents, x.owner_payout_cents into v_rev, v_share, v_pay
      from public.calc_split(v_rental, p.mileage_cents, v_kick, p.company_share_bps) x;
    v_vehicles := v_vehicles || p.vehicle_id;

    select * into s from booking_splits where booking_id = p_booking and vehicle_id = p.vehicle_id;
    if s.booking_id is not null and s.owner_statement_id is not null then
      -- already paid out: the Owner's share of the change goes on the next statement
      -- (the refunds and chargebacks against the commission the statement showed; a commission change is below)
      select x.owner_payout_cents into v_pay
        from public.calc_split(v_rental, p.mileage_cents, greatest(v_kick - greatest(v_comm, 0) + s.staff_commission_cents, 0), p.company_share_bps) x;
      select coalesce(sum(amount_cents), 0) into v_prior from owner_deductions
       where booking_id = p_booking and vehicle_id = p.vehicle_id and kind in ('refund_share', 'chargeback_share') and status <> 'waived';
      v_delta := s.owner_payout_cents - v_pay - v_prior;
      if v_delta > 0 then
        insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, booking_id)
        values (s.owner_id, s.vehicle_id, case when p.chargeback_cents > 0 then 'chargeback_share' else 'refund_share' end,
                format('Booking %s: Owner''s share of a later %s', b.booking_number,
                       case when p.chargeback_cents > 0 then 'chargeback' else 'refund' end),
                v_delta, app.today(), p_booking);
      end if;
      update booking_splits set refunded_cents = p.refunded_cents, chargeback_cents = p.chargeback_cents, withheld_cents = p.withheld_cents
       where booking_id = p_booking and vehicle_id = p.vehicle_id;
      -- a staff commission that changed after the statement (a refund, the month's tier): the Owner's share of the change
      -- goes on the next statement as its own line (0058)
      v_comm_was := s.staff_commission_cents + s.staff_commission_adjusted_cents;
      if v_comm <> v_comm_was then
        select a.owner_payout_cents - z.owner_payout_cents into v_eff
          from public.calc_split(v_rental, p.mileage_cents, greatest(s.kickback_cents - s.staff_commission_cents + v_comm_was, 0), p.company_share_bps) a,
               public.calc_split(v_rental, p.mileage_cents, greatest(s.kickback_cents - s.staff_commission_cents + v_comm, 0), p.company_share_bps) z;
        if v_eff > 0 then
          insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, booking_id)
          values (s.owner_id, s.vehicle_id, 'staff_commission_adjustment',
                  format('Booking %s: staff commission raised after the statement (%s to %s)', b.booking_number, app.fmt_money(v_comm_was), app.fmt_money(v_comm)),
                  v_eff, app.today(), p_booking);
        elsif v_eff < 0 then
          insert into owner_credits (owner_id, vehicle_id, booking_id, kind, description, amount_cents, incurred_on)
          values (s.owner_id, s.vehicle_id, p_booking, 'staff_commission_adjustment',
                  format('Booking %s: staff commission lowered after the statement (%s to %s)', b.booking_number, app.fmt_money(v_comm_was), app.fmt_money(v_comm)),
                  -v_eff, app.today());
        end if;
        update booking_splits set staff_commission_adjusted_cents = v_comm - staff_commission_cents where booking_id = p_booking and vehicle_id = p.vehicle_id;
      end if;
    else
      insert into booking_splits as bs (booking_id, vehicle_id, owner_id, referrer_type, referrer_owner_id, referrer_staff_id,
          is_first_rental, kickback_base_cents, kickback_cents, rental_charge_cents, mileage_overage_cents,
          owner_revenue_cents, company_share_bps, company_share_cents, owner_payout_cents, company_only_cents,
          pass_through_cents, hst_cents, collected_cents, refunded_cents, chargeback_cents, withheld_cents,
          uncollected_cents, kickback_ineligible_reason, counts_on, payout_month, status, computed_at,
          segment_days, segment_starts_at, segment_ends_at, staff_commission_cents)
      values (p_booking, p.vehicle_id, p.owner_id, b.referrer_type, b.referrer_owner_id, b.referrer_staff_id,
          v_reason is null, case when v_reason is null then v_rental else 0 end, v_kick, v_rental, p.mileage_cents,
          v_rev, p.company_share_bps, v_share, v_pay, p.company_only_cents,
          p.pass_through_cents, p.hst_cents, p.collected_cents, p.refunded_cents, p.chargeback_cents, p.withheld_cents,
          p.uncollected_cents, v_reason, v_counts, app.month_start(v_counts),
          case when b.status in ('closed', 'cancelled', 'no_show') then 'final' else 'provisional' end, now(),
          p.segment_days, p.segment_starts_at, p.segment_ends_at, greatest(v_comm, 0))
      on conflict (booking_id, vehicle_id) do update set
          owner_id = excluded.owner_id, referrer_type = excluded.referrer_type,
          referrer_owner_id = excluded.referrer_owner_id, referrer_staff_id = excluded.referrer_staff_id,
          is_first_rental = excluded.is_first_rental, kickback_base_cents = excluded.kickback_base_cents,
          kickback_cents = excluded.kickback_cents, rental_charge_cents = excluded.rental_charge_cents,
          mileage_overage_cents = excluded.mileage_overage_cents, owner_revenue_cents = excluded.owner_revenue_cents,
          company_share_bps = excluded.company_share_bps, company_share_cents = excluded.company_share_cents,
          owner_payout_cents = excluded.owner_payout_cents, company_only_cents = excluded.company_only_cents,
          pass_through_cents = excluded.pass_through_cents, hst_cents = excluded.hst_cents,
          collected_cents = excluded.collected_cents, refunded_cents = excluded.refunded_cents,
          chargeback_cents = excluded.chargeback_cents, withheld_cents = excluded.withheld_cents,
          uncollected_cents = excluded.uncollected_cents, kickback_ineligible_reason = excluded.kickback_ineligible_reason,
          counts_on = excluded.counts_on, payout_month = excluded.payout_month, status = excluded.status,
          computed_at = now(), segment_days = excluded.segment_days, segment_starts_at = excluded.segment_starts_at,
          segment_ends_at = excluded.segment_ends_at, staff_commission_cents = excluded.staff_commission_cents;
    end if;
  end loop;
  -- a part on a car the booking no longer has (worked out before a change), not paid out yet
  delete from booking_splits where booking_id = p_booking and owner_statement_id is null and not (vehicle_id = any (v_vehicles));

  -- the kickback record: one per booking, on the whole rental charge
  if v_ref_total > 0 then
    insert into referral_kickbacks as k (booking_id, renter_id, vehicle_id, referrer_type, referrer_owner_id, referrer_staff_id,
        base_cents, rate_bps, amount_cents, status, earned_on)
    values (p_booking, b.renter_id, b.vehicle_id, b.referrer_type, b.referrer_owner_id, b.referrer_staff_id,
        v_rental_total, v_set.kickback_bps, v_ref_total, case when v_done then 'earned' else 'pending' end,
        case when v_done then v_counts end)
    on conflict (booking_id) do update set
        base_cents = excluded.base_cents, amount_cents = excluded.amount_cents,
        status = case when k.status = 'paid' then 'paid' else excluded.status end,
        earned_on = coalesce(k.earned_on, excluded.earned_on)
      where k.status <> 'paid' or k.amount_cents = excluded.amount_cents;
  else
    -- reversed if the rental is refunded or charged back
    with rev as (
      update referral_kickbacks k
         set status = 'reversed', reversed_at = now(), reversal_reason = coalesce(v_reason, 'rental refunded or charged back')
       where k.booking_id = p_booking and k.status <> 'reversed'
      returning k.*, (select o.status from referral_kickbacks o where o.id = k.id) as was
    )
    insert into owner_deductions (owner_id, kind, description, amount_cents, incurred_on, booking_id)
    select rev.referrer_owner_id, 'kickback_reversal',
           format('Booking %s: Referral Kickback reversed', b.booking_number), rev.amount_cents, app.today(), p_booking
      from rev where rev.was = 'paid' and rev.referrer_owner_id is not null and rev.amount_cents > 0;
  end if;
end $$;

-- A rental line of an owner statement shows its staff commission apart from the Referral Kickback.
create or replace function app.owner_statement_lines_commission() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.line_type = 'rental' and new.booking_id is not null and new.vehicle_id is not null then
    new.staff_commission_cents := coalesce((select s.staff_commission_cents from booking_splits s where s.booking_id = new.booking_id and s.vehicle_id = new.vehicle_id), 0);
  end if;
  return new;
end $$;
drop trigger if exists owner_statement_lines_commission on owner_statement_lines;
create trigger owner_statement_lines_commission before insert on owner_statement_lines
  for each row execute function app.owner_statement_lines_commission();

-- A commission that changes moves the booking's split with it (the next statement carries the Owner's share of a
-- change after a statement).
create or replace function app.commission_split_refresh(p_staff uuid, p_month date) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v uuid;
begin
  for v in select distinct c.booking_id from staff_commissions c
            where c.staff_id = p_staff and c.month = p_month and exists (select 1 from booking_splits s where s.booking_id = c.booking_id) loop
    perform app.compute_booking_split(v);
  end loop;
end $$;

-- Bookings with a field staff referral whose split is not on a statement yet: the old field staff Referral Kickback
-- gives way to the staff commission (computed below once the commissions exist).

-- ================================================================ 10. what staff see
-- The month's Sales tier for a person: rental days so far, the tier, the next tier and the target (the top tier's days).
create or replace function app.sales_month_progress(p_staff uuid, p_month date default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_month date := coalesce(p_month, app.month_start(app.today()));
  s program_settings := app.settings();
  v_days integer := app.commission_month_days(p_staff, v_month);
  v_scheme text := app.commission_scheme(p_staff);
  v_rate integer;
begin
  v_rate := case v_scheme when 'override' then (select sp.commission_bps from staff_profiles sp where sp.user_id = p_staff)
                          when 'sales_tier' then app.sales_tier_bps(v_days) else s.staff_commission_bps end;
  return jsonb_build_object('month', v_month, 'label', to_char(v_month, 'FMMonth YYYY'), 'scheme', v_scheme, 'days', v_days, 'rate_bps', v_rate,
    'target_days', s.sales_tier_high_days, 'mid_days', s.sales_tier_mid_days,
    'tiers', jsonb_build_array(jsonb_build_object('from_days', 0, 'bps', s.sales_tier_low_bps), jsonb_build_object('from_days', s.sales_tier_mid_days, 'bps', s.sales_tier_mid_bps),
                               jsonb_build_object('from_days', s.sales_tier_high_days, 'bps', s.sales_tier_high_bps)),
    'progress_pct', least(100, round(100.0 * v_days / greatest(s.sales_tier_high_days, 1))),
    'next', case when v_scheme <> 'sales_tier' then null
                 when v_days < s.sales_tier_mid_days then jsonb_build_object('days', s.sales_tier_mid_days, 'bps', s.sales_tier_mid_bps, 'to_go', s.sales_tier_mid_days - v_days)
                 when v_days < s.sales_tier_high_days then jsonb_build_object('days', s.sales_tier_high_days, 'bps', s.sales_tier_high_bps, 'to_go', s.sales_tier_high_days - v_days) end,
    'rises', case when v_scheme <> 'sales_tier' then null
                  else concat_ws(' / ', case when v_days < s.sales_tier_mid_days then format('rises to %s at %s days', app.bps_words(s.sales_tier_mid_bps), s.sales_tier_mid_days) end,
                                        case when v_days < s.sales_tier_high_days then format('%s at %s days', app.bps_words(s.sales_tier_high_bps), s.sales_tier_high_days) end) end);
end $$;

create or replace function app.bps_words(p_bps integer) returns text
language sql immutable as $$
  select case when p_bps % 100 = 0 then (p_bps / 100)::text else trim(to_char(p_bps / 100.0, 'FM990.99')) end || '%'
$$;

-- One person's commissions: the totals by status, this month's tier (Sales), and each commission.
create or replace function app.staff_commissions_json(p_staff uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'scheme', app.commission_scheme(p_staff),
    'month', app.sales_month_progress(p_staff),
    'totals', jsonb_build_object(
      'not_earned', coalesce(sum(c.amount_cents) filter (where c.status = 'accruing'), 0),
      'pending', coalesce(sum(c.amount_cents) filter (where c.status = 'pending_approval'), 0),
      'approved', coalesce(sum(c.amount_cents) filter (where c.status = 'approved'), 0),
      'paid', coalesce(sum(c.amount_cents) filter (where c.status = 'paid' and c.kind <> 'clawback'), 0),
      'reversed', coalesce(sum(c.amount_cents) filter (where c.status = 'reversed'), 0) + coalesce(-sum(c.amount_cents) filter (where c.kind = 'clawback'), 0),
      'earned', coalesce(sum(c.amount_cents) filter (where c.kind <> 'clawback' and c.status in ('pending_approval', 'approved', 'paid')), 0)
                + coalesce(sum(c.amount_cents) filter (where c.kind = 'clawback'), 0)),
    'rows', coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'booking_number', b.booking_number, 'kind', c.kind, 'month', c.month,
              'month_label', to_char(c.month, 'FMMonth YYYY'), 'rental_days', c.rental_days, 'tier_days', c.tier_days, 'base_cents', c.base_cents,
              'rate_bps', c.rate_bps, 'amount_cents', c.amount_cents, 'status', c.status, 'reason', c.reason, 'note', c.note, 'scheme', c.scheme,
              'earned_at', c.earned_at, 'approved_at', c.approved_at, 'paid_at', c.paid_at,
              'paid', case when c.payout_id is not null then (select jsonb_build_object('method', po.method, 'reference', po.reference, 'paid_on', po.paid_on, 'pay_period', po.pay_period)
                                                              from staff_commission_payouts po where po.id = c.payout_id) end,
              'month_open', c.scheme = 'sales_tier' and c.month >= app.month_start(app.today()))
              order by c.month desc, b.booking_number desc, c.created_at) filter (where c.id is not null), '[]'::jsonb))
    from (select 1) one
    left join staff_commissions c on c.staff_id = p_staff
    left join bookings b on b.id = c.booking_id
$$;

-- 0057's sales board, now for every staff member (their own; an Admin: anyone's), with the choice on each deal and the
-- commissions.
create or replace function app.staff_sales(p_by uuid, p_staff uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_admin boolean := app.user_is_admin(p_by);
  v_period text := case when p ->> 'period' = 'month' then 'month' else 'week' end;
  v_count integer := least(greatest(coalesce(nullif(p ->> 'count', '')::integer, case when p ->> 'period' = 'month' then 6 else 8 end), 1), 24);
  v_periods jsonb := '[]'::jsonb;
  v_start date;
  v_end date;
  i integer;
  u users;
begin
  if p_staff is null then raise exception 'Choose the staff member' using errcode = '22023'; end if;
  if not v_admin and p_by is distinct from p_staff then raise exception 'You can read your own sales only' using errcode = '42501'; end if;
  if not v_admin and not app.user_is_sales_staff(p_by) then raise exception 'My sales is for staff' using errcode = '42501'; end if;
  select * into u from users where id = p_staff;
  if u.id is null or not exists (select 1 from user_roles r where r.user_id = u.id and r.role in ('va', 'admin', 'field')) then
    raise exception 'Staff member not found' using errcode = 'P0002';
  end if;
  for i in 0 .. v_count - 1 loop
    if v_period = 'week' then
      v_start := date_trunc('week', app.today())::date - 7 * i; v_end := v_start + 7;
    else
      v_start := (date_trunc('month', app.today()) - make_interval(months => i))::date; v_end := (v_start + interval '1 month')::date;
    end if;
    v_periods := v_periods || jsonb_build_array(jsonb_build_object('start', v_start, 'end', v_end - 1,
      'label', case when v_period = 'week' then 'Week of ' || to_char(v_start, 'FMMonth FMDD') else to_char(v_start, 'FMMonth YYYY') end,
      'current', i = 0) || app.sales_figures(p_staff, app.local_midnight(v_start), app.local_midnight(v_end)));
  end loop;
  return jsonb_build_object(
    'staff', jsonb_build_object('id', u.id, 'name', coalesce(u.full_name, u.email),
                                'function', (select coalesce(sp.va_function::text, case when sp.staff_type = 'field' then 'field' end) from staff_profiles sp where sp.user_id = u.id),
                                'admin', app.user_is_admin(u.id),
                                'commission_bps', (select sp.commission_bps from staff_profiles sp where sp.user_id = u.id)),
    'period', v_period, 'today', app.today(),
    'periods', v_periods,
    'commissions', app.staff_commissions_json(p_staff),
    'follow_ups', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'status', b.status,
                    'renter', (select split_part(r.legal_name, ' ', 1) from renters r where r.id = b.renter_id),
                    'vehicle', app.vehicle_name(b.vehicle_id), 'pickup_at', b.pickup_at) || app.sales_next_step(b)
                    order by coalesce((app.sales_next_step(b) ->> 'due_at')::timestamptz, b.pickup_at))
                  from bookings b where b.sales_staff_id = p_staff and b.status in ('requested', 'offered', 'pending_payment')), '[]'::jsonb),
    'deals', coalesce((select jsonb_agg(d order by d ->> 'at' desc) from (
                select jsonb_build_object(
                  'booking_number', b.booking_number, 'status', b.status, 'source', b.source,
                  'renter', (select split_part(r.legal_name, ' ', 1) from renters r where r.id = b.renter_id),
                  'vehicle', app.vehicle_name(b.vehicle_id), 'pickup_at', b.pickup_at, 'return_at', b.return_at,
                  'credited', b.sales_staff_id = p_staff, 'how', b.sales_source, 'sourced', b.sales_staff_id = p_staff and b.sales_sourced,
                  'choice', b.sales_choice, 'claimed', b.sales_claim_by = p_staff,
                  'credited_to', case when b.sales_staff_id is distinct from p_staff then (select coalesce(x.full_name, x.email) from users x where x.id = b.sales_staff_id) end,
                  'created_by_me', b.created_by = p_staff,
                  'offers_by_me', (select count(*) from booking_offers o where o.booking_id = b.id and o.sent_by = p_staff),
                  'at', coalesce(case when b.sales_staff_id = p_staff then b.sales_attributed_at end, b.created_at),
                  'confirmed_at', b.confirmed_at, 'offer_expires_at', case when b.status = 'offered' then b.offer_expires_at end,
                  'rental_cents', greatest(b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents, 0),
                  'revenue_cents', case when b.sales_staff_id = p_staff then app.sales_revenue_cents(b.id) else 0 end,
                  'custom_price', b.custom_price_at is not null,
                  'commission', (select jsonb_build_object('status', c.status, 'amount_cents', c.amount_cents, 'rate_bps', c.rate_bps)
                                   from staff_commissions c where c.booking_id = b.id and c.staff_id = p_staff and c.kind = 'commission'),
                  'va_can_open', b.status in ('requested', 'offered', 'pending_payment') or (b.added_by_staff and b.created_by = p_staff)) as d
                  from bookings b
                 where (b.sales_staff_id = p_staff
                        or (b.created_by = p_staff and b.source not in ('web', 'owner') and b.booking_type <> 'owner')
                        or exists (select 1 from booking_offers o where o.booking_id = b.id and o.sent_by = p_staff))
                   and coalesce(b.sales_attributed_at, b.created_at) >= app.local_midnight(app.today() - 180)
                 order by coalesce(b.sales_attributed_at, b.created_at) desc
                 limit 200) x), '[]'::jsonb));
end $$;

-- The scorecard (0057) carries the month's target for Sales: rental days so far against the top tier's days.
alter function app.staff_scorecard(uuid, integer) rename to staff_scorecard_0057;
create or replace function app.staff_scorecard(p_staff uuid, p_weeks integer default 6) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.staff_scorecard_0057(p_staff, p_weeks)
         || case when app.commission_scheme(p_staff) = 'sales_tier' then jsonb_build_object('sales_target', app.sales_month_progress(p_staff)) else '{}'::jsonb end
$$;

-- The field portal's referrals (0033): the link, and the commissions it and the rentals they source earn (0058).
create or replace function app.field_referrals(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_code text;
begin
  if not app.user_is_field(p_user) then raise exception 'Only field staff may do this' using errcode = '42501'; end if;
  select referral_code into v_code from staff_profiles where user_id = p_user and staff_type = 'field';
  if v_code is null then
    loop
      v_code := upper(substr(translate(md5(random()::text || clock_timestamp()::text || p_user::text), '01', ''), 1, 7));
      exit when length(v_code) = 7 and not exists (select 1 from staff_profiles where referral_code = v_code)
                and not exists (select 1 from owners where referral_code = v_code);
    end loop;
    update staff_profiles set referral_code = v_code where user_id = p_user and staff_type = 'field';
  end if;
  return jsonb_build_object('code', v_code,
    'rate_bps', coalesce((select sp.commission_bps from staff_profiles sp where sp.user_id = p_user), (app.settings()).staff_commission_bps),
    'commissions', app.staff_commissions_json(p_user),
    -- referral fees of the old rule (0007), kept for the record
    'kickbacks', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'month', date_trunc('month', coalesce(k.earned_on, k.created_at::date))::date,
                             'amount_cents', k.amount_cents, 'status', k.status, 'payroll_period', k.payroll_period) order by k.created_at desc)
                            from referral_kickbacks k join bookings b on b.id = k.booking_id where k.referrer_staff_id = p_user and k.status <> 'reversed'), '[]'::jsonb));
end $$;

-- ================================================================ 11. what Admins see
-- Money > Staff commissions: each person's totals, the commissions (filtered), recent payments. p: {status, staff, month}
create or replace function app.commission_admin(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_status text := nullif(p ->> 'status', '');
  v_staff uuid := nullif(p ->> 'staff', '')::uuid;
  v_month date := case when nullif(p ->> 'month', '') is not null then app.month_start(to_date(p ->> 'month', 'YYYY-MM')) end;
  v_month0 date := app.month_start(app.today());
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'today', app.today(),
    'settings', (select jsonb_build_object('staff_commission_bps', s.staff_commission_bps, 'sales_tier_low_bps', s.sales_tier_low_bps, 'sales_tier_mid_bps', s.sales_tier_mid_bps,
                   'sales_tier_high_bps', s.sales_tier_high_bps, 'sales_tier_mid_days', s.sales_tier_mid_days, 'sales_tier_high_days', s.sales_tier_high_days)
                   from (select (app.settings()).*) s),
    'people', coalesce((select jsonb_agg(x order by x ->> 'name') from (
        select jsonb_build_object('staff_id', u.id, 'name', coalesce(u.full_name, u.email),
                 'function', coalesce(sp.va_function::text, case when sp.staff_type = 'field' then 'field' end, 'admin'),
                 'scheme', app.commission_scheme(u.id), 'commission_bps', sp.commission_bps, 'month', app.sales_month_progress(u.id),
                 'pending_count', count(c.id) filter (where c.status = 'pending_approval'),
                 'pending_cents', coalesce(sum(c.amount_cents) filter (where c.status = 'pending_approval'), 0),
                 'approvable_count', count(c.id) filter (where c.status = 'pending_approval' and not (c.scheme = 'sales_tier' and c.month >= v_month0)),
                 'approved_cents', coalesce(sum(c.amount_cents) filter (where c.status = 'approved'), 0),
                 'approved_count', count(c.id) filter (where c.status = 'approved'),
                 'not_earned_cents', coalesce(sum(c.amount_cents) filter (where c.status = 'accruing'), 0),
                 'paid_cents', coalesce(sum(c.amount_cents) filter (where c.status = 'paid'), 0)) as x
          from users u join staff_commissions c on c.staff_id = u.id left join staff_profiles sp on sp.user_id = u.id
         group by u.id, u.full_name, u.email, sp.va_function, sp.staff_type, sp.commission_bps) q), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(x order by x ->> 'month' desc, x ->> 'name', x ->> 'booking_number') from (
        select jsonb_build_object('id', c.id, 'staff_id', c.staff_id, 'name', coalesce(u.full_name, u.email), 'booking_number', b.booking_number, 'kind', c.kind,
                 'month', c.month, 'month_label', to_char(c.month, 'FMMonth YYYY'), 'rental_days', c.rental_days, 'tier_days', c.tier_days,
                 'base_cents', c.base_cents, 'rate_bps', c.rate_bps, 'amount_cents', c.amount_cents, 'status', c.status, 'reason', c.reason, 'note', c.note,
                 'scheme', c.scheme, 'earned_at', c.earned_at, 'approved_at', c.approved_at, 'paid_at', c.paid_at,
                 'approvable', c.status = 'pending_approval' and not (c.scheme = 'sales_tier' and c.month >= v_month0),
                 'paid_from', case (select v.supply_type from vehicles v where v.id = b.vehicle_id) when 'program_owner' then 'owner_revenue' when 'partner' then 'carmacars_commission' else 'carmacars' end) as x
          from staff_commissions c join users u on u.id = c.staff_id join bookings b on b.id = c.booking_id
         where (v_status is null or c.status = v_status or (v_status = 'open' and c.status in ('accruing', 'pending_approval', 'approved')))
           and (v_staff is null or c.staff_id = v_staff) and (v_month is null or c.month = v_month)
         limit 500) q), '[]'::jsonb),
    'payouts', coalesce((select jsonb_agg(jsonb_build_object('id', po.id, 'name', coalesce(u.full_name, u.email), 'staff_id', po.staff_id, 'method', po.method,
                    'reference', po.reference, 'paid_on', po.paid_on, 'pay_period', po.pay_period, 'amount_cents', po.amount_cents, 'note', po.note) order by po.paid_on desc, po.created_at desc)
                  from (select * from staff_commission_payouts order by paid_on desc, created_at desc limit 50) po join users u on u.id = po.staff_id), '[]'::jsonb));
end $$;

-- The credit, the choice, the price and the commission on one booking, for the Admin's booking page (0057, extended).
create or replace function app.booking_sales_credit(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking';
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('booking_id', b.id, 'staff_id', b.sales_staff_id, 'how', b.sales_source, 'at', b.sales_attributed_at,
    'name', (select coalesce(u.full_name, u.email) from users u where u.id = b.sales_staff_id),
    'by', (select coalesce(u.full_name, u.email) from users u where u.id = b.sales_attributed_by),
    'sourced', b.sales_sourced, 'choice', b.sales_choice, 'choice_by', (select coalesce(u.full_name, u.email) from users u where u.id = b.sales_choice_by),
    'claim_by', (select coalesce(u.full_name, u.email) from users u where u.id = b.sales_claim_by), 'claim_at', b.sales_claim_at,
    'price', case when b.custom_price_at is not null then jsonb_build_object('rental_cents', b.rental_charge_cents, 'rate_sheet_cents', b.rate_sheet_rental_cents,
               'reason', b.custom_price_reason, 'by', (select coalesce(u.full_name, u.email) from users u where u.id = b.custom_price_by), 'at', b.custom_price_at,
               'flags', to_jsonb(b.price_flags), 'reviewed_at', b.price_reviewed_at, 'review_note', b.price_review_note) end,
    'commissions', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', coalesce(u.full_name, u.email), 'kind', c.kind, 'status', c.status,
                     'rate_bps', c.rate_bps, 'base_cents', c.base_cents, 'amount_cents', c.amount_cents, 'reason', c.reason, 'month', c.month) order by c.created_at)
                   from staff_commissions c join users u on u.id = c.staff_id where c.booking_id = b.id), '[]'::jsonb),
    'supply_type', (select v.supply_type from vehicles v where v.id = b.vehicle_id),
    'revenue_cents', app.sales_revenue_cents(b.id), 'options', app.sales_staff_options(p_by));
end $$;

-- To do (0054) with the commissions to approve, the prices to review and the claims to decide.
alter function app.admin_todo(uuid) rename to admin_todo_0054;
create or replace function app.admin_todo(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_todo_0054(p_admin);
  v_month0 date := app.month_start(app.today());
begin
  return jsonb_set(v, '{items}', (v -> 'items') || jsonb_build_array(
    jsonb_build_object('key', 'commissions', 'label', 'Staff commissions to approve', 'button', 'Approve commissions', 'href', '/admin/money/commissions?status=pending_approval',
                       'count', (select count(*) from staff_commissions c where c.status = 'pending_approval' and not (c.scheme = 'sales_tier' and c.month >= v_month0))),
    jsonb_build_object('key', 'commissions_pay', 'label', 'Approved staff commissions to pay', 'button', 'Record payments', 'href', '/admin/money/commissions?status=approved',
                       'count', (select count(*) from (select c.staff_id from staff_commissions c where c.status = 'approved' group by c.staff_id having sum(c.amount_cents) > 0) x)),
    jsonb_build_object('key', 'prices', 'label', 'Prices typed by hand to review (under the floor or past the discount limit)', 'button', 'Review prices', 'href', '/admin/money/commissions?tab=prices',
                       'count', (select count(*) from bookings b where b.price_flags <> '{}' and b.price_reviewed_at is null and b.status not in ('declined', 'expired'))),
    jsonb_build_object('key', 'claims', 'label', 'Staff who say they sourced a website request', 'button', 'Decide claims', 'href', '/admin/money/commissions?tab=claims',
                       'count', (select count(*) from bookings b where b.sales_claim_by is not null))));
end $$;

-- The prices to review and the claims to decide, for Money > Staff commissions.
create or replace function app.commission_reviews(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'prices', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'vehicle', app.vehicle_name(b.vehicle_id),
                   'rental_cents', b.rental_charge_cents, 'rate_sheet_cents', b.rate_sheet_rental_cents, 'reason', b.custom_price_reason, 'flags', to_jsonb(b.price_flags),
                   'days', b.billable_days, 'by', (select coalesce(u.full_name, u.email) from users u where u.id = b.custom_price_by), 'at', b.custom_price_at,
                   'reviewed_at', b.price_reviewed_at) order by b.custom_price_at desc)
                 from bookings b where b.custom_price_at is not null and b.custom_price_at > now() - interval '120 days'
                   and (b.price_flags <> '{}' or b.price_reviewed_at is null)), '[]'::jsonb),
    'claims', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'vehicle', app.vehicle_name(b.vehicle_id),
                   'claim_by', (select coalesce(u.full_name, u.email) from users u where u.id = b.sales_claim_by), 'claim_at', b.sales_claim_at,
                   'credited', (select coalesce(u.full_name, u.email) from users u where u.id = b.sales_staff_id), 'source', b.source) order by b.sales_claim_at)
                 from bookings b where b.sales_claim_by is not null), '[]'::jsonb));
end $$;

-- ================================================================ 12. emails to staff
insert into notification_link_paths (key, path) values ('va_my_sales', '/va/my-sales'), ('field_sales', '/field/sales')
on conflict (key) do update set path = excluded.path;

-- The staff member themself, at their own address (an active staff account only).
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_0053;
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code in ('staff_commission_approved', 'staff_commission_paid') then
    return query select case when sp.staff_type = 'field' then 'staff_field' else 'staff_va_' || coalesce(sp.va_function::text, 'sales') end,
                        u.id, u.email, u.full_name, null::uuid, null::uuid, true
                   from users u join staff_profiles sp on sp.user_id = u.id
                  where u.id = (p_event.payload ->> 'staff_id')::uuid and app.user_is_sales_staff(u.id) and u.email is not null;
    return;
  end if;
  return query select * from app.notification_recipients_0053(p_event, p_c);
end $$;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_0054;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_0054(p_code, p_event, p_to);
  v_staff uuid := (p_event.payload ->> 'staff_id')::uuid;
  v_field boolean;
  po staff_commission_payouts;
  v_ids uuid[];
begin
  if p_code in ('staff_commission_approved', 'staff_commission_paid') then
    v_field := app.user_is_field(v_staff);
    if p_code = 'staff_commission_paid' then
      select * into po from staff_commission_payouts where id = p_event.entity_id;
      v_ids := array(select c.id from staff_commissions c where c.payout_id = po.id);
    else
      v_ids := array(select (jsonb_array_elements_text(p_event.payload -> 'ids'))::uuid);
    end if;
    x := x || jsonb_build_object(
      'first_name', coalesce(nullif(x ->> 'first_name', ''), (select split_part(u.full_name, ' ', 1) from users u where u.id = v_staff), 'there'),
      'commission_count', (select count(*) from staff_commissions c where c.id = any (v_ids))::text,
      'commission_total', app.fmt_money((select coalesce(sum(c.amount_cents), 0) from staff_commissions c where c.id = any (v_ids))),
      'commissions', coalesce((select jsonb_agg(jsonb_build_object('booking', b.booking_number, 'month', to_char(c.month, 'FMMonth YYYY'),
                       'amount', app.fmt_money(c.amount_cents), 'what', case c.kind when 'clawback' then 'Reversed' when 'adjustment' then 'Adjustment' else app.bps_words(c.rate_bps) end)
                       order by c.month, b.booking_number) from staff_commissions c join bookings b on b.id = c.booking_id where c.id = any (v_ids)), '[]'::jsonb),
      'payout_method', case po.method when 'e_transfer' then 'e-Transfer' when 'bank_transfer' then 'Bank transfer' when 'wise' then 'Wise' when 'cash' then 'Cash'
                                      when 'pay_statement' then 'On your pay statement' else 'Other' end,
      'payout_reference', coalesce(po.reference, case when po.method = 'pay_statement' then to_char(po.pay_period, 'FMMonth YYYY') end, ''),
      'payout_date', coalesce(to_char(po.paid_on, 'FMMonth FMDD, YYYY'), ''),
      'sales_url', app.ntf_link(case when v_field then 'field_sales' else 'va_my_sales' end));
  end if;
  -- the owner's statement email: the kickbacks and staff commissions deducted before Owner Revenue (0023 printed $0.00
  -- and counted the rentals at Owner Revenue)
  if p_code = 'owner_statement_ready' then
    x := x || (select jsonb_build_object('kickbacks_deducted', app.fmt_money(-coalesce(sum(l.kickback_cents), 0)),
                                         'rentals_total', app.fmt_money(st.owner_revenue_cents + coalesce(sum(l.kickback_cents), 0)))
                 from owner_statements st left join owner_statement_lines l on l.owner_statement_id = st.id and l.line_type = 'rental'
                where st.id = p_event.entity_id group by st.owner_revenue_cents);
  end if;
  return x;
end $$;

-- ================================================================ 13. the doors
create or replace function app.ops58(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'manual_rental_create' then
    if nullif(p ->> 'sales_choice', '') is null and app.manual_rental_role(p_user) in ('va', 'field') then
      raise exception 'Choose "I sourced this client" or "Entered for CarmaCars"' using errcode = '22023';
    end if;
    return app.manual_rental_create(p_user, p);
  when 'quote_create' then return app.staff_quote_create(p_user, p);
  when 'quote_form' then
    return jsonb_build_object('vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'class', v.class) order by v.make, v.model)
                                                     from vehicles v join vehicle_listings l on l.vehicle_id = v.id and l.status = 'published'), '[]'::jsonb),
                              'min_notice_minutes', (app.settings()).booking_min_notice_minutes,
                              'price_floor_daily_cents', (app.settings()).custom_price_floor_daily_cents, 'price_max_discount_bps', (app.settings()).custom_price_max_discount_bps);
  when 'my_sales' then return app.staff_sales(p_user, p_user, p);
  when 'referrals' then return app.field_referrals(p_user);
  when 'commissions' then return app.commission_admin(p_user, p);
  when 'commission_reviews' then return app.commission_reviews(p_user);
  when 'commission_approve' then return app.commission_approve(p_user, p);
  when 'commission_reverse' then return app.commission_reverse(p_user, p);
  when 'commission_payout' then return app.commission_payout_record(p_user, p);
  when 'commission_rate_set' then return app.staff_commission_rate_set(p_user, p);
  when 'staff_household_set' then return app.staff_household_set(p_user, p);
  when 'price_review' then return app.price_review(p_user, p);
  when 'sales_claim_decide' then return app.sales_claim_decide(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_0057;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
begin
  if (p_call = 'ops_do' and p_name = 'manual_rental_create') or (p_call = 'va_do' and p_name = 'quote_create') or (p_call = 'va_read' and p_name = 'quote_form')
     or (p_call in ('va_read', 'field_read') and p_name = 'my_sales') or (p_call = 'field_read' and p_name = 'referrals')
     or (p_call = 'admin_read' and p_name in ('commissions', 'commission_reviews'))
     or (p_call = 'admin_do' and p_name in ('commission_approve', 'commission_reverse', 'commission_payout', 'commission_rate_set', 'staff_household_set', 'price_review', 'sales_claim_decide')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    if p_call = 'va_do' and not app.user_is_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    if p_call = 'field_read' and not app.user_is_field(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    if p_call = 'va_read' and not app.user_is_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.ops58(p_user, p_call, p_name, p_ - '_va');
  end if;
  -- an offer: the sender's choice once per booking ("I sourced this client" or "Entered for CarmaCars")
  if p_call in ('admin_do', 'va_do') and p_name in ('send_offer', 'resend_offer') and p_ ? 'booking' then
    perform app.door_begin(p_user, p_aal);
    select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking';
    if b.id is not null then perform app.offer_sales_choice(p_user, b.id, nullif(p_ ->> 'sales_choice', '')); end if;
    return app.door_0057(p_user, p_aal, p_call, p_name, p_ - 'sales_choice');
  end if;
  return app.door_0057(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 14. booking history kinds, privileges, audit
alter table booking_events drop constraint if exists booking_events_kind_check;
alter table booking_events add constraint booking_events_kind_check check (kind in ('adjusted', 'agreement_completed', 'agreement_opened', 'agreement_signed',
  'agreement_voided', 'booking_change', 'calendar_switch', 'cancelled', 'change_requested', 'confirmed', 'declined', 'deposit_waived', 'extension',
  'info_replied', 'info_requested', 'offer_approved', 'offer_expired', 'offer_sent', 'offer_withdrawn', 'payment_refused', 'promo_applied', 'promo_removed',
  'pushed_back', 'requested', 'verification', 'reopened', 'review_request', 'added_by_staff', 'sales_credit', 'custom_price'));

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array[
              'user_is_sales_staff', 'bookings_sales_sourced', 'kickback_ineligible_reason', 'custom_price_flags', 'booking_rate_sheet_cents', 'record_custom_price',
              'adjust_booking', 'va_guard_booking_edit', 'price_review', 'manual_rental_role', 'manual_rental_renters', 'manual_rental_quote', 'manual_rental_create_0058',
              'manual_rental_create', 'staff_quote_request', 'staff_quote_create', 'offer_sales_choice', 'sales_claim_decide', 'sales_reassign', 'sales_staff_options',
              'booking_paid_in_full', 'commission_base_cents', 'commission_own_reason', 'commission_scheme', 'sales_tier_bps', 'commission_month_days', 'commission_retier', 'commission_close',
              'commission_sync', 'commission_sync_trigger', 'staff_profiles_commission_retier', 'commission_approve', 'commission_reverse', 'commission_payout_record',
              'staff_commission_rate_set', 'staff_household_set', 'job_commission_month', 'booking_staff_commission_cents', 'compute_booking_split', 'owner_statement_lines_commission',
              'commission_split_refresh', 'sales_month_progress', 'bps_words', 'staff_commissions_json', 'staff_sales', 'staff_scorecard', 'field_referrals',
              'commission_admin', 'booking_sales_credit', 'admin_todo', 'commission_reviews', 'notification_recipients', 'notification_payload', 'ops58', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Each renamed function keeps its privileges; the function in its place gets the same.
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_0057', 'door'), ('adjust_booking_0016', 'adjust_booking'), ('kickback_ineligible_reason_0007', 'kickback_ineligible_reason'),
                          ('manual_rental_renters_0046', 'manual_rental_renters'), ('staff_scorecard_0057', 'staff_scorecard'), ('admin_todo_0054', 'admin_todo'),
                          ('notification_recipients_0053', 'notification_recipients'), ('ntf_payload_0054', 'notification_payload')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

select app.attach_audit();

-- ================================================================ 15. the month's job
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-commission-month', '41 * * * *', 'select app.job_commission_month()');
  end if;
end $$;

-- ================================================================ 16. bookings already on file
-- A field staff referral is their sourced rental (the commission replaces the referral fee); a staff member's own
-- quote or rental of the past carries no choice and earns nothing until an Admin credits it.
update bookings set sales_staff_id = referrer_staff_id, sales_source = 'referral', sales_sourced = true,
       sales_attributed_at = coalesce(sales_attributed_at, created_at), sales_attributed_by = referrer_staff_id
 where referrer_type = 'field_staff' and referrer_staff_id is not null and not sales_sourced and booking_type <> 'owner'
   and coalesce(sales_source, '') <> 'admin';
-- their splits not on a statement yet: the field staff Referral Kickback gives way to the commission
do $$
declare
  v uuid;
begin
  for v in select distinct s.booking_id from booking_splits s join bookings b on b.id = s.booking_id
            where b.referrer_type = 'field_staff' and s.owner_statement_id is null loop
    perform app.compute_booking_split(v);
  end loop;
end $$;

-- ================================================================ 17. the email catalogue
-- CATALOGUE 0058 START (generated by supabase/seed/0058_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('staff_commission_approved', 'staff_va_sales', array['staff_va_cs', 'staff_va_finance', 'staff_va_fleet', 'staff_field']::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Commission approved: {{commission_total}}', '{{commission_count}} commission(s) approved. You will hear from us again when it is paid.', 'Immediate', 'An Admin approves one or more of a staff member''s commissions (Admin > Money > Staff commissions). One email to that staff member, at their own address, for each approval. A Sales commission is approved after its month ends. Nothing is paid yet: the payment is recorded separately.', null, null, '[{"name":"commission_count","type":"string"},{"name":"commission_total","type":"string"},{"name":"commissions","type":"list","fields":["booking","month","what","amount"]},{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"sales_url","type":"url"}]'::jsonb, 'templates/staff_commission_approved.html', 'templates/staff_commission_approved.txt'),
  ('staff_commission_paid', 'staff_va_sales', array['staff_va_cs', 'staff_va_finance', 'staff_va_fleet', 'staff_field']::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Commission paid: {{commission_total}}', '{{payout_method}}, {{payout_date}}.', 'Immediate', 'An Admin records the payment of a staff member''s approved commissions (Admin > Money > Staff commissions > Record a payment): e-Transfer, bank transfer, Wise, cash, another way, or the monthly pay statement. One email to that staff member, at their own address, for each payment recorded.', null, null, '[{"name":"commission_count","type":"string"},{"name":"commission_total","type":"string"},{"name":"commissions","type":"list","fields":["booking","month","what","amount"]},{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"payout_date","type":"string"},{"name":"payout_method","type":"string"},{"name":"payout_reference","type":"string"},{"name":"sales_url","type":"url"}]'::jsonb, 'templates/staff_commission_paid.html', 'templates/staff_commission_paid.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0058 END
update notification_catalogue set emitted_by = 'app.commission_approve (0058)' where code = 'staff_commission_approved';
update notification_catalogue set emitted_by = 'app.commission_payout_record (0058)' where code = 'staff_commission_paid';

-- ================================================================ 18. the guides for this release
-- From docs/guides/content (docs/guides/src, exported). As 0057: a chapter still showing the text of the last release gets
-- the new one, published; a chapter an Admin edited keeps the Admin's text and gets the new one as a suggestion; a new
-- chapter is added.
create or replace function app.guide_release_0058(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v text := app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html);
begin
  if v = 'suggested' then
    update guide_sections set suggestion_model = 'CarmaCars (migration 0058)',
           review_note = 'CarmaCars updated this chapter for staff commissions (Add a rental for every function and field staff, "I sourced this client", prices typed by hand, Staff commissions). Your edited text was kept: compare it with the suggested text and use it, or keep yours.'
     where portal = p_portal and slug = p_slug;
  end if;
  return v;
end $$;
revoke all on function app.guide_release_0058(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0058(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0058 START (generated by supabase/seed/0058_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_0058('admin', 'getting-around-admin', 'chapter', 'start-here', 'Admin opens on To do: what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, Owners and partners, Money, People and Settings. Search finds any booking, car or person.

## To do

Start every shift here. Each line counts what is waiting and has one button to deal with it.

1. The list is in order of urgency: owner applications, booking requests, changes renters asked for, failed payments, agreements to countersign, tolls, listings, plates not checked, insurance and cars using sample photos.
2. Press the button on a line to go straight to that work. A line with nothing waiting moves to the bottom, under "more with nothing waiting".
3. Below the list: today''s pickups (ready or not ready) and today''s returns (due or late).
4. Press **Overview** for the money, fleet and queue figures, the alerts and the team''s sales for the month.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Tasks |
| Bookings | Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews |
| Cars | Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars |
| Owners and partners | Applications, Owners, Partners, Owner forms, Paid and signed |
| Money | Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Tolls and tickets, Insurer invoices, Reconciliation, Expenses |
| People | Renters, Staff, Investors, Portals and view as |
| Settings | All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
', 'Getting around Admin', 'To do, the menu, search, keyboard shortcuts and your other portals.',
  'Admin opens on To do: what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, Owners and partners, Money, People and Settings. Search finds any booking, car or person.

## To do

Start every shift here. Each line counts what is waiting and has one button to deal with it.

1. The list is in order of urgency: owner applications, booking requests, changes renters asked for, failed payments, agreements to countersign, tolls, listings, plates not checked, insurance, cars using sample photos, staff commissions to approve and to pay, prices typed by hand to review, and staff who say they sourced a website request.
2. Press the button on a line to go straight to that work. A line with nothing waiting moves to the bottom, under "more with nothing waiting".
3. Below the list: today''s pickups (ready or not ready) and today''s returns (due or late).
4. Press **Overview** for the money, fleet and queue figures, the alerts and the team''s sales for the month.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Tasks |
| Bookings | Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews |
| Cars | Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars |
| Owners and partners | Applications, Owners, Partners, Owner forms, Paid and signed |
| Money | Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Staff commissions, Tolls and tickets, Insurer invoices, Reconciliation, Expenses |
| People | Renters, Staff, Investors, Portals and view as |
| Settings | All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
',
  '<p class="gd-p">Admin opens on To do: what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, Owners and partners, Money, People and Settings. Search finds any booking, car or person.</p><section class="gd-task" id="getting-around-admin-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Start every shift here. Each line counts what is waiting and has one button to deal with it.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The list is in order of urgency: owner applications, booking requests, changes renters asked for, failed payments, agreements to countersign, tolls, listings, plates not checked, insurance, cars using sample photos, staff commissions to approve and to pay, prices typed by hand to review, and staff who say they sourced a website request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press the button on a line to go straight to that work. A line with nothing waiting moves to the bottom, under &quot;more with nothing waiting&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Below the list: today&#39;s pickups (ready or not ready) and today&#39;s returns (due or late).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Overview</b> for the money, fleet and queue figures, the alerts and the team&#39;s sales for the month.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-01-today-desktop-ea48309c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:22.6%;top:31.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:90.3%;top:31.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.4%;top:90.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.4%;top:22.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Group</th><th scope="col">Pages</th></tr></thead><tbody><tr><td>Today</td><td>To do, Overview, Tasks</td></tr><tr><td>Bookings</td><td>Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews</td></tr><tr><td>Cars</td><td>Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars</td></tr><tr><td>Owners and partners</td><td>Applications, Owners, Partners, Owner forms, Paid and signed</td></tr><tr><td>Money</td><td>Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Staff commissions, Tolls and tickets, Insurer invoices, Reconciliation, Expenses</td></tr><tr><td>People</td><td>Renters, Staff, Investors, Portals and view as</td></tr><tr><td>Settings</td><td>All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log</td></tr></tbody></table></div><div class="gd-figblock"><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/715"><img src="/guides/img/admin-31-menu-phone-667dc2fd.jpg" alt="On a phone: press Menu (1), then a group (2), then the page (3)." loading="lazy" decoding="async" width="390" height="715"><span class="gd-pin" style="left:10.3%;top:28.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:42.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.9%;top:48.3%" aria-hidden="true">3</span></div></div><figcaption>On a phone: press Menu (1), then a group (2), then the page (3).</figcaption></figure></div></section><section class="gd-task" id="getting-around-admin-search" data-gd-task><h2 class="gd-h2">Search</h2><p class="gd-p">The search box sits at the top of the menu, on every page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a booking number (CC-1042), a plate, a VIN, or a name or email address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Search</b> (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/search?q=CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/420"><img src="/guides/img/admin-32-search-desktop-ca548a70.jpg" alt="" loading="lazy" decoding="async" width="1440" height="420"><span class="gd-pin" style="left:7.4%;top:45.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:95%;top:46.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-keyboard-shortcuts" data-gd-task><h2 class="gd-h2">Keyboard shortcuts</h2><p class="gd-p">Press g, then a letter. Press / to jump to the search box.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Keys</th><th scope="col">Opens</th><th scope="col">Keys</th><th scope="col">Opens</th></tr></thead><tbody><tr><td>g t</td><td>To do</td><td>g v</td><td>Vehicles</td></tr><tr><td>g r</td><td>Requests</td><td>g l</td><td>Listings</td></tr><tr><td>g b</td><td>Bookings</td><td>g a</td><td>Applications</td></tr><tr><td>g c</td><td>Calendar</td><td>g o</td><td>Owners</td></tr><tr><td>g k</td><td>Tasks</td><td>g m</td><td>Payments and refunds</td></tr><tr><td>g s</td><td>All settings</td><td>/</td><td>Search</td></tr></tbody></table></div></section>');
select app.guide_release_0058('admin', 'people-and-access', 'chapter', 'getting-around-admin', 'Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.

## Portals and sign-in

Open **People** > **Portals and view as**. Every portal has a card.

1. Each card links to **Its sign-in page**, the address to send that person.
2. Choose a person in the list on the card.
3. Press **Open as this person** to see that portal as they see it.

![](/guides/img/admin-27-portals-desktop-0361bf61.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/portals; pins: 1 65.9 30.2, 2 58.1 39.4, 3 51.6 45.6")

## Invite a person

Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.

1. Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.
2. Fill in the Name and Email.
3. For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.
4. Press **Invite**. The link in the email works for 24 hours.

![](/guides/img/admin-27-portals-desktop-c10725cb.jpg "desktop; size: 1230 360; address: carmacars.ca/admin/portals; pins: 1 18.8 40.8, 2 50.0 40.8, 3 18.8 66.7, 4 9.8 87.8")

> Tip: Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: Owners and partners > Owners and People > Investors also have a one-click invite for a record without a sign-in.

## Send a password link

For anyone who forgot their password or let their invitation expire.

1. Under People who can sign in, search by name or email.
2. On their row, press **Send password link**. They get "Reset your CarmaCars password", valid for 24 hours.
3. **View as (...)** on the same row opens their portal, read only.

![](/guides/img/admin-27-portals-desktop-ee9b3e94.jpg "desktop; size: 1230 440; address: carmacars.ca/admin/portals; pins: 1 74.8 6.6, 2 68.2 28.6, 3 84.1 28.6")

## View as: see what someone sees

1. A red banner says "Viewing as Name (email), read only." on every page.
2. Click around their portal. Nothing can be changed: every save is refused.
3. Press **Exit** to come back. A view also ends by itself after 30 minutes.

![](/guides/img/admin-28-view-as-desktop-f858e38c.jpg "desktop; size: 1440 620; address: carmacars.ca/owner; pins: 1 48.6 4.5, 3 94.4 4.5")

> Watch out: Can''t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.

## The audit log

**Settings** > **Audit log** shows who changed what, and when.

1. Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.
2. Every View as is recorded (view_as_start), with the person viewed.
3. Search by table, record id or value.

![](/guides/img/admin-29-audit-desktop-b7504100.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/audit; pins: 1 22.6 31.1, 2 39.0 46.4, 3 89.6 20.7")

## Staff and roles

**People** > **Staff** opens Staff and roles.

1. Invite staff here too: Role, Name, Email, Main function and Also covers, then **Invite**.
2. Each row has **Send password link**, **View as (...)** and Limits (how much they may approve or refund).
3. Press **End access** to close their staff portal at once. **Restore** undoes it.

![](/guides/img/admin-26-staff-desktop-72287d0b.jpg "desktop; size: 1440 780; address: carmacars.ca/admin/settings/staff; pins: 1 20.8 59.0, 2 94.4 86.7, 3 83.3 92.6")

## Admin access

**Settings** > **All settings**, then Admin access. Who may hold the Admin role.

1. The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site''s nightly checks sign in with.
2. Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.
3. Change the list only if the business''s Admin address changes.

## Staff scorecards

See how each assistant is doing against the targets.

1. On a staff member''s row in Staff and roles, press **Scorecard**.
2. By week shows each measure (for example quote sent within 5 minutes) and the result for each week.
3. A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg "desktop; size: 1230 350; address: carmacars.ca/va/scorecard; pins: 2 21.1 42.9")

## Sales by staff member

See each person''s quotes, offers, rentals added, bookings confirmed and booked revenue. It is tracking only: the staff agreements allow no commission.

1. On a staff member''s row in Staff and roles, press **Sales**. Press **By week** or **By month**.
2. The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.
3. Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.
4. A deal credited to the wrong person? Press **Reassign** beside it, choose who and write the reason.
5. The whole team: **Today** > **Overview**, the Sales card at the bottom. Choose another month and press **Show**.

| Figure | How it is counted |
| --- | --- |
| Credited to | Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it. |
| Conversion | Of the deals credited in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off. |
', 'People and access', 'Portals and sign-in, invitations, password links, View as, staff and scorecards.',
  'Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.

## Portals and sign-in

Open **People** > **Portals and view as**. Every portal has a card.

1. Each card links to **Its sign-in page**, the address to send that person.
2. Choose a person in the list on the card.
3. Press **Open as this person** to see that portal as they see it.

![](/guides/img/admin-27-portals-desktop-0361bf61.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/portals; pins: 1 65.9 30.2, 2 58.1 39.4, 3 51.6 45.6")

## Invite a person

Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.

1. Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.
2. Fill in the Name and Email.
3. For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.
4. Press **Invite**. The link in the email works for 24 hours.

![](/guides/img/admin-27-portals-desktop-c10725cb.jpg "desktop; size: 1230 360; address: carmacars.ca/admin/portals; pins: 1 18.8 40.8, 2 50.0 40.8, 3 18.8 66.7, 4 9.8 87.8")

> Tip: Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: Owners and partners > Owners and People > Investors also have a one-click invite for a record without a sign-in.

## Send a password link

For anyone who forgot their password or let their invitation expire.

1. Under People who can sign in, search by name or email.
2. On their row, press **Send password link**. They get "Reset your CarmaCars password", valid for 24 hours.
3. **View as (...)** on the same row opens their portal, read only.

![](/guides/img/admin-27-portals-desktop-ee9b3e94.jpg "desktop; size: 1230 440; address: carmacars.ca/admin/portals; pins: 1 74.8 6.6, 2 68.2 28.6, 3 84.1 28.6")

## View as: see what someone sees

1. A red banner says "Viewing as Name (email), read only." on every page.
2. Click around their portal. Nothing can be changed: every save is refused.
3. Press **Exit** to come back. A view also ends by itself after 30 minutes.

![](/guides/img/admin-28-view-as-desktop-f858e38c.jpg "desktop; size: 1440 620; address: carmacars.ca/owner; pins: 1 48.6 4.5, 3 94.4 4.5")

> Watch out: Can''t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.

## The audit log

**Settings** > **Audit log** shows who changed what, and when.

1. Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.
2. Every View as is recorded (view_as_start), with the person viewed.
3. Search by table, record id or value.

![](/guides/img/admin-29-audit-desktop-b7504100.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/audit; pins: 1 22.6 31.1, 2 39.0 46.4, 3 89.6 20.7")

## Staff and roles

**People** > **Staff** opens Staff and roles.

1. Invite staff here too: Role, Name, Email, Main function and Also covers, then **Invite**.
2. Each row has **Send password link**, **View as (...)** and Limits (how much they may approve or refund).
3. Press **End access** to close their staff portal at once. **Restore** undoes it.

![](/guides/img/admin-26-staff-desktop-72287d0b.jpg "desktop; size: 1440 780; address: carmacars.ca/admin/settings/staff; pins: 1 20.8 59.0, 2 94.4 86.7, 3 83.3 92.6")

## Admin access

**Settings** > **All settings**, then Admin access. Who may hold the Admin role.

1. The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site''s nightly checks sign in with.
2. Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.
3. Change the list only if the business''s Admin address changes.

## Staff scorecards

See how each assistant is doing against the targets.

1. On a staff member''s row in Staff and roles, press **Scorecard**.
2. By week shows each measure (for example quote sent within 5 minutes) and the result for each week.
3. A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg "desktop; size: 1230 350; address: carmacars.ca/va/scorecard; pins: 2 21.1 42.9")

## Sales by staff member

See each person''s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.

1. On a staff member''s row in Staff and roles, press **Sales**. Press **By week** or **By month**.
2. The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.
3. Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.
4. A deal credited to the wrong person, or marked sourced when it was not? Press **Reassign** beside it, choose who, say whether they sourced the client, and write the reason.
5. **Commission rate** gives this person their own flat rate (empty: the Program settings). **Reverse** beside a commission stops it, for example for a household rental found later.
6. The whole team: **Today** > **Overview**, the Sales card at the bottom. Choose another month and press **Show**.

| Figure | How it is counted |
| --- | --- |
| Credited to | Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it. |
| Conversion | Of the deals credited in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off. |
',
  '<p class="gd-p">Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.</p><section class="gd-task" id="people-and-access-portals-and-sign-in" data-gd-task><h2 class="gd-h2">Portals and sign-in</h2><p class="gd-p">Open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Portals and view as</b>. Every portal has a card.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each card links to <b class="gd-ui">Its sign-in page</b>, the address to send that person.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a person in the list on the card.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Open as this person</b> to see that portal as they see it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-27-portals-desktop-0361bf61.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:65.9%;top:30.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:58.1%;top:39.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:51.6%;top:45.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-invite-a-person" data-gd-task><h2 class="gd-h2">Invite a person</h2><p class="gd-p">Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in the Name and Email.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Invite</b>. The link in the email works for 24 hours.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/360"><img src="/guides/img/admin-27-portals-desktop-c10725cb.jpg" alt="" loading="lazy" decoding="async" width="1230" height="360"><span class="gd-pin" style="left:18.8%;top:40.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:50%;top:40.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.8%;top:66.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:9.8%;top:87.8%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: Owners and partners &gt; Owners and People &gt; Investors also have a one-click invite for a record without a sign-in.</div></aside></section><section class="gd-task" id="people-and-access-send-a-password-link" data-gd-task><h2 class="gd-h2">Send a password link</h2><p class="gd-p">For anyone who forgot their password or let their invitation expire.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under People who can sign in, search by name or email.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On their row, press <b class="gd-ui">Send password link</b>. They get &quot;Reset your CarmaCars password&quot;, valid for 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">View as (...)</b> on the same row opens their portal, read only.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/440"><img src="/guides/img/admin-27-portals-desktop-ee9b3e94.jpg" alt="" loading="lazy" decoding="async" width="1230" height="440"><span class="gd-pin" style="left:74.8%;top:6.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:68.2%;top:28.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.1%;top:28.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-view-as-see-what-someone-sees" data-gd-task><h2 class="gd-h2">View as: see what someone sees</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A red banner says &quot;Viewing as Name (email), read only.&quot; on every page.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Click around their portal. Nothing can be changed: every save is refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Exit</b> to come back. A view also ends by itself after 30 minutes.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/620"><img src="/guides/img/admin-28-view-as-desktop-f858e38c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="620"><span class="gd-pin" style="left:48.6%;top:4.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.4%;top:4.5%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Can&#39;t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.</div></aside></section><section class="gd-task" id="people-and-access-the-audit-log" data-gd-task><h2 class="gd-h2">The audit log</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Audit log</b> shows who changed what, and when.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every View as is recorded (view_as_start), with the person viewed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Search by table, record id or value.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/audit</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-29-audit-desktop-b7504100.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:22.6%;top:31.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:39%;top:46.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.6%;top:20.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-staff-and-roles" data-gd-task><h2 class="gd-h2">Staff and roles</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b> opens Staff and roles.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Invite staff here too: Role, Name, Email, Main function and Also covers, then <b class="gd-ui">Invite</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row has <b class="gd-ui">Send password link</b>, <b class="gd-ui">View as (...)</b> and Limits (how much they may approve or refund).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End access</b> to close their staff portal at once. <b class="gd-ui">Restore</b> undoes it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/staff</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/780"><img src="/guides/img/admin-26-staff-desktop-72287d0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="780"><span class="gd-pin" style="left:20.8%;top:59%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.4%;top:86.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:83.3%;top:92.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-admin-access" data-gd-task><h2 class="gd-h2">Admin access</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Admin access. Who may hold the Admin role.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site&#39;s nightly checks sign in with.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change the list only if the business&#39;s Admin address changes.</div></li></ol></div></section><section class="gd-task" id="people-and-access-staff-scorecards" data-gd-task><h2 class="gd-h2">Staff scorecards</h2><p class="gd-p">See how each assistant is doing against the targets.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a staff member&#39;s row in Staff and roles, press <b class="gd-ui">Scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure (for example quote sent within 5 minutes) and the result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/350"><img src="/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg" alt="" loading="lazy" decoding="async" width="1230" height="350"><span class="gd-pin" style="left:21.1%;top:42.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-sales-by-staff-member" data-gd-task><h2 class="gd-h2">Sales by staff member</h2><p class="gd-p">See each person&#39;s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a staff member&#39;s row in Staff and roles, press <b class="gd-ui">Sales</b>. Press <b class="gd-ui">By week</b> or <b class="gd-ui">By month</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A deal credited to the wrong person, or marked sourced when it was not? Press <b class="gd-ui">Reassign</b> beside it, choose who, say whether they sourced the client, and write the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Commission rate</b> gives this person their own flat rate (empty: the Program settings). <b class="gd-ui">Reverse</b> beside a commission stops it, for example for a household rental found later.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The whole team: <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Overview</b>, the Sales card at the bottom. Choose another month and press <b class="gd-ui">Show</b>.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Figure</th><th scope="col">How it is counted</th></tr></thead><tbody><tr><td>Credited to</td><td>Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it.</td></tr><tr><td>Conversion</td><td>Of the deals credited in the period, the share confirmed so far.</td></tr><tr><td>Booked revenue</td><td>The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off.</td></tr></tbody></table></div></section>');
select app.guide_release_0058('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

> Tip: After the offer is out: **Withdraw to edit** takes it back, **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody) and write the reason. The booking''s history keeps it, and the deal stays in the same week and month.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
', 'Requests, offers and bookings', 'Answer a request with an offer, run a booking, and propose a change.',
  'Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

> Tip: After the offer is out: **Withdraw to edit** takes it back, **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
',
  '<p class="gd-p">Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:18.5%;top:21.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.3%;top:31.7%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-03-booking-review-desktop-84570463.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:21.7%;top:16.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:20%;top:45.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:65%;top:45.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:98.8%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:620/810"><img src="/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg" alt="" loading="lazy" decoding="async" width="620" height="810"><span class="gd-pin" style="left:91.9%;top:33.6%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>After the offer is out: <b class="gd-ui">Withdraw to edit</b> takes it back, <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b> and <b class="gd-ui">Cancel by CarmaCars</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:20.1%;top:24%" aria-hidden="true">1</span><span class="gd-pin" style="left:34.7%;top:58.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:20.1%;top:72.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:90.3%;top:18.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/530"><img src="/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="530"><span class="gd-pin" style="left:12.9%;top:15.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:35%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:49.8%;top:59.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:30.9%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section>');
select app.guide_release_0058('admin', 'owner-money', 'chapter', 'owners-and-onboarding', 'Owner fee invoices are issued on the notice day and debited on the 15th. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner invoices**

1. **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month. An invoice is never issued twice.
2. **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.
3. Filter by Open, Paid, Failed or In arrears. Failed invoices show the reason.
4. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment** under the invoice. Leave Amount empty for the full balance.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4, 4 51.6 84.3")

## The automatic debit

The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each mandate. Use **Pause**, **Resume** or **Send a notice now**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.

## Owner statements

**Money** > **Owner statements**

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 3 86.0 22.7")

## Company statements

CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")
', 'Owner money', 'Owner invoices, the automatic debit, statements, payouts and the company statement.',
  'Owner fee invoices are issued on the notice day and debited on the 15th. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner invoices**

1. **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month. An invoice is never issued twice.
2. **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.
3. Filter by Open, Paid, Failed or In arrears. Failed invoices show the reason.
4. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment** under the invoice. Leave Amount empty for the full balance.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4, 4 51.6 84.3")

## The automatic debit

The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each mandate. Use **Pause**, **Resume** or **Send a notice now**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.

## Owner statements

**Money** > **Owner statements**

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Staff commissions**. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| Customer service, finance, fleet, field staff | 10% (also the field referral fee) |
| Base | The rental charge before tax, after discounts, less refunds |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Company statements

CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")
',
  '<p class="gd-p">Owner fee invoices are issued on the notice day and debited on the 15th. Statements are built, approved and issued each month, and payouts follow.</p><section class="gd-task" id="owner-money-owner-invoices" data-gd-task><h2 class="gd-h2">Owner invoices</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner invoices</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Run the monthly invoices</b> issues the invoices for the 15th by hand, for a missed month. An invoice is never issued twice.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Issue all tracker invoices</b> bills the Tracker Install for each car waiting for its tracker.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Filter by Open, Paid, Failed or In arrears. Failed invoices show the reason.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Paid by e-Transfer, cheque, cash or bank transfer? Press <b class="gd-ui">Record payment</b> under the invoice. Leave Amount empty for the full balance.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/invoices</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:83.3%;top:22.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:41.7%;top:35.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:29%;top:43.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:51.6%;top:84.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="owner-money-the-automatic-debit" data-gd-task><h2 class="gd-h2">The automatic debit</h2><p class="gd-p">The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.</p><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>Invoices issued, one notice per owner, 10 days before</em></li><li><b>2</b><span>Debit day</span><em>The 15th from 6:00: one debit per invoice</em></li><li><b>3</b><span>Cleared</span><em>The invoice is paid</em></li><li><b>4</b><span>Returned, insufficient funds</span><em>The $50.00 Late Fee is added once; the same amount is tried again within 30 days</em></li><li><b>5</b><span>Returned for another reason</span><em>No retry and no Late Fee: the debit pauses and you get a task</em></li></ol><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">How it runs explains the policy in words, read from Program settings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Scheduled and processing lists each debit. <b class="gd-ui">Pause</b> holds one (a reason is needed).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owners lists each mandate. Use <b class="gd-ui">Pause</b>, <b class="gd-ui">Resume</b> or <b class="gd-ui">Send a notice now</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/920"><img src="/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="920"><span class="gd-pin" style="left:21.8%;top:21.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:21.5%;top:35.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.5%;top:75.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:84.7%;top:94.7%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Results: each debit, cleared or returned, with the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Run log: each notice and debit run, with its counts.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Notices sent: who was told what, for which debit day.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/520"><img src="/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg" alt="" loading="lazy" decoding="async" width="1230" height="520"><span class="gd-pin" style="left:11%;top:14.4%" aria-hidden="true">5</span><span class="gd-pin" style="left:10.2%;top:52.3%" aria-hidden="true">6</span><span class="gd-pin" style="left:15.4%;top:89.8%" aria-hidden="true">7</span></div></div></figure></div><p class="gd-p">Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner&#39;s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner&#39;s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.</div></aside></section><section class="gd-task" id="owner-money-owner-statements" data-gd-task><h2 class="gd-h2">Owner statements</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner statements</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Build all for a month</b> (or <b class="gd-ui">Build one</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open each draft. Check it, <b class="gd-ui">Rebuild</b> after a correction, <b class="gd-ui">Preview PDF</b>, then <b class="gd-ui">Approve</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Issue to the owner</b>. <b class="gd-ui">Reissue</b> sends a corrected copy; <b class="gd-ui">CSV</b> exports it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/400"><img src="/guides/img/admin-16-statements-desktop-43a313ea.jpg" alt="" loading="lazy" decoding="async" width="1440" height="400"><span class="gd-pin" style="left:79.9%;top:27.3%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/520"><img src="/guides/img/admin-17-statement-desktop-106ee57f.jpg" alt="An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts." loading="lazy" decoding="async" width="1440" height="520"><span class="gd-pin" style="left:86%;top:22.7%" aria-hidden="true">3</span></div></div><figcaption>An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.</figcaption></figure></div></section><section class="gd-task" id="owner-money-staff-commissions" data-gd-task><h2 class="gd-h2">Staff commissions</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Staff commissions</b>. Nothing is paid automatically.</p><ol class="gd-flow"><li><b>1</b><span>Not earned yet</span><em>The rental is ahead, or not paid in full</em></li><li><b>2</b><span>Pending approval</span><em>Completed and paid in full; a Sales month once it has ended</em></li><li><b>3</b><span>Approved</span><em>You approved it; the staff member is told</em></li><li><b>4</b><span>Paid</span><em>You recorded the payment; the staff member is told</em></li><li><b>5</b><span>Reversed</span><em>Cancelled, refunded or charged back; after payment it comes off the next payment</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">By person shows each staff member&#39;s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b> on a person (everything that may be approved now) or on one commission.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Record a payment</b>: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Prices to review</b> lists prices typed by hand; <b class="gd-ui">Sourcing claims</b> lists staff who say they sourced a website request; <b class="gd-ui">Payments made</b> lists each payment.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month&#39;s rentals</td></tr><tr><td>Customer service, finance, fleet, field staff</td><td>10% (also the field referral fee)</td></tr><tr><td>Base</td><td>The rental charge before tax, after discounts, less refunds</td></tr><tr><td>On the owner statement</td><td>An owner&#39;s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner&#39;s car: from CarmaCars&#39; commission. A CarmaCars-owned car: a CarmaCars expense</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A commission that changes after an owner statement was built (a refund, or the month&#39;s Sales tier) goes on the owner&#39;s next statement as an adjustment line.</div></aside></section><section class="gd-task" id="owner-money-company-statements" data-gd-task><h2 class="gd-h2">Company statements</h2><p class="gd-p">CarmaCars&#39; own monthly statement, in twelve sections.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between Total, Per owner and Per vehicle.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Download <b class="gd-ui">PDF</b>, <b class="gd-ui">PDF by owner</b> or <b class="gd-ui">PDF by vehicle</b>, or press <b class="gd-ui">Email me the PDFs</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Finalize</b> freezes the month. <b class="gd-ui">Rebuild</b> works until then.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/reports</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:20.8%;top:28%" aria-hidden="true">1</span><span class="gd-pin" style="left:19.4%;top:59.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.1%;top:15.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:46.9%;top:15.5%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_0058('admin', 'settings', 'chapter', 'tolls-and-tickets', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff agreement defaults by function, at the bottom: pay (a month or an hour), the rate, full or part time, days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Press **Save the defaults**.
5. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending.
4. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
5. Your own PDF instead? **Send a PDF to sign** still works.
6. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
7. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. A rewrite that did not pass the checks is not published. Its section shows **Needs review** with the suggested text: press **Use this text as the draft** or **Dismiss the suggestion**, then **Mark reviewed**.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten or wait for review, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%).
5. Staff agreement defaults by function, at the bottom: pay (a month or an hour), the rate, full or part time, days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Press **Save the defaults**.
6. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending.
4. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
5. Your own PDF instead? **Send a PDF to sign** still works.
6. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
7. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. A rewrite that did not pass the checks is not published. Its section shows **Needs review** with the suggested text: press **Use this text as the draft** or **Dismiss the suggestion**, then **Mark reviewed**.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten or wait for review, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month or an hour), the rate, full or part time, days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;The owner signs here&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.</div></aside></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A rewrite that did not pass the checks is not published. Its section shows <b class="gd-ui">Needs review</b> with the suggested text: press <b class="gd-ui">Use this text as the draft</b> or <b class="gd-ui">Dismiss the suggestion</b>, then <b class="gd-ui">Mark reviewed</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten or wait for review, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section>');
select app.guide_release_0058('va', 'your-workday', 'chapter', 'start-here', 'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today and My scorecard (Sales also has My sales). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Owner forms) |
| Sales | My work (also My sales), Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar), Renters (Find a renter) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. **Sheet** opens the step-by-step procedure.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
', 'Your workday', 'The menu, To do, task actions, Today, switching functions and your scorecard.',
  'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today, My scorecard and My sales. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Owner forms) |
| Sales | Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar), Renters (Find a renter), Rentals (Add a rental, New quote) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. **Sheet** opens the step-by-step procedure.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
',
  '<p class="gd-p">Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.</p><section class="gd-task" id="your-workday-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">My work comes first: To do, Today, My scorecard and My sales. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Function</th><th scope="col">Groups and pages</th></tr></thead><tbody><tr><td>Customer service</td><td>Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Owner forms)</td></tr><tr><td>Sales</td><td>Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads)</td></tr><tr><td>Finance</td><td>Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote)</td></tr><tr><td>Fleet</td><td>Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar), Renters (Find a renter), Rentals (Add a rental, New quote)</td></tr></tbody></table></div></section><section class="gd-task" id="your-workday-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top line shows your function and how many tasks are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours. <b class="gd-ui">Sheet</b> opens the step-by-step procedure.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:13.9%;top:5%" aria-hidden="true">1</span><span class="gd-pin" style="left:36.1%;top:17.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.9%;top:43.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:91.7%;top:52.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="your-workday-work-a-task" data-gd-task><h2 class="gd-h2">Work a task</h2><p class="gd-p">Open the task. The buttons along the top move it on.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">What it does</th></tr></thead><tbody><tr><td><b class="gd-ui">Open the working screen</b></td><td>Jumps to the booking, car or owner the task is about.</td></tr><tr><td><b class="gd-ui">Done</b></td><td>You finished it. It leaves the queue.</td></tr><tr><td><b class="gd-ui">Waiting</b></td><td>You are waiting on someone (a renter, an owner). It stays yours.</td></tr><tr><td><b class="gd-ui">Escalate</b></td><td>It needs an Admin. Add why.</td></tr><tr><td><b class="gd-ui">Hand over</b></td><td>Give it to someone else on the team.</td></tr><tr><td><b class="gd-ui">Add a note</b></td><td>Leave a note for whoever looks next.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.</div></aside></section><section class="gd-task" id="your-workday-today" data-gd-task><h2 class="gd-h2">Today</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today lists pickups and returns, and what is due, for your function.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press a booking number to open it. <b class="gd-ui">To do</b> takes you back to your tasks.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/today</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/700"><img src="/guides/img/va-cs-02-today-desktop-dfd277b7.jpg" alt="" loading="lazy" decoding="async" width="1440" height="700"><span class="gd-pin" style="left:20.8%;top:14.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="your-workday-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The queue shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, hours, rate and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>). Several documents? One signature covers all of them. The signed copy stays on the same page.</div></li></ol></div></section><section class="gd-task" id="your-workday-several-functions-switch-with-working-as" data-gd-task><h2 class="gd-h2">Several functions? Switch with Working as</h2><p class="gd-p">If you cover more than one function, <b class="gd-ui">Working as</b> above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.</p></section><section class="gd-task" id="your-workday-your-scorecard" data-gd-task><h2 class="gd-h2">Your scorecard</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure, its target and your result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/360"><img src="/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg" alt="" loading="lazy" decoding="async" width="1440" height="360"><span class="gd-pin" style="left:4.2%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:62.5%;top:58.3%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_0058('va', 'sales', 'chapter', 'fleet', 'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, New quote, Add a rental, Calendar and Owner leads.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works. Answer requests and follow offers out.
2. **New quote**: price a car for a caller and press **Create the request**, as in chapter 2.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 13.8 19.3")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## My sales

Open **My work** > **My sales**. It shows your own sales only. Nothing here is a commission: it is for tracking.

1. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
2. By week (or By month) lists each period with the same figures, newest first.
3. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
4. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |

## Owner leads

1. Owner leads: each enquiry with the name, contact, car and status.
2. Press **Take it** to make it yours, then call the owner.
3. Press **Update** to set the status. When you close a lead, say why.
4. Owner applications, last 90 days, shows who applied and how far onboarding has come.

![](/guides/img/va-sales-04-leads-desktop-3402e913.jpg "desktop; size: 1230 400; address: carmacars.ca/va/leads; pins: 1 6.5 26.5, 3 94.8 44.0, 4 15.4 63.0")
', 'Sales', 'Requests and offers, new quotes and owner leads.',
  'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, New quote, Add a rental, Calendar and Owner leads.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works. Answer requests and follow offers out.
2. **New quote**: price a car for a caller and press **Create the request**, as in chapter 2.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 13.8 19.3")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## My sales

Open **My work** > **My sales**. It shows your own sales and commissions only.

1. Commissions comes first. In Sales your rate depends on the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%. The bar shows your days against the target of 100, and says when your rate rises.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owner leads

1. Owner leads: each enquiry with the name, contact, car and status.
2. Press **Take it** to make it yours, then call the owner.
3. Press **Update** to set the status. When you close a lead, say why.
4. Owner applications, last 90 days, shows who applied and how far onboarding has come.

![](/guides/img/va-sales-04-leads-desktop-3402e913.jpg "desktop; size: 1230 400; address: carmacars.ca/va/leads; pins: 1 6.5 26.5, 3 94.8 44.0, 4 15.4 63.0")
',
  '<p class="gd-p">You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.</p><p class="gd-p">Your menu: To do, Today, My scorecard and My sales, then Requests and offers, New quote, Add a rental, Calendar and Owner leads.</p><section class="gd-task" id="sales-requests-offers-and-new-quotes" data-gd-task><h2 class="gd-h2">Requests, offers and new quotes</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Requests and offers</b>: the same queue customer service works. Answer requests and follow offers out.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">New quote</b>: price a car for a caller and press <b class="gd-ui">Create the request</b>, as in chapter 2.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:13.8%;top:19.3%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your first reply target is 5 minutes, the &quot;Quote sent&quot; measure on your scorecard. Follow every offer out before it expires.</div></aside></section><section class="gd-task" id="sales-my-sales" data-gd-task><h2 class="gd-h2">My sales</h2><p class="gd-p">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My sales</b>. It shows your own sales and commissions only.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Commissions comes first. In Sales your rate depends on the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%. The bar shows your days against the target of 100, and says when your rate rises.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press <b class="gd-ui">By month</b> for months, <b class="gd-ui">By week</b> for weeks.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">By week (or By month) lists each period with the same figures, newest first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Figure</th><th scope="col">How it is counted</th></tr></thead><tbody><tr><td>Credited to you</td><td>A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else.</td></tr><tr><td>Quotes created, offers sent, rentals added</td><td>Counted on the day they happened.</td></tr><tr><td>Bookings confirmed, booked revenue</td><td>Counted on the day the booking was confirmed.</td></tr><tr><td>Conversion</td><td>Of the deals credited to you in the period, the share confirmed so far.</td></tr><tr><td>Booked revenue</td><td>The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off.</td></tr><tr><td>Rental days (Sales)</td><td>The days of the completed, paid rentals you sourced that end in the month. The month&#39;s tier applies to all of that month&#39;s rentals.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Sales commissions are approved after the month ends, when the month&#39;s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.</div></aside></section><section class="gd-task" id="sales-owner-leads" data-gd-task><h2 class="gd-h2">Owner leads</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Owner leads: each enquiry with the name, contact, car and status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours, then call the owner.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Update</b> to set the status. When you close a lead, say why.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owner applications, last 90 days, shows who applied and how far onboarding has come.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/leads</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/400"><img src="/guides/img/va-sales-04-leads-desktop-3402e913.jpg" alt="" loading="lazy" decoding="async" width="1230" height="400"><span class="gd-pin" style="left:6.5%;top:26.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:44%" aria-hidden="true">3</span><span class="gd-pin" style="left:15.4%;top:63%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_0058('va', 'add-a-rental-by-hand', 'chapter', 'sales', 'Customer service and Sales add rentals that come in by phone, at the counter, from Turo, a partner or an insurer. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
3. Press **Check the calendar and the price**. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code; a price typed by hand is for Admins.
4. Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as **Paid another way**, **Send a payment link** or **Charge the saved card when the renter signs**.
5. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
6. A rental you add is credited to you. In Sales it shows in My sales as a rental you added, and as a booking confirmed once it is confirmed.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
', 'Add a rental by hand', 'Choose the car and dates, find the renter, price it, record how it is paid.',
  'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
3. Press **Check the calendar and the price**. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code.
4. To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.
5. Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as **Paid another way**, **Send a payment link** or **Charge the saved card when the renter signs**.
6. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
7. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
8. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
',
  '<p class="gd-p">Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.</p><section class="gd-task" id="add-a-rental-by-hand-add-a-rental" data-gd-task><h2 class="gd-h2">Add a rental</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Check the calendar and the price</b>. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as <b class="gd-ui">Paid another way</b>, <b class="gd-ui">Send a payment link</b> or <b class="gd-ui">Charge the saved card when the renter signs</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Under Who found this client, choose <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Press <b class="gd-ui">Add the rental</b>. The renter gets the confirmation email unless you tick <b class="gd-ui">Do not email the renter</b>.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.</div></aside></section>');
select app.guide_release_0058('va', 'commissions', 'chapter', 'add-a-rental-by-hand', null, 'Commissions', 'I sourced this client, your rate, when it is earned, approved and paid.',
  'Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.

## Mark who found the client

Every rental, quote and offer you enter asks: **I sourced this client** or **Entered for CarmaCars**.

1. Choose **I sourced this client** when you found the renter yourself: someone you know, your own post or your own outreach.
2. Choose **Entered for CarmaCars** when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.
3. A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.

|  | Commission |
| --- | --- |
| Sales | By the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all of that month''s rentals |
| Customer service, finance, fleet | 10% |
| How much | The rate on the rental charge before tax, after discounts, less refunds |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Paid | After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed |

> Tip: A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.
',
  '<p class="gd-p">Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.</p><section class="gd-task" id="commissions-mark-who-found-the-client" data-gd-task><h2 class="gd-h2">Mark who found the client</h2><p class="gd-p">Every rental, quote and offer you enter asks: <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose <b class="gd-ui">I sourced this client</b> when you found the renter yourself: someone you know, your own post or your own outreach.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">Entered for CarmaCars</b> when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>By the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all of that month&#39;s rentals</td></tr><tr><td>Customer service, finance, fleet</td><td>10%</td></tr><tr><td>How much</td><td>The rate on the rental charge before tax, after discounts, less refunds</td></tr><tr><td>When earned</td><td>When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental</td></tr><tr><td>Paid</td><td>After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.</div></aside></section>');
select app.guide_release_0058('va', 'quick-reference', 'reference', 'shared-tools', '### Where things are

| Item | What it is for |
| --- | --- |
| **To do** | Your function''s tasks, oldest due first |
| **Today** | Pickups, returns, what is due |
| **Working as** | Switch function (above the menu) |
| **Customer service** | Requests, New quote, Renter messages, Owner forms |
| **Finance** | Payments, Tolls and tickets, Reconciliation, Turo trips |
| **Fleet** | Field jobs, Daily checks, Photo reviews, Listings, Similar cars |
| **Sales** | Requests and offers, New quote, Add a rental, Owner leads |
| **My sales** | Sales: your quotes, offers, bookings and booked revenue |
| **My scorecard** | Your results by week |

### Top tasks

1. *Take a task:* **My work** > **To do**, **Take it**, then **Done**
2. *Send an offer:* **Bookings** > **Requests**, the booking, then **Send the offer**
3. *Quote a caller:* **Bookings** > **New quote**, then **Create the request**
4. *See your sales:* **My work** > **My sales**, then **By week** or **By month**
5. *Review Forms C and D:* **Owner forms** > **Approve**
6. *Read a toll notice:* **Tolls and tickets** > **Read a notice**
7. *Issue a refund:* **Request the refund**, **Issue the refund**
8. *Schedule a field job:* **Field jobs** > **Schedule**
9. *Cover a plate:* **Cover the plate**, **Save the covered photo**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A task is above your limit** | Press **Escalate** and say why. An Admin picks it up. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost your phone? Tell an Admin. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **To do** | Your function''s tasks, oldest due first |
| **Today** | Pickups, returns, what is due |
| **Working as** | Switch function (above the menu) |
| **Customer service** | Requests, New quote, Renter messages, Owner forms |
| **Finance** | Payments, Tolls and tickets, Reconciliation, Turo trips |
| **Fleet** | Field jobs, Daily checks, Photo reviews, Listings, Similar cars |
| **Sales** | Requests and offers, New quote, Add a rental, Owner leads |
| **Add a rental, New quote** | Every function |
| **My sales** | Your commissions, quotes, offers, bookings and booked revenue |
| **My scorecard** | Your results by week |

### Top tasks

1. *Take a task:* **My work** > **To do**, **Take it**, then **Done**
2. *Send an offer:* **Bookings** > **Requests**, the booking, then **Send the offer**
3. *Quote a caller:* **Bookings** > **New quote**, then **Create the request**
4. *See your sales:* **My work** > **My sales**, then **By week** or **By month**
5. *Claim a client you found:* **I sourced this client** when you add the rental or send the offer
6. *Review Forms C and D:* **Owner forms** > **Approve**
7. *Read a toll notice:* **Tolls and tickets** > **Read a notice**
8. *Issue a refund:* **Request the refund**, **Issue the refund**
9. *Schedule a field job:* **Field jobs** > **Schedule**
10. *Cover a plate:* **Cover the plate**, **Save the covered photo**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A task is above your limit** | Press **Escalate** and say why. An Admin picks it up. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost your phone? Tell an Admin. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">To do</b></td><td>Your function&#39;s tasks, oldest due first</td></tr><tr><td><b class="gd-ui">Today</b></td><td>Pickups, returns, what is due</td></tr><tr><td><b class="gd-ui">Working as</b></td><td>Switch function (above the menu)</td></tr><tr><td><b class="gd-ui">Customer service</b></td><td>Requests, New quote, Renter messages, Owner forms</td></tr><tr><td><b class="gd-ui">Finance</b></td><td>Payments, Tolls and tickets, Reconciliation, Turo trips</td></tr><tr><td><b class="gd-ui">Fleet</b></td><td>Field jobs, Daily checks, Photo reviews, Listings, Similar cars</td></tr><tr><td><b class="gd-ui">Sales</b></td><td>Requests and offers, New quote, Add a rental, Owner leads</td></tr><tr><td><b class="gd-ui">Add a rental, New quote</b></td><td>Every function</td></tr><tr><td><b class="gd-ui">My sales</b></td><td>Your commissions, quotes, offers, bookings and booked revenue</td></tr><tr><td><b class="gd-ui">My scorecard</b></td><td>Your results by week</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Take a task:</em> <b class="gd-ui">My work</b> &gt; <b class="gd-ui">To do</b>, <b class="gd-ui">Take it</b>, then <b class="gd-ui">Done</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Send an offer:</em> <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>, the booking, then <b class="gd-ui">Send the offer</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Quote a caller:</em> <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">New quote</b>, then <b class="gd-ui">Create the request</b></div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>See your sales:</em> <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My sales</b>, then <b class="gd-ui">By week</b> or <b class="gd-ui">By month</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Claim a client you found:</em> <b class="gd-ui">I sourced this client</b> when you add the rental or send the offer</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Review Forms C and D:</em> <b class="gd-ui">Owner forms</b> &gt; <b class="gd-ui">Approve</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Read a toll notice:</em> <b class="gd-ui">Tolls and tickets</b> &gt; <b class="gd-ui">Read a notice</b></div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><em>Issue a refund:</em> <b class="gd-ui">Request the refund</b>, <b class="gd-ui">Issue the refund</b></div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t"><em>Schedule a field job:</em> <b class="gd-ui">Field jobs</b> &gt; <b class="gd-ui">Schedule</b></div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t"><em>Cover a plate:</em> <b class="gd-ui">Cover the plate</b>, <b class="gd-ui">Save the covered photo</b></div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">A task is above your limit</b></td><td>Press <b class="gd-ui">Escalate</b> and say why. An Admin picks it up.</td></tr><tr><td><b class="gd-ui">Asked for a 6-digit code</b></td><td>Open your authenticator app. Lost your phone? Tell an Admin.</td></tr></tbody></table></div>');
select app.guide_release_0058('field', 'my-jobs', 'chapter', 'start-here', 'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Report**, **Referrals** and **Profile**. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. Each card: the kind, the time, the status, the car and plate.
4. Press **Open the job** to start.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-421eca90.jpg "phone; size: 390 945; pins: 1 7.7 19.6, 2 76.9 27.5, 3 89.7 37.0, 4 88.5 46.6, 5 76.9 56.3")

> Tip: Need help on a job? Call CarmaCars at 647-575-3377. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-a0feec93.jpg "phone; size: 390 635; pins: 1 94.9 51.2, 2 94.9 64.3, 3 94.9 79.5, 4 94.9 93.9")

## Move a car

1. Under Vehicle moves, choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km).
3. Press **Start a move**. When you arrive, press **End the move** and enter the odometer again.

![](/guides/img/field-01-today-phone-27dfe7af.jpg "phone; size: 390 450; pins: 1 87.2 22.2, 2 87.2 60.4, 3 87.2 93.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**).
', 'My jobs', 'Your job list, a job card, maps and car moves.',
  'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Report**, **Add a rental**, **My sales**, **Referrals** and **Profile**. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. Each card: the kind, the time, the status, the car and plate.
4. Press **Open the job** to start.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-421eca90.jpg "phone; size: 390 945; pins: 1 7.7 19.6, 2 76.9 27.5, 3 89.7 37.0, 4 88.5 46.6, 5 76.9 56.3")

> Tip: Need help on a job? Call CarmaCars at 647-575-3377. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-a0feec93.jpg "phone; size: 390 635; pins: 1 94.9 51.2, 2 94.9 64.3, 3 94.9 79.5, 4 94.9 93.9")

## Move a car

1. Under Vehicle moves, choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km).
3. Press **Start a move**. When you arrive, press **End the move** and enter the odometer again.

![](/guides/img/field-01-today-phone-27dfe7af.jpg "phone; size: 390 450; pins: 1 87.2 22.2, 2 87.2 60.4, 3 87.2 93.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**).
',
  '<p class="gd-p">Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.</p><section class="gd-task" id="my-jobs-your-job-list" data-gd-task><h2 class="gd-h2">Your job list</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The menu: <b class="gd-ui">My jobs</b>, <b class="gd-ui">Report</b>, <b class="gd-ui">Add a rental</b>, <b class="gd-ui">My sales</b>, <b class="gd-ui">Referrals</b> and <b class="gd-ui">Profile</b>. <b class="gd-ui">Sign out</b> is top right.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between <b class="gd-ui">Today</b> and <b class="gd-ui">Tomorrow</b>. Jobs are in time order.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each card: the kind, the time, the status, the car and plate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Open the job</b> to start.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Moving a car that has no job? Use Vehicle moves (see below).</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/945"><img src="/guides/img/field-01-today-phone-421eca90.jpg" alt="" loading="lazy" decoding="async" width="390" height="945"><span class="gd-pin" style="left:7.7%;top:19.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:27.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.7%;top:37%" aria-hidden="true">3</span><span class="gd-pin" style="left:88.5%;top:46.6%" aria-hidden="true">4</span><span class="gd-pin" style="left:76.9%;top:56.3%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need help on a job? Call CarmaCars at 647-575-3377. The link is at the bottom of My jobs.</div></aside></section><section class="gd-task" id="my-jobs-open-a-job" data-gd-task><h2 class="gd-h2">Open a job</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card shows the kind, the time, the car, the plate and colour.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The address, with <b class="gd-ui">Open in maps</b> for directions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For a handover: the booking, the renter&#39;s name and phone, the Card on File and the licence on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Acknowledge</b> so the office knows you have it. Then press <b class="gd-ui">Start</b> when you are with the car.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/635"><img src="/guides/img/field-02-job-phone-a0feec93.jpg" alt="" loading="lazy" decoding="async" width="390" height="635"><span class="gd-pin" style="left:94.9%;top:51.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.9%;top:64.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:94.9%;top:79.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.9%;top:93.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="my-jobs-move-a-car" data-gd-task><h2 class="gd-h2">Move a car</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Vehicle moves, choose the Car and Why (for example Reposition).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in From and the Odometer (km).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Start a move</b>. When you arrive, press <b class="gd-ui">End the move</b> and enter the odometer again.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/450"><img src="/guides/img/field-01-today-phone-27dfe7af.jpg" alt="" loading="lazy" decoding="async" width="390" height="450"><span class="gd-pin" style="left:87.2%;top:22.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:87.2%;top:60.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:87.2%;top:93.3%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="my-jobs-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">My jobs shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, wage and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>).</div></li></ol></div></section>');
select app.guide_release_0058('field', 'report-rentals-referrals-and-profile', 'chapter', 'photo-shoots', null, 'Report, rentals, referrals and profile', 'Report an incident, add a rental, commissions, your referral link and your profile.',
  'Report anything that happens on the road, add a rental for a renter you found, share your referral link, and keep your details up to date.

## Report something

1. Open **Report** and choose the Car.
2. Choose What happened: **New damage found**, **Warning light**, **Collision while I was driving**, **Ticket or toll while I was driving**, **Lost property found** or **Something else**.
3. Write the Details: where, when and what you see.
4. Press **Take a photo** for each photo, then **Send the report**.

![](/guides/img/field-03-report-phone-2adac4d1.jpg "phone; size: 390 965; pins: 1 92.3 29.5, 2 92.3 37.3, 3 92.3 83.4, 4 92.3 97.9")

> Watch out: In a collision, make sure everyone is safe and call 911 if anyone is hurt. Then call CarmaCars at 647-575-3377 before you send the report.

## Add a rental for a renter you found

1. Open **Add a rental**. Choose the car, the dates and the places, then type the renter''s details. A renter already on file is found by their email.
2. Press **Check the calendar and the price**. To charge another price, type it with the reason: a price far under the rate sheet is flagged for an Admin, not refused.
3. Choose **Send a payment link** or **Charge the saved card when the renter signs**. You never take payment yourself.
4. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**, then press **Add the rental**.

## Commissions

1. You earn 10% of the rental charge (before tax, after discounts, less refunds) of each rental you sourced: one you added and marked I sourced this client, or a booking made with your referral link.
2. It is earned when the rental is completed and paid in full, then an Admin approves it and it is paid on your pay date.
3. **My sales** shows each commission: not earned yet, pending approval, approved, paid or reversed. A refund after payment comes off a later commission.

## Referrals and profile

1. **Referrals**: your own referral link. Press **Copy the link**, or let someone scan its QR code. A booking made with it counts as a rental you sourced.
2. **Profile**: **Save my phone**, **Set up two-step sign-in**, **Change my password** and **Sign out**.

![](/guides/img/field-04-profile-phone-56e58ae3.jpg "phone; size: 390 905; pins: 2 93.6 63.9")
',
  '<p class="gd-p">Report anything that happens on the road, add a rental for a renter you found, share your referral link, and keep your details up to date.</p><section class="gd-task" id="report-rentals-referrals-and-profile-report-something" data-gd-task><h2 class="gd-h2">Report something</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Report</b> and choose the Car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose What happened: <b class="gd-ui">New damage found</b>, <b class="gd-ui">Warning light</b>, <b class="gd-ui">Collision while I was driving</b>, <b class="gd-ui">Ticket or toll while I was driving</b>, <b class="gd-ui">Lost property found</b> or <b class="gd-ui">Something else</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Details: where, when and what you see.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Take a photo</b> for each photo, then <b class="gd-ui">Send the report</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/965"><img src="/guides/img/field-03-report-phone-2adac4d1.jpg" alt="" loading="lazy" decoding="async" width="390" height="965"><span class="gd-pin" style="left:92.3%;top:29.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:92.3%;top:37.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:92.3%;top:83.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:92.3%;top:97.9%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>In a collision, make sure everyone is safe and call 911 if anyone is hurt. Then call CarmaCars at 647-575-3377 before you send the report.</div></aside></section><section class="gd-task" id="report-rentals-referrals-and-profile-add-a-rental-for-a-renter-you-found" data-gd-task><h2 class="gd-h2">Add a rental for a renter you found</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Add a rental</b>. Choose the car, the dates and the places, then type the renter&#39;s details. A renter already on file is found by their email.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Check the calendar and the price</b>. To charge another price, type it with the reason: a price far under the rate sheet is flagged for an Admin, not refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose <b class="gd-ui">Send a payment link</b> or <b class="gd-ui">Charge the saved card when the renter signs</b>. You never take payment yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Who found this client, choose <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>, then press <b class="gd-ui">Add the rental</b>.</div></li></ol></div></section><section class="gd-task" id="report-rentals-referrals-and-profile-commissions" data-gd-task><h2 class="gd-h2">Commissions</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You earn 10% of the rental charge (before tax, after discounts, less refunds) of each rental you sourced: one you added and marked I sourced this client, or a booking made with your referral link.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">It is earned when the rental is completed and paid in full, then an Admin approves it and it is paid on your pay date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">My sales</b> shows each commission: not earned yet, pending approval, approved, paid or reversed. A refund after payment comes off a later commission.</div></li></ol></div></section><section class="gd-task" id="report-rentals-referrals-and-profile-referrals-and-profile" data-gd-task><h2 class="gd-h2">Referrals and profile</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Referrals</b>: your own referral link. Press <b class="gd-ui">Copy the link</b>, or let someone scan its QR code. A booking made with it counts as a rental you sourced.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Profile</b>: <b class="gd-ui">Save my phone</b>, <b class="gd-ui">Set up two-step sign-in</b>, <b class="gd-ui">Change my password</b> and <b class="gd-ui">Sign out</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/905"><img src="/guides/img/field-04-profile-phone-56e58ae3.jpg" alt="" loading="lazy" decoding="async" width="390" height="905"><span class="gd-pin" style="left:93.6%;top:63.9%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_0058('field', 'quick-reference', 'reference', 'report-rentals-referrals-and-profile', '### Where things are

| Item | What it is for |
| --- | --- |
| **My jobs** | Today and Tomorrow, in order; Vehicle moves |
| **A job** | Open in maps, Acknowledge, Start |
| **Report** | Damage, warning light, collision, ticket, lost property |
| **Referrals** | Your link and QR code |
| **Profile** | Phone, two-step sign-in, password, Sign out |

### Top tasks

1. *Start a job:* **Open the job**, **Acknowledge**, **Start**
2. *Hand over a car:* Every step, then **Hand over the keys**
3. *Stop a handover:* **Stop: do not release the car**, call us
4. *Take a car back:* Every step, then **Complete the return**
5. *Shoot listing photos:* **Take photo**, then **Submit for listing**
6. *Move a car:* **Start a move**, then **End the move**
7. *Report an incident:* **Report** > **Send the report**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A photo did not upload** | Check your signal, then press **Send again**. |
| **The renter does not match** | Do not hand over. Press Stop and call us. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **My jobs** | Today and Tomorrow, in order; Vehicle moves |
| **A job** | Open in maps, Acknowledge, Start |
| **Report** | Damage, warning light, collision, ticket, lost property |
| **Add a rental** | A renter you found: a payment link or the saved card |
| **My sales** | Your rentals and commissions |
| **Referrals** | Your link and QR code |
| **Profile** | Phone, two-step sign-in, password, Sign out |

### Top tasks

1. *Start a job:* **Open the job**, **Acknowledge**, **Start**
2. *Hand over a car:* Every step, then **Hand over the keys**
3. *Stop a handover:* **Stop: do not release the car**, call us
4. *Take a car back:* Every step, then **Complete the return**
5. *Shoot listing photos:* **Take photo**, then **Submit for listing**
6. *Move a car:* **Start a move**, then **End the move**
7. *Report an incident:* **Report** > **Send the report**
8. *Add a rental:* **Add a rental**, **I sourced this client**, **Add the rental**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A photo did not upload** | Check your signal, then press **Send again**. |
| **The renter does not match** | Do not hand over. Press Stop and call us. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">My jobs</b></td><td>Today and Tomorrow, in order; Vehicle moves</td></tr><tr><td><b class="gd-ui">A job</b></td><td>Open in maps, Acknowledge, Start</td></tr><tr><td><b class="gd-ui">Report</b></td><td>Damage, warning light, collision, ticket, lost property</td></tr><tr><td><b class="gd-ui">Add a rental</b></td><td>A renter you found: a payment link or the saved card</td></tr><tr><td><b class="gd-ui">My sales</b></td><td>Your rentals and commissions</td></tr><tr><td><b class="gd-ui">Referrals</b></td><td>Your link and QR code</td></tr><tr><td><b class="gd-ui">Profile</b></td><td>Phone, two-step sign-in, password, Sign out</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Start a job:</em> <b class="gd-ui">Open the job</b>, <b class="gd-ui">Acknowledge</b>, <b class="gd-ui">Start</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Hand over a car:</em> Every step, then <b class="gd-ui">Hand over the keys</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Stop a handover:</em> <b class="gd-ui">Stop: do not release the car</b>, call us</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>Take a car back:</em> Every step, then <b class="gd-ui">Complete the return</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Shoot listing photos:</em> <b class="gd-ui">Take photo</b>, then <b class="gd-ui">Submit for listing</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Move a car:</em> <b class="gd-ui">Start a move</b>, then <b class="gd-ui">End the move</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Report an incident:</em> <b class="gd-ui">Report</b> &gt; <b class="gd-ui">Send the report</b></div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><em>Add a rental:</em> <b class="gd-ui">Add a rental</b>, <b class="gd-ui">I sourced this client</b>, <b class="gd-ui">Add the rental</b></div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">A photo did not upload</b></td><td>Check your signal, then press <b class="gd-ui">Send again</b>.</td></tr><tr><td><b class="gd-ui">The renter does not match</b></td><td>Do not hand over. Press Stop and call us.</td></tr></tbody></table></div>');
-- GUIDES 0058 END
