-- 3052 (release 48, part 2): the deposit by how it is paid, top-ups and overpaid deposits, a deposit raised while the
-- booking waits for payment (docs/changes/2026-11-15-r48-money-fixes.md).
--
-- 1. A deposit taken by e-Transfer or in cash is the car's deposit times program_settings.offline_deposit_multiplier
--    (2: $300 becomes $600), on by default (offline_deposit_double). A debit or prepaid card keeps its own multiplier
--    (0262, debit_deposit_multiplier); a credit card hold is the deposit. An amount staff set for the booking
--    (bookings.debit_deposit_cents, 0262) is used for every method that is not a credit card. app.deposit_for_method is
--    the one rule; record_payment, the connector, the Money tabs and the renter's pay page read it
--    (public.server_booking_deposit_options).
-- 2. record_payment covers=deposit takes a top-up up to the deposit (a deposit taken in part), and an amount over it:
--    the extra is held with the deposit and given back with it (deposits.amount_cents is all that was taken); the Money
--    tab says "over, to return $X" or "under, still owed $X".
-- 3. An Admin may raise (or lower) the deposit of a booking waiting for payment: Edit booking and the connector's
--    change_booking with only changes.deposit_cents, with the reason, no need to reopen the offer.
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

alter table program_settings add column if not exists offline_deposit_double boolean not null default true;
alter table program_settings add column if not exists offline_deposit_multiplier numeric(4, 2) not null default 2 check (offline_deposit_multiplier between 1 and 5);
comment on column program_settings.offline_deposit_double is 'A deposit by e-Transfer or cash is the deposit times offline_deposit_multiplier (3052). Off: the deposit as it is.';
comment on column program_settings.offline_deposit_multiplier is 'Deposit by e-Transfer or cash (3052): the car''s deposit times this (2: $300 becomes $600).';

-- ================================================================ 1. the one rule
create or replace function app.deposit_for_method(b bookings, p_method text) returns bigint
language sql stable security definer set search_path = public, app as $$
  select case when coalesce(b.deposit_cents, 0) <= 0 or b.booking_type = 'owner' then 0
              when coalesce(p_method, 'card') in ('cash', 'e_transfer') and coalesce((app.settings()).offline_deposit_double, true)
                then coalesce(b.debit_deposit_cents, round(b.deposit_cents * coalesce((app.settings()).offline_deposit_multiplier, 2))::bigint)
              when coalesce(p_method, 'card') in ('debit', 'prepaid') then app.debit_deposit_cents(b)
              else b.deposit_cents end
$$;
revoke all on function app.deposit_for_method(bookings, text) from public, anon, authenticated;
grant execute on function app.deposit_for_method(bookings, text) to service_role;
comment on function app.deposit_for_method(bookings, text) is '3052: the deposit for a way of paying it: a credit card the deposit; e-Transfer or cash the offline multiplier; a debit or prepaid card the debit multiplier (0262); an amount set for the booking for any but a credit card.';

