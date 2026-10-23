-- 0112: a price typed by hand says whether it is "plus tax" or "tax included" (the owner, October 23, 2026: "include a
-- thing on custom rentals where it says 'tax included' or 'plus tax'").
--   * Every place staff type the rental charge (Add a rental, a quote, the review screen before an offer) also takes
--     price_tax: 'plus' (the default, as before: HST is added on top) or 'included' (the typed amount already holds HST).
--   * Tax included: the rental charge kept on the booking is the amount before tax, backed out of the typed amount
--     (app.price_before_tax: typed x 10000 / (10000 + HST bps), rounded to the cent), and the HST of the rental charge
--     line is what is left (typed - before tax), so the renter pays exactly the amount typed for it and the HST stays
--     recorded on its own. Commissions, owner revenue and discounts keep working on the amount before tax.
--   * The rental charge line names the choice: "Rental charge (plus tax)" or "Rental charge ($100.00 tax included)" (the
--     fee type's own words about the rates are left out of that name, as the portal leaves them out of its lines). The
--     offer page, the booking page, the emails (their text version too), receipts and statements print the line's name,
--     so the label is next to the price everywhere. Admin shows it beside the price typed by hand.
--   * Existing bookings are unchanged: price_tax stays empty on them and their lines are not touched.
-- No applied migration is edited.

-- A function patched in place: the text must be found, or the migration stops.
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0112: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the booking keeps the choice
alter table bookings
  add column if not exists price_tax text,
  add column if not exists price_with_tax_cents bigint;
alter table bookings drop constraint if exists bookings_price_tax_check;
alter table bookings add constraint bookings_price_tax_check check (price_tax in ('plus', 'included'));
alter table bookings drop constraint if exists bookings_price_with_tax_check;
alter table bookings add constraint bookings_price_with_tax_check
  check (coalesce(price_tax = 'included', false) = (price_with_tax_cents is not null) and coalesce(price_with_tax_cents, 0) >= 0);
comment on column bookings.price_tax is 'A price typed by hand (0112): plus (HST added on top of the rental charge) or included (the amount typed holds HST). Empty: the rate sheet, or a price typed before 0112 (plus tax)';
comment on column bookings.price_with_tax_cents is 'Tax included (0112): the amount typed, HST included. rental_charge_cents holds the amount before tax and the rental charge line''s HST is the difference';

drop trigger if exists bookings_guard_price_tax_columns on bookings;
create trigger bookings_guard_price_tax_columns before update on bookings
  for each row execute function app.guard_admin_columns('price_tax', 'price_with_tax_cents');

-- ================================================================ 2. the arithmetic
-- The amount before tax inside an amount that includes HST, rounded to the cent (half away from zero).
create or replace function app.price_before_tax(p_with_tax_cents bigint, p_hst_bps integer) returns bigint
language sql immutable set search_path = public, app as $$
  select round(p_with_tax_cents::numeric * 10000 / (10000 + greatest(coalesce(p_hst_bps, 0), 0)))::bigint
$$;

-- A typed price split for display: {tax, before_tax_cents, hst_cents, with_tax_cents}. Plus tax: HST on top, as every
-- line (public.calc_hst). Tax included: the amount before tax backed out, the HST what is left.
create or replace function app.price_tax_split(p_cents bigint, p_tax text, p_hst_bps integer) returns jsonb
language sql immutable set search_path = public, app as $$
  select case when p_cents is null then null
              when p_tax = 'included' then jsonb_build_object('tax', 'included', 'before_tax_cents', app.price_before_tax(p_cents, p_hst_bps),
                     'hst_cents', p_cents - app.price_before_tax(p_cents, p_hst_bps), 'with_tax_cents', p_cents)
              else jsonb_build_object('tax', 'plus', 'before_tax_cents', p_cents, 'hst_cents', public.calc_hst(p_cents, coalesce(p_hst_bps, 0)),
                     'with_tax_cents', p_cents + public.calc_hst(p_cents, coalesce(p_hst_bps, 0))) end
$$;

-- The words next to the rental charge: "plus tax" or "$100.00 tax included".
create or replace function app.price_tax_label(p_tax text, p_with_tax_cents bigint) returns text
language sql stable set search_path = public, app as $$
  select case p_tax when 'plus' then 'plus tax' when 'included' then app.fmt_money(p_with_tax_cents) || ' tax included' end
$$;

-- The choice in a call's payload (price_tax): plus by default; anything else is refused.
create or replace function app.price_tax_choice(p jsonb) returns text
language plpgsql immutable set search_path = public, app as $$
declare
  v text := coalesce(nullif(btrim(coalesce(p ->> 'price_tax', '')), ''), 'plus');
begin
  if v not in ('plus', 'included') then raise exception 'Say whether the price is plus tax or tax included' using errcode = '22023'; end if;
  return v;
end $$;

-- ================================================================ 3. the price lines
-- the spec carries the choice while the booking keeps its rental charge (same dates, nothing recomputed); the amount
-- with tax only while it still matches the rental charge kept
select pg_temp.patch_fn('app.booking_price_spec(uuid,jsonb)'::regprocedure,
  $o$    'coverage_option', b.coverage_option, 'fee_terms', v_terms);$o$,
  $n$    'coverage_option', b.coverage_option, 'fee_terms', v_terms,
    -- 0112: plus tax or tax included, on a price typed by hand the booking keeps
    'price_tax', case when (p_changes ->> 'rental_charge_cents') is null and not coalesce((p_changes ->> 'recompute_rental')::boolean, false)
                           and v_pickup = b.pickup_at and v_return = b.return_at then b.price_tax end,
    'rental_charge_with_tax_cents', case when (p_changes ->> 'rental_charge_cents') is null and not coalesce((p_changes ->> 'recompute_rental')::boolean, false)
                           and v_pickup = b.pickup_at and v_return = b.return_at and b.price_tax = 'included'
                           and b.rental_charge_cents = app.price_before_tax(b.price_with_tax_cents, b.hst_bps) then b.price_with_tax_cents end);$n$);

