-- 0185: paid before the renter signs (the owner, October 28). SCHEMA_MARKER 0185.
-- A renter accepted an offer online and left the pay page; staff took the rental in cash at the office (the deposit as a
-- card hold at pickup). Admin > booking > Money > Record a payment, "The rental and fees", Cash, amount empty:
--   * only the rental part was recorded. "Both" was two separate calls from the browser (the rental, then the fees),
--     so the second could fail alone and leave the first recorded;
--   * the fees part failed with "CarmaCars countersigns once the amount due at booking is paid": paying the last of the
--     amount due confirms the booking, the confirmation countersigns the rental agreement for CarmaCars, and the
--     countersignature looked for ONE payment of exactly the amount due at booking (a card payment), never the parts
--     recorded another way;
--   * a booking whose renter had not signed could not be confirmed at all, so the money could be recorded but the
--     booking stayed waiting for payment.
-- Now:
--   1. "The rental and fees" is one call: both parts in one transaction, all or nothing (app.record_booking_payment,
--      covers 'both'). Recording a payment never fails because the confirmation after it does: the confirmation runs in
--      its own subtransaction and says why it did not confirm.
--   2. The countersignature accepts the amount due at booking paid in parts (nothing open for the rental and the fees).
--   3. Paid in full and the renter has not signed: the booking is confirmed (paid), marked as waiting for the renter's
--      signature (the confirmation event says awaiting_signature). The renter signs later, in person on a staff
--      member's device, online, or on paper; CarmaCars countersigns right after (the same step as a rental added by
--      hand) and the signed copy is queued.
--   4. The car is still not released without the signature: the booking's signature guard refuses check-out (on rent)
--      of a booking confirmed before signing until its agreement is completed; the handover's ready check says
--      "awaiting signature" as for a rental added by hand. A deposit by card is still taken before the car is released
--      (the deposit guard), so a booking paid another way is confirmed without a saved card.
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0185: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. confirmed before the renter signed
-- A booking staff confirmed on a payment received another way before its agreement was signed, until the agreement is
-- completed (signed by the renter and every signer required before payment, then countersigned).
create or replace function app.booking_confirmed_unsigned(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select b.booking_type <> 'owner'
                          and not exists (select 1 from signature_requests s where s.id = b.signature_request_id and s.status = 'completed')
                          and exists (select 1 from booking_events e where e.booking_id = b.id and e.kind = 'confirmed'
                                         and e.details ->> 'awaiting_signature' = 'true')
                     from bookings b where b.id = p_booking), false)
$$;
comment on function app.booking_confirmed_unsigned(uuid) is 'Confirmed on a payment received another way before the renter signed, and the agreement is not completed yet (0185)';

-- The same, while the booking is confirmed (a rental added by hand has its own path, 0046).
create or replace function app.booking_paid_unsigned(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(b.status = 'confirmed' and not coalesce(b.added_by_staff, false) and app.booking_confirmed_unsigned(b.id), false)
$$;

-- Waiting for the signature (the ready check, the handover, the paper signature, the lists): a rental added by hand
-- (0051, 0072) or a booking paid before signing.
create or replace function app.booking_awaiting_signature(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select (app.booking_added_live(b) and b.booking_type <> 'owner'
                           and not exists (select 1 from signature_requests s where s.id = b.signature_request_id and s.status = 'completed'))
                          or app.booking_paid_unsigned(b)
                     from bookings b where b.id = p_booking), false)
$$;

-- The car is not released before the renter signed (0051), for a booking paid before signing too.
create or replace function app.booking_signature_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'on_rent' and old.status is distinct from 'on_rent' and new.added_by_staff
     and coalesce(new.added_mode, 'future') <> 'past' and new.booking_type <> 'owner'
     and not exists (select 1 from signature_requests s where s.id = new.signature_request_id and s.status = 'completed') then
    raise exception 'Do not release the car: the renter has not signed the rental agreement yet (in the portal, or on paper recorded by an Admin)'
      using errcode = '23514';
  end if;
  if new.status = 'on_rent' and old.status is distinct from 'on_rent' and new.booking_type <> 'owner'
     and not exists (select 1 from signature_requests s where s.id = new.signature_request_id and s.status = 'completed')
     and exists (select 1 from booking_events e where e.booking_id = new.id and e.kind = 'confirmed' and e.details ->> 'awaiting_signature' = 'true') then
    raise exception 'Do not release the car: the renter has not signed the rental agreement yet (Sign now on this device, the signing link, or a paper signature)'
      using errcode = '23514';
  end if;
  return new;
