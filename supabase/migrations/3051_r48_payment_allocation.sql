-- 3051 (release 48, part 2): a payment covers every line up to the total; a deposit change reaches every deposit record;
-- a voided payment resets what it paid (docs/changes/2026-11-15-r48-money-fixes.md).
--
-- 1. Found live on CC-10478: a payment of the whole total ($186.73, HST included) recorded for "the rental" paid the
--    rental and short-notice lines only. The young driver fee and the Protection Plan (the fees part) stayed open, so the
--    booking showed $115.26 open, stayed waiting for payment and blocked the pickup. Now:
--      a. app.booking_part_open_raw: what is paid past one part (the rental or the fees) pays the other one, so a payment
--         covers every line up to the total, whichever part it was recorded against;
--      b. app.record_booking_payment: after a payment of the rental, the fees or both, every line of a part that is now
--         paid in full is tied to it, and a booking waiting for payment with nothing open is confirmed;
--      c. the bookings already stuck that way are repaired: their lines tied, and confirmed when waiting for payment.
-- 2. Changing a booking's deposit (Edit booking, the connector's change_booking: $300 to $600) left the deposit not taken
--    yet, the deposit owed at pickup and the open deposit links at $300, so the Money tab said "Collect $300 deposit".
--    A trigger on bookings.deposit_cents moves every record that is not taken yet (an open deposit link of the old
--    amount is already replaced by a new one, 0213).
-- 3. Voiding a deposit recorded by hand left the deposit "collected" in the database: the Money tab said Not collected,
--    the header still said "Deposit collected $300", record_payment refused ("already been taken") and Record the
--    deposit did nothing. A void now gives back the deposit record its state (not taken, or what is left of it), and a
--    void of a rental payment unties the lines it paid.
-- No applied migration is edited.
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

-- ================================================================ 1a. what is open of each part, the parts spilling into each other
create or replace function app.booking_part_open_raw(p_booking uuid, p_covers text) returns bigint
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_due bigint;
  v_rental bigint;
  v_due_r bigint;
  v_due_f bigint;
  v_paid_r bigint;
  v_paid_f bigint;
  v_whole bigint := 0;
  v_legacy bigint := 0;
  v_rest bigint;