-- the rental charge line names the choice; tax included: its HST is the amount typed less the amount before tax
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$                         'daily_days', r.daily_days, 'weekend_days', r.weekend_days));
  end if;$o$,
  $n$                         'daily_days', r.daily_days, 'weekend_days', r.weekend_days));
    -- 0112: a price typed by hand says plus tax or tax included
    if (p ->> 'price_tax') in ('plus', 'included') and ((p ->> 'price_tax') = 'plus' or (p ->> 'rental_charge_with_tax_cents') is not null) then
      v_lines := jsonb_set(v_lines, array[(jsonb_array_length(v_lines) - 1)::text], (v_lines -> -1) || jsonb_build_object(
        'description', regexp_replace(coalesce(v_lines -> -1 ->> 'label', 'Rental charge'), '\s*\((daily|the daily)[^)]*\)$', '') || ' (' || app.price_tax_label(p ->> 'price_tax', (p ->> 'rental_charge_with_tax_cents')::bigint) || ')',
        'price_tax', p ->> 'price_tax'));
    end if;
    if (p ->> 'price_tax') = 'included' and (p ->> 'rental_charge_with_tax_cents') is not null and coalesce((v_lines -> -1 ->> 'hst_applies')::boolean, false) then
      v_lines := jsonb_set(v_lines, array[(jsonb_array_length(v_lines) - 1)::text, 'hst_cents'], to_jsonb((p ->> 'rental_charge_with_tax_cents')::bigint - v_rental));
    end if;
  end if;$n$);

-- the rental charge line's name follows the choice (only when a label comes or goes: other names are left as they are)
select pg_temp.patch_fn('app.put_price_line(uuid,jsonb)'::regprocedure,
  $o$     or (v_ba is not null and v_line.description is distinct from p_line ->> 'description') then$o$,
  $n$     or (v_ba is not null and v_line.description is distinct from p_line ->> 'description')
     or (v_line.charge_type = 'rental_charge' and v_line.description is distinct from p_line ->> 'description'
         and (p_line ? 'price_tax' or v_line.description ~ ' \((plus tax|\$[0-9,.]+ tax included)\)$')) then$n$);