end $$;

-- The confirmation rule (0019, 0129): staff confirming a booking paid another way (app.confirm_offline_booking says so
-- for this booking only, for this transaction) confirm it before the agreement is completed and without a saved card.
select pg_temp.patch_fn('app.booking_before_write()'::regprocedure,
  $o$      if not exists (select 1 from signature_requests s where s.id = new.signature_request_id and s.status = 'completed') then
        raise exception 'A booking is confirmed only when the agreement is signed' using errcode = '23514';$o$,
  $n$      if not exists (select 1 from signature_requests s where s.id = new.signature_request_id and s.status = 'completed')
         and coalesce(current_setting('app.confirm_offline', true), '') is distinct from new.id::text then
        raise exception 'A booking is confirmed only when the agreement is signed' using errcode = '23514';$n$);
select pg_temp.patch_fn('app.booking_before_write()'::regprocedure,
  $o$      if new.booking_type <> 'owner' and new.card_on_file_id is null and new.deposit_pay_method = 'card' then
        raise exception 'No saved card, no confirmed booking' using errcode = '23514';$o$,
  $n$      if new.booking_type <> 'owner' and new.card_on_file_id is null and new.deposit_pay_method = 'card'
         and coalesce(current_setting('app.confirm_offline', true), '') is distinct from new.id::text then
        raise exception 'No saved card, no confirmed booking' using errcode = '23514';$n$);

-- ================================================================ 2. the countersignature on money paid in parts
select pg_temp.patch_fn('app.complete_signature_request(uuid, uuid, text, text)'::regprocedure,
  $o$          and p.status = 'succeeded' and p.amount_cents = b.renter_due_at_booking_cents) then
    raise exception 'CarmaCars countersigns once the amount due at booking is paid' using errcode = '23514';$o$,
  $n$          and p.status = 'succeeded' and p.amount_cents = b.renter_due_at_booking_cents)
     and app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees') > 0 then
    raise exception 'CarmaCars countersigns once the amount due at booking is paid' using errcode = '23514';$n$);

-- ================================================================ 3. staff confirm a booking paid another way
create or replace function app.confirm_offline_booking(p_by uuid, p_booking uuid, p_raise boolean default true) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  a rental_agreements;
  v_open bigint;
  v_problem text;
  v_signed boolean;
  v_pay uuid;
begin
  if app.offer_role(p_by) is null and not app.user_runs_finance(p_by) then raise exception 'Customer service, sales, Finance or an Admin confirms a booking' using errcode = '42501'; end if;
  perform 1 from vehicles where id = (select vehicle_id from bookings where id = p_booking) for no key update;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status <> 'pending_payment' then v_problem := format('Booking %s is %s, not waiting for payment', b.booking_number, replace(b.status::text, '_', ' '));
  elsif b.offer_approved_version is distinct from b.current_offer_version then v_problem := 'The renter has not approved the current offer';
  end if;
  if v_problem is null and b.rental_pay_method not in ('insurer', 'platform_payout') then
    v_open := app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees');
    if v_open > 0 then v_problem := format('%s is still open: record the payment first', app.fmt_money(v_open)); end if;
  end if;
  if v_problem is null and b.blocks_calendar and not app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) then
    v_problem := 'The car is no longer free for these dates';
  end if;
  if v_problem is not null then
    if p_raise then raise exception '%', v_problem using errcode = '23514'; end if;
    return jsonb_build_object('ok', false, 'reason', v_problem);
  end if;
  -- signed by the renter and by everyone who signs before payment: CarmaCars countersigns now; otherwise when they sign
  select * into a from rental_agreements where booking_id = b.id and status in ('signed', 'completed') order by opened_at desc limit 1;
  v_signed := a.id is not null and (a.status = 'completed' or not exists (
    select 1 from rental_agreement_signers g where g.agreement_id = a.id and g.required_before_payment and g.signed_at is null));
  begin
    if v_signed and a.status = 'signed' and a.signature_request_id is not null then
      select m.payment_id into v_pay from manual_payments m
       where m.booking_id = b.id and m.voided_at is null and m.covers in ('rental', 'fees') order by m.recorded_at desc limit 1;
      perform app.complete_signature_request(a.signature_request_id, v_pay);
    end if;
    perform set_config('app.confirm_offline', b.id::text, true);
    update bookings set status = 'confirmed' where id = b.id;
    perform set_config('app.confirm_offline', '', true);
  exception when others then
    if p_raise then raise; end if;
    return jsonb_build_object('ok', false, 'reason', sqlerrm);
  end;
  perform app.log_booking_event(b.id, 'confirmed', 'pending_payment', 'confirmed', b.offer_approved_version,
    'Paid by ' || app.payment_method_label(b.rental_pay_method)
      || case when v_signed then '' else '. Waiting for the renter''s signature: CarmaCars countersigns when they sign' end,
    p_by, 'staff', jsonb_build_object('mode', 'offline', 'method', b.rental_pay_method, 'awaiting_signature', not v_signed));
  perform app.resolve_tasks(array['confirm_offline_booking'], b.id, p_by, 'Confirmed');
  return jsonb_build_object('ok', true, 'status', 'confirmed', 'booking_number', b.booking_number, 'awaiting_signature', not v_signed);
