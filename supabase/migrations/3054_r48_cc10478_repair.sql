-- 3054 (release 48, part 2): the money of CC-10478 put right (docs/changes/2026-11-15-r48-money-fixes.md). Runs once and
-- again without change (each step checks what is there first); does nothing on a database without that booking.
--
-- The renter sent one e-Transfer of $800.00 (reference C1AqmwK7G9Hu, received November 15, 2026): $186.73 for the
-- booking, $600.00 for the deposit (twice the car's $300 deposit: an e-Transfer deposit, 3052) and $13.27 as a tip.
-- Recorded: the $186.73 for "the rental" (so the young driver fee and the Protection Plan stayed open: 3051 fixes how a
-- payment is shared out), a $300 deposit later voided (which left the deposit "collected": 3051), the deposit raised by
-- hand to $600, and no tip. 3052 doubles an e-Transfer deposit by itself, so the booking's deposit for any way but a
-- credit card is set to the $600 agreed (bookings.debit_deposit_cents, the amount set for the booking), not $1,200.
-- Now: the deposit is $600 taken by e-Transfer, the tip is $13.27, every line of the
-- booking is paid and nothing is open. The booking stays on rent.
set local check_function_bodies = off;

create or replace function app.repair_cc10478() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_by uuid;
  v_pay uuid;
  v_tip uuid;
  d deposits;
  v_ref constant text := 'C1AqmwK7G9Hu';
  v_on constant date := date '2026-11-15';
begin
  select * into b from bookings where booking_number = 'CC-10478';
  if b.id is null then return null; end if;
  -- who recorded the payment of the booking records the rest of the same e-Transfer
  select m.recorded_by into v_by from manual_payments m where m.booking_id = b.id and m.reference = v_ref order by m.recorded_at limit 1;
  if v_by is null then select coalesce(b.sales_staff_id, b.created_by) into v_by; end if;
  if v_by is null then raise notice '3054: CC-10478 has no one to record it as; left as it is'; return null; end if;

  -- the deposit agreed by e-Transfer is $600 (not doubled again)
  if b.deposit_cents = 60000 and b.debit_deposit_cents is null then
    update bookings set debit_deposit_cents = 60000 where id = b.id;
  end if;

  -- the deposit: $600 by e-Transfer
  if not exists (select 1 from manual_payments m where m.booking_id = b.id and m.covers = 'deposit' and m.voided_at is null) then
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
    values (b.id, b.renter_id, 'deposit', 'charge', 'e_transfer', 60000, 'succeeded', app.local_midnight(v_on) + interval '12 hours', v_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
    values (v_pay, 'offline', 'e_transfer:' || v_ref, jsonb_build_object('reference', v_ref, 'received_on', v_on, 'recorded_by', v_by, 'covers', 'deposit', 'note', 'Repair 3054'));
    insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by, covers)
    values (v_pay, 'booking', b.id, b.renter_id, 'e_transfer', 60000, v_on, v_ref, 'The deposit of the $800.00 e-Transfer (repair 3054)', v_by, 'deposit');
    insert into deposits as x (booking_id, amount_cents, method, paid_method, status, hold_payment_id, taken_at, captured_cents)
    values (b.id, 60000, 'offline', 'e_transfer', 'captured', v_pay, app.local_midnight(v_on) + interval '12 hours', 60000)
    on conflict (booking_id) do update set amount_cents = 60000, method = 'offline', paid_method = 'e_transfer', status = 'captured',
           hold_payment_id = v_pay, taken_at = excluded.taken_at, hold_expires_at = null, captured_cents = 60000
    returning * into d;
    insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by)
    values (d.id, 'taken', 60000, v_pay, 'e-Transfer (repair 3054)', v_by);
    update bookings set deposit_pay_method = 'e_transfer' where id = b.id and deposit_pay_method is distinct from 'e_transfer';
    perform app.resolve_tasks(array['take_deposit', 'deposit_declined'], b.id, v_by, 'Deposit taken by e-Transfer');
    update deposit_pendings set cleared_at = now(), cleared_why = 'Deposit taken by e-Transfer (repair 3054)' where booking_id = b.id and cleared_at is null;
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
      'Deposit of $600.00 taken by e-Transfer (' || v_ref || '), recorded by the repair of release 48', v_by, 'staff',
      jsonb_build_object('payment_id', v_pay, 'covers', 'deposit', 'method', 'e_transfer', 'repair', 3054));
  end if;

  -- the tip: $13.27
  if not exists (select 1 from tips t where t.booking_id = b.id and t.reference = v_ref and t.status = 'paid') then
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
    values (b.id, b.renter_id, 'tip', 'charge', 'e_transfer', 1327, 'succeeded', app.local_midnight(v_on) + interval '12 hours', v_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
    values (v_pay, 'offline', 'e_transfer:' || v_ref, jsonb_build_object('reference', v_ref, 'received_on', v_on, 'recorded_by', v_by, 'covers', 'tip', 'note', 'Repair 3054'));
    insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by, covers)
    values (v_pay, 'booking', b.id, b.renter_id, 'e_transfer', 1327, v_on, v_ref, 'The tip of the $800.00 e-Transfer (repair 3054)', v_by, 'tip');
    insert into tips (booking_id, amount_cents, method, source, status, payment_id, reference, received_on, note, recorded_by, paid_at)
    values (b.id, 1327, 'e_transfer', 'staff', 'paid', v_pay, v_ref, v_on, 'The rest of the $800.00 e-Transfer', v_by, app.local_midnight(v_on) + interval '12 hours')
    returning id into v_tip;
    perform app.tip_split(v_tip);
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
      'Tip of $13.27 by e-Transfer (' || v_ref || '), recorded by the repair of release 48', v_by, 'staff',
      jsonb_build_object('tip_id', v_tip, 'payment_id', v_pay, 'repair', 3054));
  end if;

  -- the fee lines: paid by the $186.73 (3051), so nothing is open
  perform app.repair_payment_allocation(b.id);
  return jsonb_build_object('booking', b.booking_number, 'open_cents', app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees'),
    'deposit', (select jsonb_build_object('status', x.status, 'amount_cents', x.amount_cents, 'paid_method', x.paid_method) from deposits x where x.booking_id = b.id),
    'tips_cents', (select coalesce(sum(t.amount_cents), 0) from tips t where t.booking_id = b.id and t.status = 'paid'));
end $$;
revoke all on function app.repair_cc10478() from public, anon, authenticated;
grant execute on function app.repair_cc10478() to service_role;
select app.repair_cc10478();