select pg_temp.patch_fn('app.put_price_line(uuid,jsonb)'::regprocedure,
  $o$           description = case when v_ba is not null then p_line ->> 'description' else description end$o$,
  $n$           description = case when v_ba is not null then p_line ->> 'description'
                              when charge_type = 'rental_charge' and (p_line ? 'price_tax' or description ~ ' \((plus tax|\$[0-9,.]+ tax included)\)$')
                                then p_line ->> 'description' else description end$n$);

-- ================================================================ 4. recording a price typed by hand
-- p_with_tax: the amount typed, tax included (the rental charge becomes the amount before tax). Without it the price is
-- plus tax, except on Add a rental (p_set false), where the booking was created with its choice already.
drop function app.record_custom_price(uuid, uuid, bigint, bigint, text, boolean);
create function app.record_custom_price(p_booking uuid, p_by uuid, p_cents bigint, p_rate_sheet bigint, p_reason text, p_set boolean default false,
                                        p_with_tax bigint default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_flags text[];
  v_tax text;
  v_with bigint := p_with_tax;
  v_cents bigint := p_cents;
begin
  select * into b from bookings where id = p_booking for update;
  if v_with is not null then
    if v_with < 0 then raise exception 'Enter the price as an amount' using errcode = '22023'; end if;
    v_cents := app.price_before_tax(v_with, b.hst_bps);
    v_tax := 'included';
  elsif not p_set and b.price_tax = 'included' then
    v_with := b.price_with_tax_cents;
    v_tax := 'included';
  else
    v_tax := 'plus';
  end if;
  if v_cents is null or v_cents < 0 then raise exception 'Enter the price as an amount' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for the price' using errcode = '22023'; end if;
  if p_set then
    update bookings set rental_charge_cents = v_cents,
           discount_cents = case when booking_type = 'non_refundable' then public.calc_bps(v_cents, (app.settings(app.local_date(b.booked_at))).non_refundable_discount_bps) else 0 end
     where id = p_booking;
  end if;
  if p_rate_sheet is not null and v_cents = p_rate_sheet and v_tax = 'plus' then
    update bookings set rate_sheet_rental_cents = null, custom_price_reason = null, custom_price_by = null, custom_price_at = null, price_flags = '{}',
           price_reviewed_at = null, price_reviewed_by = null, price_review_note = null, price_tax = null, price_with_tax_cents = null where id = p_booking;
  else
    v_flags := app.custom_price_flags(v_cents, p_rate_sheet, b.billable_days);
    update bookings set rate_sheet_rental_cents = p_rate_sheet, custom_price_reason = btrim(p_reason), custom_price_by = p_by, custom_price_at = now(),
           price_flags = v_flags, price_reviewed_at = null, price_reviewed_by = null, price_review_note = null,
           price_tax = v_tax, price_with_tax_cents = case when v_tax = 'included' then v_with end
     where id = p_booking;
    perform app.log_booking_event(p_booking, 'custom_price', null, b.status::text, null,
      format('Price typed by hand: %s (rate sheet %s). %s',
             case when v_tax = 'included' then format('%s tax included (%s before tax, HST %s)', app.fmt_money(v_with), app.fmt_money(v_cents), app.fmt_money(v_with - v_cents))
                  else app.fmt_money(v_cents) || ' plus tax' end,
             coalesce(app.fmt_money(p_rate_sheet), 'none'), btrim(p_reason)), p_by, 'staff',
      jsonb_build_object('cents', v_cents, 'rate_sheet_cents', p_rate_sheet, 'reason', btrim(p_reason), 'flags', to_jsonb(v_flags),
                         'price_tax', v_tax, 'with_tax_cents', case when v_tax = 'included' then v_with end));
  end if;
  -- the price lines: a price set now, or a label that came or went
  if p_set or (select x.price_tax from bookings x where x.id = p_booking) is distinct from b.price_tax then
    perform app.sync_booking_price(p_booking);
  end if;
end $$;
revoke all on function app.record_custom_price(uuid, uuid, bigint, bigint, text, boolean, bigint) from public, anon, authenticated;
grant execute on function app.record_custom_price(uuid, uuid, bigint, bigint, text, boolean, bigint) to service_role;

-- the review screen (and the Admin's booking edit): price_tax travels with rental_charge_cents
select pg_temp.patch_fn('app.adjust_booking(uuid,uuid,jsonb,text)'::regprocedure,
  $o$  v_changes jsonb := coalesce(p_changes, '{}'::jsonb) - 'price_reason';$o$,
  $n$  v_changes jsonb := coalesce(p_changes, '{}'::jsonb) - 'price_reason' - 'price_tax';
  v_tax text := app.price_tax_choice(p_changes);$n$);
select pg_temp.patch_fn('app.adjust_booking(uuid,uuid,jsonb,text)'::regprocedure,
  $o$    perform app.record_custom_price(p_booking, p_by, v_custom, b.rental_charge_cents, coalesce(v_reason, p_note, 'Set by an Admin'), true);$o$,
  $n$    perform app.record_custom_price(p_booking, p_by, v_custom, b.rental_charge_cents, coalesce(v_reason, p_note, 'Set by an Admin'), true,
                                    case when v_tax = 'included' then v_custom end);$n$);
select pg_temp.patch_fn('app.adjust_booking(uuid,uuid,jsonb,text)'::regprocedure,
  $o$      update bookings set rate_sheet_rental_cents = null, custom_price_reason = null, custom_price_by = null, custom_price_at = null, price_flags = '{}',
             price_reviewed_at = null, price_reviewed_by = null, price_review_note = null where id = p_booking;$o$,
  $n$      update bookings set rate_sheet_rental_cents = null, custom_price_reason = null, custom_price_by = null, custom_price_at = null, price_flags = '{}',
             price_reviewed_at = null, price_reviewed_by = null, price_review_note = null, price_tax = null, price_with_tax_cents = null where id = p_booking;
      if b0.price_tax is not null then perform app.sync_booking_price(p_booking); end if;$n$);

-- an assistant may send the choice with the price
select pg_temp.patch_fn('app.va_guard_booking_edit(text,jsonb)'::regprocedure,
  $o$                 'rental_charge_cents', 'price_reason') then$o$,
  $n$                 'rental_charge_cents', 'price_reason', 'price_tax') then$n$);