end $$;

-- ================================================================ 4. a payment by part and method; "both" in one step
-- p: booking, covers (rental | fees | both | deposit | later), method, amount_cents (empty: what is open for that part;
-- for both, the rental first and the rest for the fees), reference, received_on, note.
create or replace function app.record_booking_payment(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_covers text := coalesce(nullif(p ->> 'covers', ''), 'rental');
  v_method text := coalesce(nullif(p ->> 'method', ''), 'e_transfer');
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_ref text := nullif(btrim(coalesce(p ->> 'reference', '')), '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_on date := coalesce(nullif(p ->> 'received_on', '')::date, app.today());
  v_refuse text;
  v_pay uuid;
  v_mp uuid;
  v_open bigint;
  v_out jsonb;
  v_conf jsonb;
  v_first bigint;
  v_parts jsonb := '[]'::jsonb;
  v_r jsonb;
  v_inner boolean := coalesce(current_setting('app.payment_parts', true), '') <> '';
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_covers not in ('rental', 'deposit', 'fees', 'both', 'later') then raise exception 'Choose what the payment covers: the rental, the fees, both, the deposit or a later charge' using errcode = '22023'; end if;
  if v_method not in ('e_transfer', 'cash', 'cheque', 'bank_transfer', 'platform_payout', 'insurer', 'other') then
    raise exception 'Choose how it was paid: e-Transfer, cash, cheque, bank transfer, platform payout, the insurer or another way. A card is paid through Collect a card' using errcode = '22023';
  end if;
  if b.status in ('cancelled', 'declined', 'expired') then raise exception 'Booking % is %: nothing is owed on it', b.booking_number, b.status using errcode = '23514'; end if;
  if v_covers = 'deposit' then
    if v_method not in ('cash', 'e_transfer') then raise exception 'A deposit is taken by card, in cash or by e-Transfer' using errcode = '22023'; end if;
    return app.record_offline_deposit(p_by, b.id, v_method, v_amount, v_ref, v_on, v_note);
  end if;
  -- the rental and the fees in one payment: two records (one per part, as the statements read them), in this one
  -- transaction, then one confirmation
  if v_covers = 'both' then
    v_open := app.booking_part_open(b.id, 'rental');
    v_amount := coalesce(v_amount, v_open + app.booking_part_open(b.id, 'fees'));
    if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount received: nothing is open for the rental or the fees' using errcode = '22023'; end if;
    v_refuse := app.booking_payment_allowed(p_by, v_amount);
    if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
    v_first := least(v_amount, v_open);
    perform set_config('app.payment_parts', b.id::text, true);
    if v_first > 0 then
      v_r := app.record_booking_payment(p_by, p || jsonb_build_object('covers', 'rental', 'amount_cents', v_first));
      v_parts := v_parts || jsonb_build_array(v_r || jsonb_build_object('covers', 'rental', 'amount_cents', v_first));
    end if;
    if v_amount > v_first then
      v_r := app.record_booking_payment(p_by, p || jsonb_build_object('covers', 'fees', 'amount_cents', v_amount - v_first,
        'reference', case when v_ref is not null and v_first > 0 then v_ref || ' (part 2)' else v_ref end,
        'note', case when v_first > 0 then coalesce(v_note, 'The rest of the same payment, for the fees') else v_note end));
      v_parts := v_parts || jsonb_build_array(v_r || jsonb_build_object('covers', 'fees', 'amount_cents', v_amount - v_first));
    end if;
    perform set_config('app.payment_parts', '', true);
    if b.status = 'pending_payment' then
      v_conf := app.confirm_offline_booking(p_by, b.id, false);
    end if;
    return jsonb_build_object('ok', true, 'id', v_r ->> 'id', 'payment_id', v_r ->> 'payment_id', 'parts', v_parts, 'amount_cents', v_amount,
                              'repeat', coalesce((select bool_and(coalesce((x ->> 'repeat')::boolean, false)) from jsonb_array_elements(v_parts) x), false),
                              'open_cents', app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees'),
                              'confirmed', coalesce((v_conf ->> 'ok')::boolean, false), 'confirm', v_conf);
  end if;
  if v_ref is not null then
    select m.id into v_mp from manual_payments m where m.booking_id = b.id and m.method = v_method and lower(m.reference) = lower(v_ref) and m.voided_at is null;
    if v_mp is not null then return jsonb_build_object('ok', true, 'repeat', true, 'id', v_mp); end if;
  end if;
  v_open := app.booking_part_open(b.id, v_covers);
  v_amount := coalesce(v_amount, v_open);
  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount received: nothing is open for that part' using errcode = '22023'; end if;
  v_refuse := app.booking_payment_allowed(p_by, v_amount);
  if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
  if v_method in ('e_transfer', 'cheque', 'bank_transfer') and (v_ref is null or length(v_ref) < 3) then
    raise exception '%', case v_method when 'cheque' then 'Enter the cheque number' when 'e_transfer' then 'Enter the e-Transfer reference number' else 'Enter the reference of the bank transfer' end using errcode = '22023';
  end if;
  if v_method = 'other' and v_note is null then raise exception 'Say how it was paid in the note' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date received cannot be in the future' using errcode = '22023'; end if;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
  values (b.id, b.renter_id, case v_covers when 'later' then 'post_rental' else 'booking_total' end, 'charge', v_method, v_amount, 'succeeded',
          app.local_midnight(v_on) + interval '12 hours', p_by)
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
  values (v_pay, 'offline', v_method || ':' || coalesce(v_ref, v_pay::text), jsonb_strip_nulls(jsonb_build_object('reference', v_ref, 'received_on', v_on, 'note', v_note, 'recorded_by', p_by, 'covers', v_covers)));
  insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by, covers)
  values (v_pay, 'booking', b.id, b.renter_id, v_method, v_amount, v_on, v_ref, v_note, p_by, v_covers)
  returning id into v_mp;
  -- the lines it pays: the booking's lines of that part once it is paid in full, a later charge's statement lines
  perform app.booking_tie_lines(b.id, v_covers, v_pay);
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('%s received by %s for the %s%s', app.fmt_money(v_amount), app.payment_method_label(v_method),
           case v_covers when 'rental' then 'rental' when 'fees' then 'fees' else 'later charges' end, coalesce(' (' || v_ref || ')', '')), p_by, 'staff',
    jsonb_build_object('payment_id', v_pay, 'covers', v_covers, 'method', v_method, 'amount_cents', v_amount));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'record_booking_payment', 'bookings', b.id::text, jsonb_build_object('payment_id', v_pay, 'manual_payment_id', v_mp, 'covers', v_covers, 'method', v_method,
          'amount_cents', v_amount, 'reference', v_ref, 'received_on', v_on));
  -- the receipt (a payment that confirms an online booking has its own; this one is offline)
  perform app.ntf_emit('renter_payment_receipt', 'payment', v_pay, 'succeeded', jsonb_build_object('booking_id', b.id, 'renter_id', b.renter_id));
  -- paid in full and approved: confirmed now (signed or not: 0185); a part of "both" waits for the whole payment
  if b.status = 'pending_payment' and v_covers in ('rental', 'fees') and not v_inner then
    v_conf := app.confirm_offline_booking(p_by, b.id, false);
  end if;
  v_out := jsonb_build_object('ok', true, 'id', v_mp, 'payment_id', v_pay, 'open_cents', app.booking_part_open(b.id, v_covers), 'confirmed', coalesce((v_conf ->> 'ok')::boolean, false),
                              'confirm', v_conf);
  return v_out;
