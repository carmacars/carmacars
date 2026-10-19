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
     or (p_call = 'admin_do' and p_name in ('commission_approve', 'commission_reverse', 'commission_payout', 'commission_rate_set', 'price_review', 'sales_claim_decide')) then
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
              'staff_commission_rate_set', 'job_commission_month', 'booking_staff_commission_cents', 'compute_booking_split', 'owner_statement_lines_commission',
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