begin
  select * into b from bookings where id = p_booking;
  if p_covers = 'later' then
    select coalesce(sum(l.amount_cents + l.hst_cents), 0) into v_due from booking_line_items l
     where l.booking_id = p_booking and l.stage <> 'booking' and l.statement_id is not null and l.payment_id is null and l.voided_at is null and l.charged_to_renter;
    return greatest(v_due - coalesce((select sum(m.amount_cents) from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers = 'later'
                                        and not exists (select 1 from booking_line_items l2 where l2.payment_id = m.payment_id)), 0), 0);
  end if;
  if p_covers not in ('rental', 'fees') then return 0; end if;
  select coalesce(sum(l.amount_cents + l.hst_cents), 0) into v_rental from booking_line_items l
   where l.booking_id = p_booking and l.stage = 'booking' and l.voided_at is null and l.charged_to_renter
     and l.charge_type in ('rental_charge', 'lead_time', 'price_limit', 'occasion_discount', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'discount');
  if b.bill_to <> 'renter' and b.renter_due_at_booking_cents is not null then
    v_rental := least(v_rental, b.renter_due_at_booking_cents);
  end if;
  v_due_r := v_rental;
  v_due_f := greatest(coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents) - v_rental, 0);
  v_paid_r := coalesce((select sum(m.amount_cents) from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers = 'rental'), 0)
              + app.card_part_paid(p_booking, 'rental');
  v_paid_f := coalesce((select sum(m.amount_cents) from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers = 'fees'), 0)
              + app.card_part_paid(p_booking, 'fees');
  -- a card payment of the whole booking (the website's) pays both parts, the rental first
  v_whole := (select coalesce(sum(x.amount_cents), 0) from payments x where x.booking_id = p_booking and x.purpose = 'booking_total' and x.method = 'card' and x.kind in ('charge', 'capture')
                  and x.status = 'succeeded' and not exists (select 1 from payment_requests q where q.payment_id = x.id))
            - (select coalesce(sum(r.amount_cents), 0) from payments r join payments x on x.id = r.parent_payment_id where r.booking_id = p_booking and r.kind = 'refund' and r.status = 'succeeded'
                  and x.purpose = 'booking_total' and x.method = 'card' and not exists (select 1 from payment_requests q where q.payment_id = x.id));
  v_whole := greatest(v_whole, 0);
  v_paid_r := v_paid_r + least(v_whole, v_rental);
  v_paid_f := v_paid_f + greatest(v_whole - v_rental, 0);
  v_rest := greatest(v_rental - v_whole, 0);
  -- a payment of the whole booking recorded before 0129 (no part named): the rental first
  v_legacy := coalesce((select sum(m.amount_cents) from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers is null), 0);
  v_paid_r := v_paid_r + least(v_legacy, v_rest);
  v_paid_f := v_paid_f + greatest(v_legacy - v_rest, 0);
  -- 3051: what is paid past one part pays the other (a whole payment recorded for "the rental" pays the fees too)
  if p_covers = 'rental' then
    return greatest(v_due_r - v_paid_r - greatest(v_paid_f - v_due_f, 0), 0);
  end if;
  return greatest(v_due_f - v_paid_f - greatest(v_paid_r - v_due_r, 0), 0);
end $$;

-- ================================================================ 1b. tie every paid line, confirm when nothing is open
alter function app.record_booking_payment(uuid, jsonb) rename to record_booking_payment_pre3051;
create function app.record_booking_payment(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_covers text := coalesce(nullif(p ->> 'covers', ''), 'rental');
  v_inner boolean := coalesce(current_setting('app.payment_parts', true), '') <> '';
  r jsonb;
  b bookings;
  v_pay uuid;
  v_conf jsonb;
begin
  r := app.record_booking_payment_pre3051(p_by, p);
  if v_inner or v_covers not in ('rental', 'fees', 'both') or coalesce((r ->> 'repeat')::boolean, false) then return r; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1;
  if b.id is null then return r; end if;
  v_pay := coalesce(nullif(r ->> 'payment_id', '')::uuid, (select m.payment_id from manual_payments m where m.booking_id = b.id and m.voided_at is null
                                                                and m.covers in ('rental', 'fees') order by m.recorded_at desc limit 1));
  if v_pay is not null then
    perform app.booking_tie_lines_raw(b.id, 'rental', v_pay);
    perform app.booking_tie_lines_raw(b.id, 'fees', v_pay);
  end if;
  if b.status = 'pending_payment' and not coalesce((r ->> 'confirmed')::boolean, false)
     and app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees') = 0 then
    v_conf := app.confirm_offline_booking(p_by, b.id, false);
    r := r || jsonb_build_object('confirmed', coalesce((v_conf ->> 'ok')::boolean, false), 'confirm', v_conf);
  end if;
  return r || jsonb_build_object('open_cents', app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees'));
end $$;
select pg_temp.copy_grants('app.record_booking_payment(uuid, jsonb)'::regprocedure, 'app.record_booking_payment_pre3051(uuid, jsonb)'::regprocedure);
comment on function app.record_booking_payment(uuid, jsonb) is '3051: a payment covers every line up to the total (the parts spill into each other); a booking waiting for payment with nothing open is confirmed.';

-- ================================================================ 1c. the bookings already stuck that way
create or replace function app.repair_payment_allocation(p_booking uuid default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  x record;
  v_pay uuid;
  v_n integer := 0;
begin
  for x in
    select b.id, b.status from bookings b
     where (p_booking is null or b.id = p_booking)
       and b.status::text in ('pending_payment', 'confirmed', 'on_rent', 'returned', 'closed')
       and exists (select 1 from manual_payments m where m.booking_id = b.id and m.voided_at is null and m.covers in ('rental', 'fees'))
       and exists (select 1 from booking_line_items l where l.booking_id = b.id and l.stage = 'booking' and l.voided_at is null and l.charged_to_renter and l.payment_id is null)
  loop
    if app.booking_part_open(x.id, 'rental') + app.booking_part_open(x.id, 'fees') > 0 then continue; end if;
    select m.payment_id into v_pay from manual_payments m where m.booking_id = x.id and m.voided_at is null and m.covers in ('rental', 'fees') order by m.recorded_at desc limit 1;
    perform app.booking_tie_lines_raw(x.id, 'rental', v_pay);
    perform app.booking_tie_lines_raw(x.id, 'fees', v_pay);
    if x.status = 'pending_payment' then
      perform set_config('app.confirm_paid', x.id::text, true);
      perform app.confirm_offline_booking(null, x.id, false);
      perform set_config('app.confirm_paid', '', true);
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function app.repair_payment_allocation(uuid) from public, anon, authenticated;
grant execute on function app.repair_payment_allocation(uuid) to service_role;
select app.repair_payment_allocation();

-- ================================================================ 2. a deposit change reaches every record not taken yet
create or replace function app.booking_deposit_follow() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.deposit_cents is not distinct from old.deposit_cents then return new; end if;
  update deposits set amount_cents = greatest(new.deposit_cents, 0)
   where booking_id = new.id and status in ('pending', 'failed') and amount_cents is distinct from greatest(new.deposit_cents, 0);
  update deposit_pendings set amount_cents = greatest(new.deposit_cents, 0)
   where booking_id = new.id and cleared_at is null and amount_cents is distinct from greatest(new.deposit_cents, 0);
  -- an open deposit link of the old amount is replaced by a new one for the new amount (0213, app.deposit_link_needed)
  return new;
end $$;
revoke all on function app.booking_deposit_follow() from public, anon, authenticated;
grant execute on function app.booking_deposit_follow() to service_role;
drop trigger if exists bookings_deposit_follow on bookings;
create trigger bookings_deposit_follow after update of deposit_cents on bookings for each row execute function app.booking_deposit_follow();

-- ================================================================ 3. a void resets what the payment paid
alter table deposit_events drop constraint if exists deposit_events_kind_check;
alter table deposit_events add constraint deposit_events_kind_check
  check (kind in ('taken', 'hold_renewed', 'captured', 'applied', 'held_back', 'released', 'carried_over', 'failed', 'voided'));

alter function app.void_manual_payment(uuid, uuid, text) rename to void_manual_payment_pre3051;
create function app.void_manual_payment(p_by uuid, p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  m manual_payments;
  d deposits;
  b bookings;
  v_left bigint;
  v_last manual_payments;
  r jsonb;
begin
  select * into m from manual_payments where id = p_id;
  r := app.void_manual_payment_pre3051(p_by, p_id, p_reason);
  if m.booking_id is null then return r; end if;
  select * into b from bookings where id = m.booking_id;
  if m.covers = 'deposit' then
    select * into d from deposits where booking_id = m.booking_id for update;
    if d.id is not null and d.method = 'offline' and d.status = 'captured' then
      v_left := coalesce((select sum(x.amount_cents) from manual_payments x where x.booking_id = m.booking_id and x.covers = 'deposit' and x.voided_at is null), 0);
      if v_left <= 0 then
        update deposits set status = 'pending', method = 'card_hold', paid_method = null, amount_cents = greatest(b.deposit_cents, 0), captured_cents = 0,
               hold_payment_id = null, taken_at = null, hold_expires_at = null where id = d.id;
      else
        select * into v_last from manual_payments x where x.booking_id = m.booking_id and x.covers = 'deposit' and x.voided_at is null order by x.recorded_at desc limit 1;
        update deposits set amount_cents = v_left, captured_cents = v_left, paid_method = v_last.method, hold_payment_id = v_last.payment_id where id = d.id;
      end if;
      insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by)
      values (d.id, 'voided', m.amount_cents, m.payment_id, left('Voided: ' || btrim(p_reason), 500), p_by);
      perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
        format('Deposit of %s by %s voided: %s%s', app.fmt_money(m.amount_cents), app.payment_method_label(m.method), btrim(p_reason),
               case when v_left > 0 then format('. %s of the deposit stays taken', app.fmt_money(v_left)) else '. The deposit is not taken' end), p_by, 'staff',
        jsonb_build_object('payment_id', m.payment_id, 'covers', 'deposit', 'voided', true));
    end if;
  elsif m.covers in ('rental', 'fees') then
    -- the lines it paid are open again; a payment that is still recorded ties them back when its part is paid in full
    update booking_line_items set payment_id = null where booking_id = m.booking_id and payment_id = m.payment_id and stage = 'booking';
    perform app.booking_tie_lines_raw(m.booking_id, 'rental', (select x.payment_id from manual_payments x where x.booking_id = m.booking_id and x.voided_at is null and x.covers in ('rental', 'fees') order by x.recorded_at desc limit 1));
    perform app.booking_tie_lines_raw(m.booking_id, 'fees', (select x.payment_id from manual_payments x where x.booking_id = m.booking_id and x.voided_at is null and x.covers in ('rental', 'fees') order by x.recorded_at desc limit 1));
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.void_manual_payment(uuid, uuid, text)'::regprocedure, 'app.void_manual_payment_pre3051(uuid, uuid, text)'::regprocedure);

-- the deposits already left "collected" by a void before this release
update deposits d set status = 'pending', method = 'card_hold', paid_method = null, amount_cents = greatest(b.deposit_cents, 0), captured_cents = 0,
       hold_payment_id = null, taken_at = null, hold_expires_at = null
  from bookings b
 where b.id = d.booking_id and d.method = 'offline' and d.status = 'captured' and d.released_cents = 0 and d.applied_cents = 0 and d.held_back_cents = 0
   and not exists (select 1 from manual_payments x where x.booking_id = d.booking_id and x.covers = 'deposit' and x.voided_at is null)
   and exists (select 1 from manual_payments x where x.booking_id = d.booking_id and x.covers = 'deposit' and x.voided_at is not null);
