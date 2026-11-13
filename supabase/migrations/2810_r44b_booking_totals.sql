-- 2810 (release 44, part B): a booking's total follows its lines, and the money it shows is real money only.
--   1. Change amount on a rental line (Money tab, app.line_adjust of 1063) changed the line but not the booking: a
--      hand-set booking's rental line lowered from $1,284.58 to $1,275.00 left "Total at booking" at $1,490.00, and the
--      fees part (the total less the rental, app.booking_part_open) grew by the difference with its HST, a $10.83
--      "rental due" that nobody owed. Now every change of a line at booking moves the booking's subtotal, HST and total
--      (and the renter's share, the rental charge and a tax-included price) by exactly the change of the line.
--   2. An Admin sets a hand-set total cleanly: booking_total_set {booking, total_cents, reason} puts the difference on the
--      rental charge line (tax included: the line's HST is backed out of it, as a price typed "tax included" is, 0112),
--      then the totals follow, so "Total at booking" is the amount typed and nothing is left open by itself.
--   3. Data Health, Finance: bookings whose deposit says it was charged or taken while no deposit money is recorded
--      (a payment that failed, was voided or never made), the "Charged $1,000" on a cancelled booking with $0 paid.
-- No applied migration is edited: functions are wrapped (_pre2810).

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the totals move with a line
-- The booking's figures at booking moved by a line's change (before tax, and its HST): the subtotal, the HST, the total;
-- the rental charge (and a tax-included price) when it is the rental line; the renter's share of a booking the renter
-- pays (an insurer's booking keeps the renter's share, never above the total).
create function app.booking_totals_shift(p_booking uuid, p_amount bigint, p_hst bigint, p_charge_type text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(p_amount, 0) = 0 and coalesce(p_hst, 0) = 0 then return; end if;
  update bookings b
     set subtotal_at_booking_cents = b.subtotal_at_booking_cents + p_amount,
         hst_at_booking_cents = b.hst_at_booking_cents + p_hst,
         total_due_at_booking_cents = b.total_due_at_booking_cents + p_amount + p_hst,
         rental_charge_cents = case when p_charge_type = 'rental_charge' then greatest(b.rental_charge_cents + p_amount, 0) else b.rental_charge_cents end,
         price_with_tax_cents = case when p_charge_type = 'rental_charge' and b.price_tax = 'included' and b.price_with_tax_cents is not null
                                     then greatest(b.price_with_tax_cents + p_amount + p_hst, 0) else b.price_with_tax_cents end
   where b.id = p_booking;
end $$;
comment on function app.booking_totals_shift(uuid, bigint, bigint, text) is 'r44 (2810): a booking''s subtotal, HST and total at booking (and the renter''s share, the rental charge) moved by the change of one of its lines at booking.';

alter function app.line_adjust(uuid, jsonb) rename to line_adjust_pre2810;
create function app.line_adjust(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  li booking_line_items;
  li2 booking_line_items;
  r jsonb;
begin
  select * into li from booking_line_items where id = nullif(p ->> 'line', '')::uuid;
  r := app.line_adjust_pre2810(p_by, p);
  select * into li2 from booking_line_items where id = li.id;
  if li.id is not null and li.stage = 'booking' and li.charged_to_renter and li.voided_at is null then
    perform app.booking_totals_shift(li.booking_id,
      (case when li2.voided_at is null then li2.amount_cents else 0 end) - li.amount_cents,
      (case when li2.voided_at is null then li2.hst_cents else 0 end) - li.hst_cents, li.charge_type);
  end if;
  return r || jsonb_build_object('total_cents', (select b.total_due_at_booking_cents from bookings b where b.id = li.booking_id));
end $$;
select pg_temp.copy_grants('app.line_adjust(uuid, jsonb)'::regprocedure, 'app.line_adjust_pre2810(uuid, jsonb)'::regprocedure);

-- ================================================================ 2. an Admin sets the total
-- p: booking (id or number), total_cents (HST included), reason. The rental charge line takes the difference.
create function app.booking_total_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  li booking_line_items;
  v_total bigint := nullif(p ->> 'total_cents', '')::bigint;
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_gross bigint;
  v_amount bigint;
  v_hst bigint;
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status::text in ('cancelled', 'declined', 'expired') then
    raise exception 'Booking % is %: its total is not changed', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  if v_total is null or v_total < 0 then raise exception 'Enter the new total, HST included' using errcode = '22023'; end if;
  if length(v_reason) < 5 then raise exception 'Give the reason (at least 5 characters): it is in the booking history' using errcode = '22023'; end if;
  if v_total = b.total_due_at_booking_cents then return jsonb_build_object('ok', true, 'changed', false, 'total_cents', v_total); end if;
  select * into li from booking_line_items l
   where l.booking_id = b.id and l.stage = 'booking' and l.charge_type = 'rental_charge' and l.voided_at is null and l.charged_to_renter
   order by l.amount_cents desc, l.created_at limit 1 for update;
  if li.id is null then raise exception 'This booking has no rental charge line to take the difference: change its lines one by one' using errcode = '23514'; end if;
  if li.statement_id is not null then raise exception 'The rental charge is on an issued statement: credit it on a new statement instead' using errcode = '23514'; end if;
  if li.payment_id is not null then raise exception 'The rental charge is paid: refund the difference instead' using errcode = '23514'; end if;
  v_gross := li.amount_cents + li.hst_cents + (v_total - b.total_due_at_booking_cents);
  if v_gross < 0 then
    raise exception 'The other charges come to more than %: lower or waive them first', app.fmt_money(v_total) using errcode = '22023';
  end if;
  if li.hst_cents <> 0 or coalesce(li.hst_applies, true) then
    v_amount := app.price_before_tax(v_gross, b.hst_bps);
    v_hst := v_gross - v_amount;
  else
    v_amount := v_gross; v_hst := 0;
  end if;
  update booking_line_items set amount_cents = v_amount, hst_cents = v_hst,
         unit_amount_cents = case when coalesce(quantity, 0) > 0 then round(v_amount / quantity) else v_amount end,
         override_by = p_by, override_reason = left('Total set by an Admin: ' || v_reason, 300)
   where id = li.id;
  perform app.booking_totals_shift(b.id, v_amount - li.amount_cents, v_hst - li.hst_cents, 'rental_charge');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'booking_total_set', 'bookings', b.id::text, jsonb_build_object('total_cents', b.total_due_at_booking_cents),
          jsonb_build_object('total_cents', v_total, 'reason', v_reason));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    left(format('Total at booking set from %s to %s: %s', app.fmt_money(b.total_due_at_booking_cents), app.fmt_money(v_total), v_reason), 600),
    p_by, 'staff', jsonb_build_object('line_id', li.id, 'total_cents', v_total));
  return jsonb_build_object('ok', true, 'changed', true, 'total_cents', (select x.total_due_at_booking_cents from bookings x where x.id = b.id));
end $$;
comment on function app.booking_total_set(uuid, jsonb) is 'r44 (2810): an Admin sets a booking''s total at booking (HST included); the rental charge line takes the difference and the totals follow.';

-- ================================================================ 3. Data Health: deposits that say money no record shows
-- A deposit charged or taken in cash or by e-Transfer (not a card hold) is money received; when no deposit payment that
-- went through and no payment received another way for the deposit is on the booking, the deposit's state is wrong.
create function app.deposit_money_mismatch() returns table (booking_id uuid, booking_number text, status text, deposit_cents bigint)
language sql stable security definer set search_path = public, app as $$
  select b.id, b.booking_number, b.status::text, d.amount_cents
    from deposits d join bookings b on b.id = d.booking_id
   where d.status = 'captured' and d.method <> 'card_hold' and d.carried_from_deposit_id is null and d.amount_cents > 0
     and not exists (select 1 from payments x where x.booking_id = b.id and x.purpose = 'deposit' and x.kind in ('charge', 'capture')
                      and x.status in ('succeeded', 'partially_refunded', 'refunded'))
     and not exists (select 1 from manual_payments m where m.booking_id = b.id and m.covers = 'deposit' and m.voided_at is null)
$$;

alter function app.data_health(timestamptz) rename to data_health_pre2810;
create function app.data_health(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.data_health_pre2810(p_now);
  x jsonb;
  c jsonb;
begin
  select coalesce(jsonb_agg(app.dh_item(m.booking_id, format('%s (%s): the deposit says %s was charged, but no deposit payment is recorded',
                                        m.booking_number, replace(m.status, '_', ' '), app.fmt_money(m.deposit_cents)),
                                        '/admin/bookings/' || m.booking_number || '?tab=money') order by m.booking_number), '[]'::jsonb) into x
    from app.deposit_money_mismatch() m;
  c := app.dh_check('deposit_without_money', 'Deposit without money',
                    'Bookings whose deposit reads as charged while no deposit payment is recorded: check the payments, then correct the deposit', x, '/admin/bookings');
  return jsonb_set(jsonb_set(r, '{checks}', (r -> 'checks') || c), '{issues}', to_jsonb((r ->> 'issues')::integer + (c ->> 'count')::integer));
end $$;
select pg_temp.copy_grants('app.data_health(timestamptz)'::regprocedure, 'app.data_health_pre2810(timestamptz)'::regprocedure);

alter function app.data_health_keys(text) rename to data_health_keys_pre2810;
create function app.data_health_keys(p_fn text) returns text[]
language sql immutable as $$
  select case when p_fn = 'finance' then app.data_health_keys_pre2810(p_fn) || array['deposit_without_money'] else app.data_health_keys_pre2810(p_fn) end
$$;
select pg_temp.copy_grants('app.data_health_keys(text)'::regprocedure, 'app.data_health_keys_pre2810(text)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['booking_totals_shift', 'line_adjust_pre2810', 'booking_total_set', 'deposit_money_mismatch',
                    'data_health_pre2810', 'data_health_keys_pre2810'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