-- what a booking's deposit is for each way, and where it stands (the Money tab, the pay page, the offer)
create or replace function app.deposit_state(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  d deposits;
  v_method text;
  v_req bigint;
  v_taken bigint := 0;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or coalesce(b.deposit_cents, 0) <= 0 then return null; end if;
  select * into d from deposits where booking_id = b.id;
  v_method := case when d.method = 'offline' and d.status not in ('pending', 'failed') then d.paid_method else b.deposit_pay_method end;
  v_req := app.deposit_for_method(b, v_method);
  if d.id is not null and d.status in ('captured', 'held', 'settled', 'carried_forward') then v_taken := d.amount_cents; end if;
  return jsonb_build_object(
    'card_cents', b.deposit_cents,
    'offline_cents', app.deposit_for_method(b, 'e_transfer'),
    'debit_cents', app.debit_deposit_cents(b),
    'offline_on', coalesce((app.settings()).offline_deposit_double, true),
    'multiplier', coalesce((app.settings()).offline_deposit_multiplier, 2),
    'set_by_staff', b.debit_deposit_cents is not null,
    'method', v_method,
    'required_cents', v_req,
    'taken_cents', v_taken,
    'owed_cents', case when v_taken > 0 and d.method = 'offline' then greatest(v_req - v_taken, 0) else 0 end,
    'over_cents', case when v_taken > 0 and d.method = 'offline' then greatest(v_taken - v_req, 0) else 0 end);
end $$;
revoke all on function app.deposit_state(uuid) from public, anon, authenticated;
grant execute on function app.deposit_state(uuid) to service_role;

create or replace function public.server_booking_deposit_options(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.deposit_state(p_booking) $$;
revoke all on function public.server_booking_deposit_options(uuid) from public, anon, authenticated;
grant execute on function public.server_booking_deposit_options(uuid) to service_role;

-- ================================================================ 2. a deposit by e-Transfer or cash: in full, a top-up, or over
create or replace function app.record_offline_deposit(p_by uuid, p_booking uuid, p_method text, p_amount bigint, p_ref text, p_on date, p_note text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d deposits;
  v_pay uuid;
  v_amount bigint;
  v_req bigint;
  v_taken bigint := 0;
  v_refuse text;
  v_total bigint;
begin
  select * into b from bookings where id = p_booking for update;
  if b.status not in ('pending_payment', 'confirmed', 'on_rent') then
    raise exception 'Booking % is %: a deposit is taken once the offer is approved, until the end of the trip', b.booking_number, b.status using errcode = '23514';
  end if;
  if b.booking_type = 'owner' or b.deposit_cents = 0 then raise exception 'Booking % has no deposit to take', b.booking_number using errcode = '23514'; end if;
  v_req := app.deposit_for_method(b, p_method);
  select * into d from deposits where booking_id = b.id for update;
  if d.id is not null and d.status not in ('pending', 'failed') then
    if d.status <> 'captured' or d.method <> 'offline' or d.released_cents > 0 or d.applied_cents > 0 or d.held_back_cents > 0 then
      raise exception 'The deposit on % has already been taken (%): settle it or release the hold first', b.booking_number,
        case d.method when 'card_hold' then 'held on the card' when 'charged' then 'charged to the card' else 'by ' || app.payment_method_label(coalesce(d.paid_method, 'cash')) end
        using errcode = '23514';
    end if;
    v_taken := d.amount_cents;
  end if;
  v_amount := coalesce(p_amount, greatest(v_req - v_taken, 0));
  if v_amount <= 0 then
    raise exception 'The deposit on % has already been taken in full (%): to take more, enter the amount', b.booking_number, app.fmt_money(v_taken) using errcode = '23514';
  end if;
  v_refuse := app.booking_payment_allowed(p_by, v_amount);
  if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
  if p_method = 'e_transfer' and (p_ref is null or length(p_ref) < 3) then raise exception 'Enter the e-Transfer reference number' using errcode = '22023'; end if;
  if p_on > app.today() then raise exception 'The date received cannot be in the future' using errcode = '22023'; end if;
  if p_ref is not null and exists (select 1 from manual_payments m where m.booking_id = b.id and m.covers = 'deposit' and m.method = p_method and lower(m.reference) = lower(p_ref) and m.voided_at is null) then
    return jsonb_build_object('ok', true, 'repeat', true, 'deposit_id', d.id, 'state', app.deposit_state(b.id));
  end if;
  v_total := v_taken + v_amount;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
  values (b.id, b.renter_id, 'deposit', 'charge', p_method, v_amount, 'succeeded', app.local_midnight(p_on) + interval '12 hours', p_by)
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
  values (v_pay, 'offline', p_method || ':' || coalesce(p_ref, v_pay::text), jsonb_strip_nulls(jsonb_build_object('reference', p_ref, 'received_on', p_on, 'note', p_note, 'recorded_by', p_by, 'covers', 'deposit')));
  insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by, covers)
  values (v_pay, 'booking', b.id, b.renter_id, p_method, v_amount, p_on, p_ref, p_note, p_by, 'deposit');
  insert into deposits as x (booking_id, amount_cents, method, paid_method, status, hold_payment_id, taken_at, captured_cents)
  values (b.id, v_total, 'offline', p_method, 'captured', v_pay, now(), v_total)
  on conflict (booking_id) do update set amount_cents = excluded.amount_cents, method = 'offline', paid_method = excluded.paid_method, status = 'captured',
         hold_payment_id = excluded.hold_payment_id, taken_at = coalesce(x.taken_at, excluded.taken_at), hold_expires_at = null, captured_cents = excluded.captured_cents
  returning * into d;
  insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by)
  values (d.id, 'taken', v_amount, v_pay, app.payment_method_label(p_method) || case when v_taken > 0 then ' (a top-up)' else '' end, p_by);
  update bookings set deposit_pay_method = p_method where id = b.id and deposit_pay_method is distinct from p_method;
  perform app.resolve_tasks(array['take_deposit', 'deposit_declined'], b.id, p_by, 'Deposit taken by ' || app.payment_method_label(p_method));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('Deposit of %s taken by %s%s%s', app.fmt_money(v_amount), app.payment_method_label(p_method), coalesce(' (' || p_ref || ')', ''),
           case when v_total < v_req then format('; %s still owed', app.fmt_money(v_req - v_total))
                when v_total > v_req then format('; %s over the deposit, given back with it', app.fmt_money(v_total - v_req)) else '' end), p_by, 'staff',
    jsonb_build_object('payment_id', v_pay, 'covers', 'deposit', 'method', p_method, 'total_cents', v_total, 'required_cents', v_req));
  perform app.ntf_emit('renter_payment_receipt', 'payment', v_pay, 'succeeded', jsonb_build_object('booking_id', b.id, 'renter_id', b.renter_id));
  return jsonb_build_object('ok', true, 'payment_id', v_pay, 'deposit_id', d.id, 'open_cents', 0, 'amount_cents', v_amount, 'taken_cents', v_total,
    'required_cents', v_req, 'owed_cents', greatest(v_req - v_total, 0), 'over_cents', greatest(v_total - v_req, 0));