-- a quote
select pg_temp.patch_fn('app.staff_quote_create(uuid,jsonb)'::regprocedure,
  $o$  v_out := app.staff_quote_request(p_by, p - 'sales_choice' - 'rental_charge_cents' - 'price_reason');$o$,
  $n$  v_out := app.staff_quote_request(p_by, p - 'sales_choice' - 'rental_charge_cents' - 'price_reason' - 'price_tax');$n$);
select pg_temp.patch_fn('app.staff_quote_create(uuid,jsonb)'::regprocedure,
  $o$    perform app.record_custom_price(b.id, p_by, v_cents, b.rental_charge_cents, p ->> 'price_reason', true);$o$,
  $n$    perform app.record_custom_price(b.id, p_by, v_cents, b.rental_charge_cents, p ->> 'price_reason', true,
                                    case when app.price_tax_choice(p) = 'included' then v_cents end);$n$);

-- ================================================================ 5. Add a rental
-- The choice travels with the transaction (app.price_tax, app.price_with_tax) to the booking's insert, so the booking is
-- priced right from its first line (the payment taken in the same call is for the right amount).
create or replace function app.bookings_price_tax_from_call() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_tax text := nullif(current_setting('app.price_tax', true), '');
  v_with bigint := nullif(current_setting('app.price_with_tax', true), '')::bigint;