end $$;

-- ================================================================ 5. the renter signs after paying; CarmaCars countersigns
-- The agreement is opened (or made again) for a booking paid before signing, as while it waited for payment.
select pg_temp.patch_fn('app.open_rental_agreement_0019(uuid, uuid, text, text, text, text)'::regprocedure,
  $o$  if b.status <> 'pending_payment' then$o$,
  $n$  if b.status <> 'pending_payment' and not app.booking_paid_unsigned(b) then$n$);

-- The renter's signature on a booking paid before signing: recorded as for a rental added by hand (the booking is
-- confirmed already), then the countersignature.
select pg_temp.patch_fn('app.record_signature_pre0154(uuid, uuid, text, text, inet, text, text, text, jsonb)'::regprocedure,
  $o$  if not (app.booking_added_live(b) and g.signer_role = 'renter') then$o$,
  $n$  if not ((app.booking_added_live(b) or app.booking_paid_unsigned(b)) and g.signer_role = 'renter') then$n$);
select pg_temp.patch_fn('app.record_signature_pre0154(uuid, uuid, text, text, inet, text, text, text, jsonb)'::regprocedure,
  $o$    if app.booking_added_live(b) then perform app.manual_agreement_complete(b.id); end if;$o$,
  $n$    if app.booking_added_live(b) or app.booking_paid_unsigned(b) then perform app.manual_agreement_complete(b.id); end if;$n$);