end $$;
revoke all on function app.record_offline_deposit(uuid, uuid, text, bigint, text, date, text) from public, anon, authenticated;
grant execute on function app.record_offline_deposit(uuid, uuid, text, bigint, text, date, text) to service_role;

-- the Money tab: the deposit for each way of paying, and how much is still owed or over
alter function app.booking_money(uuid, jsonb) rename to booking_money_pre3052;
create function app.booking_money(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.booking_money_pre3052(p_by, p);
begin
  if v is null or nullif(v ->> 'booking_id', '') is null then return v; end if;
  return v || jsonb_build_object('deposit_state', app.deposit_state((v ->> 'booking_id')::uuid));
end $$;
select pg_temp.copy_grants('app.booking_money(uuid, jsonb)'::regprocedure, 'app.booking_money_pre3052(uuid, jsonb)'::regprocedure);

-- ================================================================ 3. the deposit of a booking waiting for payment
create or replace function app.booking_deposit_raise(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_new bigint := nullif(p -> 'changes' ->> 'deposit_cents', '')::bigint;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_new is null or v_new < 0 then raise exception 'Enter the new deposit' using errcode = '22023'; end if;
  if v_reason is null then raise exception 'Give the reason' using errcode = '22023'; end if;
  if b.deposit_cents = v_new then return jsonb_build_object('ok', true, 'changed', false, 'deposit_cents', v_new); end if;
  perform set_config('app.partly_paid_edit', b.id::text, true);
  update bookings set deposit_cents = v_new, updated_at = now() where id = b.id;
  perform set_config('app.partly_paid_edit', '', true);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'booking_deposit_change', 'bookings', b.id::text, jsonb_build_object('deposit_cents', b.deposit_cents), jsonb_build_object('deposit_cents', v_new, 'reason', v_reason));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('Deposit: %s to %s (%s)', app.fmt_money(b.deposit_cents), app.fmt_money(v_new), v_reason), p_by, 'staff',
    jsonb_build_object('deposit_before', b.deposit_cents, 'deposit_after', v_new));
  return jsonb_build_object('ok', true, 'changed', true, 'booking_number', b.booking_number, 'deposit_cents', v_new);
end $$;
revoke all on function app.booking_deposit_raise(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.booking_deposit_raise(uuid, jsonb) to service_role;

alter function app.booking_staff_edit(uuid, jsonb) rename to booking_staff_edit_pre3052;
create function app.booking_staff_edit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_status text := (select status::text from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1);
  c jsonb := coalesce(p -> 'changes', '{}'::jsonb);
begin
  -- only the deposit of a booking waiting for payment: changed at once, the offer stays as it is
  if v_status = 'pending_payment' and c ? 'deposit_cents' and (c - 'deposit_cents' - 'notes') = '{}'::jsonb
     and coalesce(jsonb_array_length(case when jsonb_typeof(p -> 'lines') = 'array' then p -> 'lines' end), 0) = 0 then
    return app.booking_deposit_raise(p_by, p);
  end if;
  return app.booking_staff_edit_pre3052(p_by, p);
end $$;
select pg_temp.copy_grants('app.booking_staff_edit(uuid, jsonb)'::regprocedure, 'app.booking_staff_edit_pre3052(uuid, jsonb)'::regprocedure);