begin
  if v_tax = 'plus' then
    new.price_tax := 'plus';
    new.price_with_tax_cents := null;
  elsif v_tax = 'included' and v_with is not null then
    if new.rental_charge_cents is distinct from app.price_before_tax(v_with, new.hst_bps) then
      raise exception 'The price before tax does not match the price typed (tax included)' using errcode = '23514';
    end if;
    new.price_tax := 'included';
    new.price_with_tax_cents := v_with;
  end if;
  return new;
end $$;
drop trigger if exists bookings_price_tax_from_call on bookings;
create trigger bookings_price_tax_from_call before insert on bookings
  for each row execute function app.bookings_price_tax_from_call();

alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre0112;
create function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_typed bigint := nullif(p ->> 'rental_charge_cents', '')::bigint;
  v_tax text := app.price_tax_choice(p);
  v_out jsonb;
begin
  if v_typed is null then return app.manual_rental_create_pre0112(p_by, p - 'price_tax'); end if;
  perform set_config('app.price_tax', v_tax, true);
  if v_tax = 'included' then
    perform set_config('app.price_with_tax', v_typed::text, true);
    p := jsonb_set(p, '{rental_charge_cents}', to_jsonb(app.price_before_tax(v_typed, (app.settings()).hst_bps)));
  end if;
  v_out := app.manual_rental_create_pre0112(p_by, p - 'price_tax');
  perform set_config('app.price_tax', '', true);
  perform set_config('app.price_with_tax', '', true);
  return v_out || (select jsonb_build_object('price_tax', b.price_tax, 'price_with_tax_cents', b.price_with_tax_cents, 'rental_charge_cents', b.rental_charge_cents)
                     from bookings b where b.id = (v_out ->> 'booking_id')::uuid);
end $$;

-- the check before adding: a price typed tax included is priced on its amount before tax, and the split is returned
alter function app.manual_rental_quote(uuid, jsonb) rename to manual_rental_quote_pre0112;
create function app.manual_rental_quote(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_typed bigint := nullif(p ->> 'rental_charge_cents', '')::bigint;
  v_tax text := app.price_tax_choice(p);
  v_hst integer := (app.settings()).hst_bps;
begin
  if v_typed is not null and v_tax = 'included' then
    p := jsonb_set(p, '{rental_charge_cents}', to_jsonb(app.price_before_tax(v_typed, v_hst)));
  end if;
  return app.manual_rental_quote_pre0112(p_by, p - 'price_tax') || jsonb_build_object('price_tax', app.price_tax_split(v_typed, v_tax, v_hst));
end $$;

do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('manual_rental_create_pre0112', 'manual_rental_create'), ('manual_rental_quote_pre0112', 'manual_rental_quote')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
revoke all on function app.price_before_tax(bigint, integer), app.price_tax_split(bigint, text, integer), app.price_tax_label(text, bigint),
                       app.price_tax_choice(jsonb), app.bookings_price_tax_from_call() from public, anon, authenticated;
grant execute on function app.price_before_tax(bigint, integer), app.price_tax_split(bigint, text, integer), app.price_tax_label(text, bigint),
                          app.price_tax_choice(jsonb), app.bookings_price_tax_from_call() to service_role;

-- ================================================================ 6. Admin: the choice beside the price typed by hand
select pg_temp.patch_fn('app.booking_sales_credit(uuid,jsonb)'::regprocedure,
  $o$'review_note', b.price_review_note) end,$o$,
  $n$'review_note', b.price_review_note,
               'tax', coalesce(b.price_tax, 'plus'), 'with_tax_cents', b.price_with_tax_cents) end,$n$);
select pg_temp.patch_fn('app.commission_reviews(uuid)'::regprocedure,
  $o$                   'reviewed_at', b.price_reviewed_at) order by b.custom_price_at desc)$o$,
  $n$                   'reviewed_at', b.price_reviewed_at, 'tax', coalesce(b.price_tax, 'plus'), 'with_tax_cents', b.price_with_tax_cents) order by b.custom_price_at desc)$n$);