-- signed on paper (0046): the same
select pg_temp.patch_fn('app.record_paper_signature_0046(uuid, jsonb)'::regprocedure,
  $o$      if b.added_by_staff then perform app.manual_agreement_complete(b.id); end if;$o$,
  $n$      if b.added_by_staff or app.booking_paid_unsigned(b) then perform app.manual_agreement_complete(b.id); end if;$n$);

-- The countersignature once everyone who signs before payment has signed (0046's step), for a booking paid before
-- signing too, in the name of the staff member who sent the offer (the agreement's countersigner).
select pg_temp.patch_fn('app.manual_agreement_complete_pre0074(uuid)'::regprocedure,
  $o$  if a.id is null or not b.added_by_staff then return null; end if;$o$,
  $n$  if a.id is null or not (b.added_by_staff or app.booking_paid_unsigned(b)) then return null; end if;$n$);
-- ...and its signed copy, queued (the PDF jobs of 0077 render it with every signature).
create or replace function app.manual_agreement_complete(p_booking uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_paid boolean;
  v uuid;
begin
  select * into b from bookings where id = p_booking;
  v_paid := app.booking_paid_unsigned(b);
  v := app.manual_agreement_complete_pre0074(p_booking);
  if v is not null then
    perform app.resolve_tasks(array['live_rental_agreement'], p_booking, null, 'The renter signed');
    if v_paid then
      perform app.pdf_jobs_enqueue(jsonb_build_array(jsonb_build_object('kind', 'renter_signed_copy', 'ref', b.id,
        'user_id', (select r.user_id from renters r where r.id = b.renter_id))));
    end if;
  end if;
  return v;
end $$;

-- ================================================================ 6. what the screens read
-- Sign now on this device (0130): whether the booking is paid and waits for the signature.
select pg_temp.patch_fn('app.in_person_signing(uuid, uuid)'::regprocedure,
  $o$'added', app.booking_added_live(b), 'link_due', app.booking_link_due(b),$o$,
  $n$'added', app.booking_added_live(b), 'paid_unsigned', app.booking_paid_unsigned(b), 'link_due', app.booking_link_due(b),$n$);
-- The renter's booking page: sign with no payment step after (paid already).
create or replace function app.booking_portal_flags(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('added_live', app.booking_added_live(b), 'link_due', app.booking_link_due(b), 'added_mode', b.added_mode,
                            'paid_unsigned', app.booking_paid_unsigned(b))
    from bookings b where b.id = p_booking and app.is_booking_renter(b.id, app.uid())
$$;

-- ================================================================ 7. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['booking_confirmed_unsigned', 'booking_paid_unsigned'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
