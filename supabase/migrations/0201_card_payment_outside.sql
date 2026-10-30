-- 0201: a card payment taken outside the site (Release 21, item 2). SCHEMA_MARKER 0201.
-- docs/changes/2026-10-31-card-payment-outside.md.
--   "Record card payment" on a booking: a card taken in the Stripe Dashboard or on a card reader, for the rental, the
--   fees, both, a later charge, or the deposit. The last 4 digits are always asked. A Stripe payment id (pi_... or
--   ch_...) is optional for a payment and needed for a deposit hold: the website reads it at Stripe and the database
--   checks the amount, the last 4 digits and the state against what was typed. A deposit hold is recorded as held (a card
--   hold, released or captured from Settle the deposit like any hold), so the release reminders apply.
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

-- a card recorded by hand is a manual payment of method card
alter table manual_payments drop constraint if exists manual_payments_method_check;
alter table manual_payments add constraint manual_payments_method_check
  check (method = any (array['e_transfer', 'cheque', 'cash', 'bank_transfer', 'other', 'platform_payout', 'insurer', 'card']));
alter table manual_payments add column if not exists card_last4 text check (card_last4 ~ '^[0-9]{4}$');
alter table manual_payments add column if not exists card_source text check (card_source in ('dashboard', 'reader'));
alter table manual_payments add column if not exists stripe_verified boolean not null default false;
comment on column manual_payments.card_source is 'A card taken outside the site (0201): in the Stripe Dashboard or on a card reader.';

-- p: booking, covers (rental | fees | both | later | deposit), amount_cents, last4, brand, source (dashboard | reader),
--    stripe_id (pi_... or ch_...), verified (what Stripe answered for stripe_id, read by the website: intent_id, charge_id,
--    status, amount_cents, capturable_cents, last4, brand, fingerprint, capture_before epoch seconds), received_on, note.
create function app.record_card_payment(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d deposits;
  v_covers text := coalesce(nullif(p ->> 'covers', ''), 'rental');
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_last4 text := nullif(btrim(coalesce(p ->> 'last4', '')), '');
  v_brand text := nullif(lower(btrim(coalesce(p ->> 'brand', ''))), '');
  v_source text := coalesce(nullif(p ->> 'source', ''), 'dashboard');
  v_sid text := nullif(btrim(coalesce(p ->> 'stripe_id', '')), '');
  v jsonb := case when jsonb_typeof(p -> 'verified') = 'object' then p -> 'verified' end;
  v_intent text;
  v_charge text;
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_on date := coalesce(nullif(p ->> 'received_on', '')::date, app.today());
  v_refuse text;
  v_open bigint;
  v_first bigint;
  v_pay uuid;
  v_mp uuid;
  v_conf jsonb;
  v_parts jsonb := '[]'::jsonb;
  v_r jsonb;
  v_expires timestamptz;
  v_inner boolean := coalesce(current_setting('app.payment_parts', true), '') <> '';
  v_label text;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_covers not in ('rental', 'fees', 'both', 'later', 'deposit') then
    raise exception 'Choose what the card paid: the rental, the fees, both, a later charge or the deposit' using errcode = '22023';
  end if;
  if v_source not in ('dashboard', 'reader') then raise exception 'Say where the card was taken: the Stripe Dashboard or a card reader' using errcode = '22023'; end if;
  if b.status in ('cancelled', 'declined', 'expired') then raise exception 'Booking % is %: nothing is owed on it', b.booking_number, b.status using errcode = '23514'; end if;
  if v_last4 is null or v_last4 !~ '^[0-9]{4}$' then raise exception 'Enter the last 4 digits of the card' using errcode = '22023'; end if;
  if v_sid is not null and v_sid !~ '^(pi|ch)_[A-Za-z0-9_]{6,}$' then
    raise exception 'A Stripe payment id starts with pi_ (the payment) or ch_ (the charge): copy it from the payment in the Stripe Dashboard' using errcode = '22023';
  end if;
  if v_sid is not null and v is null then raise exception 'Look up the Stripe payment first' using errcode = '22023'; end if;
  if v is not null then
    v_intent := nullif(v ->> 'intent_id', '');
    v_charge := nullif(v ->> 'charge_id', '');
    if v_sid is not null and v_sid not in (coalesce(v_intent, ''), coalesce(v_charge, '')) then
      raise exception 'The Stripe payment looked up is not the one typed' using errcode = '22023';
    end if;
    if (v ->> 'last4') is not null and v ->> 'last4' <> v_last4 then
      raise exception 'Stripe says this card ends %, not %', v ->> 'last4', v_last4 using errcode = '23514';
    end if;
    v_brand := coalesce(v_brand, nullif(lower(v ->> 'brand'), ''));
    if exists (select 1 from payment_processor_details x where x.processor = 'stripe' and (x.processor_payment_id = v_intent or (v_charge is not null and x.processor_charge_id = v_charge))) then
      raise exception 'This Stripe payment is already recorded' using errcode = '23505';
    end if;
  end if;

  -- ---------------------------------------------------------------- a deposit hold
  if v_covers = 'deposit' then
    if v_intent is null then
      raise exception 'A deposit hold needs its Stripe payment id (pi_...), so it can be captured or released from the booking' using errcode = '22023';
    end if;
    if v ->> 'status' <> 'requires_capture' then
      raise exception 'Stripe says this payment is %, not a hold waiting to be captured: record a charged deposit as a payment for later charges, or place a new hold',
        replace(coalesce(v ->> 'status', 'unknown'), '_', ' ') using errcode = '23514';
    end if;
    if b.status not in ('pending_payment', 'confirmed', 'on_rent') then
      raise exception 'Booking % is %: a deposit is taken once the offer is approved, until the end of the trip', b.booking_number, b.status using errcode = '23514';
    end if;
    if b.booking_type = 'owner' or b.deposit_cents = 0 then raise exception 'Booking % has no deposit to take', b.booking_number using errcode = '23514'; end if;
    v_amount := coalesce(v_amount, (v ->> 'capturable_cents')::bigint, b.deposit_cents);
    if (v ->> 'capturable_cents')::bigint is distinct from v_amount then
      raise exception 'Stripe holds % on this card, not %', app.fmt_money((v ->> 'capturable_cents')::bigint), app.fmt_money(v_amount) using errcode = '23514';
    end if;
    if v_amount <> b.deposit_cents then
      raise exception 'The deposit on % is %: the hold must be for the whole deposit (an Admin can change the deposit on the booking first)', b.booking_number, app.fmt_money(b.deposit_cents) using errcode = '23514';
    end if;
    v_refuse := app.booking_payment_allowed(p_by, v_amount);
    if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
    select * into d from deposits where booking_id = b.id for update;
    if d.id is not null and d.status not in ('pending', 'failed') then raise exception 'The deposit on % has already been taken', b.booking_number using errcode = '23514'; end if;
    -- a hold lapses: on a reader (card present) after 2 days, online after 7, unless Stripe says when
    v_expires := coalesce(to_timestamp(nullif(v ->> 'capture_before', '')::double precision),
                          now() + case when v_source = 'reader' then interval '2 days' else interval '7 days' end);
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, card_brand, card_last4, processed_at, created_by)
    values (b.id, b.renter_id, 'deposit', 'hold', 'card', v_amount, 'authorized', v_brand, v_last4, now(), p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, raw)
    values (v_pay, 'stripe', v_intent, v_charge, jsonb_strip_nulls(jsonb_build_object('recorded_by', p_by, 'source', v_source, 'covers', 'deposit', 'note', v_note, 'outside_site', true)));
    insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by, covers, card_last4, card_source, stripe_verified)
    values (v_pay, 'booking', b.id, b.renter_id, 'card', v_amount, v_on, v_intent, v_note, p_by, 'deposit', v_last4, v_source, true)
    returning id into v_mp;
    insert into deposits as x (booking_id, amount_cents, method, status, hold_payment_id, taken_at, hold_expires_at)
    values (b.id, v_amount, 'card_hold', 'held', v_pay, now(), v_expires)
    on conflict (booking_id) do update set amount_cents = excluded.amount_cents, method = 'card_hold', paid_method = null, status = 'held', hold_payment_id = excluded.hold_payment_id,
           taken_at = excluded.taken_at, hold_expires_at = excluded.hold_expires_at, captured_cents = 0
     where x.status in ('pending', 'failed')
    returning * into d;
    insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by)
    values (d.id, 'taken', v_amount, v_pay, format('card hold %s, recorded by hand', case v_source when 'reader' then 'on a card reader' else 'in the Stripe Dashboard' end), p_by);
    update bookings set deposit_pay_method = 'card' where id = b.id and deposit_pay_method is distinct from 'card';
    perform app.resolve_tasks(array['take_deposit', 'deposit_declined'], b.id, p_by, 'Deposit hold recorded');
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
      format('Deposit hold of %s recorded (%s ending %s, %s)', app.fmt_money(v_amount), initcap(coalesce(v_brand, 'card')), v_last4,
             case v_source when 'reader' then 'card reader' else 'Stripe Dashboard' end), p_by, 'staff',
      jsonb_build_object('payment_id', v_pay, 'covers', 'deposit', 'method', 'card', 'source', v_source));
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'record_card_payment', 'bookings', b.id::text, jsonb_build_object('payment_id', v_pay, 'covers', 'deposit', 'amount_cents', v_amount, 'last4', v_last4,
            'source', v_source, 'intent_id', v_intent));
    return jsonb_build_object('ok', true, 'payment_id', v_pay, 'deposit_id', d.id, 'id', v_mp, 'held', true, 'hold_expires_at', v_expires);
  end if;

  -- ---------------------------------------------------------------- a payment
  if v is not null and v ->> 'status' <> 'succeeded' then
    raise exception 'Stripe says this payment is %, not paid', replace(coalesce(v ->> 'status', 'unknown'), '_', ' ') using errcode = '23514';
  end if;
  if v_covers = 'both' then
    v_open := app.booking_part_open(b.id, 'rental');
    v_amount := coalesce(v_amount, (v ->> 'amount_cents')::bigint, v_open + app.booking_part_open(b.id, 'fees'));
    if v is not null and (v ->> 'amount_cents')::bigint is distinct from v_amount then
      raise exception 'Stripe says % was paid, not %', app.fmt_money((v ->> 'amount_cents')::bigint), app.fmt_money(v_amount) using errcode = '23514';
    end if;
    if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount paid: nothing is open for the rental or the fees' using errcode = '22023'; end if;
    v_first := least(v_amount, v_open);
    perform set_config('app.payment_parts', b.id::text, true);
    if v_first > 0 then
      v_r := app.record_card_payment(p_by, p || jsonb_build_object('covers', 'rental', 'amount_cents', v_first, 'verified', null, 'stripe_id', null, '_intent', v_intent, '_charge', v_charge));
      v_parts := v_parts || jsonb_build_array(v_r || jsonb_build_object('covers', 'rental', 'amount_cents', v_first));
    end if;
    if v_amount > v_first then
      v_r := app.record_card_payment(p_by, p || jsonb_build_object('covers', 'fees', 'amount_cents', v_amount - v_first, 'verified', null, 'stripe_id', null,
                                                               '_intent', case when v_first > 0 then null else v_intent end, '_charge', case when v_first > 0 then null else v_charge end,
                                                               '_part_of', case when v_first > 0 then coalesce(v_intent, v_charge) end));
      v_parts := v_parts || jsonb_build_array(v_r || jsonb_build_object('covers', 'fees', 'amount_cents', v_amount - v_first));
    end if;
    perform set_config('app.payment_parts', '', true);
    if b.status = 'pending_payment' then v_conf := app.confirm_offline_booking(p_by, b.id, false); end if;
    return jsonb_build_object('ok', true, 'parts', v_parts, 'amount_cents', v_amount, 'confirmed', coalesce((v_conf ->> 'ok')::boolean, false), 'confirm', v_conf,
                              'open_cents', app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees'));
  end if;
  -- the parts of "both" carry the Stripe ids of the whole payment (the first part holds them, so a refund finds them)
  v_intent := coalesce(v_intent, nullif(p ->> '_intent', ''));
  v_charge := coalesce(v_charge, nullif(p ->> '_charge', ''));
  v_open := app.booking_part_open(b.id, v_covers);
  v_amount := coalesce(v_amount, (v ->> 'amount_cents')::bigint, v_open);
  if v is not null and (v ->> 'amount_cents')::bigint is distinct from v_amount then
    raise exception 'Stripe says % was paid, not %', app.fmt_money((v ->> 'amount_cents')::bigint), app.fmt_money(v_amount) using errcode = '23514';
  end if;
  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount paid: nothing is open for that part' using errcode = '22023'; end if;
  v_refuse := app.booking_payment_allowed(p_by, v_amount);
  if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
  if v_on > app.today() then raise exception 'The date paid cannot be in the future' using errcode = '22023'; end if;
  v_label := format('card ending %s (%s)', v_last4, case v_source when 'reader' then 'card reader' else 'Stripe Dashboard' end);
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, card_brand, card_last4, processed_at, created_by)
  values (b.id, b.renter_id, case v_covers when 'later' then 'post_rental' else 'booking_total' end, 'charge', 'card', v_amount, 'succeeded', v_brand, v_last4,
          case when v_on = app.today() then now() else app.local_midnight(v_on) + interval '12 hours' end, p_by)
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, raw)
  values (v_pay, case when v_intent is not null or v_charge is not null then 'stripe' else 'outside_card' end,
          coalesce(v_intent, case when v_charge is null then 'card:' || v_last4 || ':' || v_pay::text end), v_charge,
          jsonb_strip_nulls(jsonb_build_object('recorded_by', p_by, 'source', v_source, 'covers', v_covers, 'note', v_note, 'outside_site', true, 'part_of', p ->> '_part_of')));
  insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by, covers, card_last4, card_source, stripe_verified)
  values (v_pay, 'booking', b.id, b.renter_id, 'card', v_amount, v_on, coalesce(v_intent, v_charge, p ->> '_part_of'), v_note, p_by, v_covers, v_last4, v_source,
          v_intent is not null or v_charge is not null or p ->> '_part_of' is not null)
  returning id into v_mp;
  perform app.booking_tie_lines(b.id, v_covers, v_pay);
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('%s paid by %s for the %s', app.fmt_money(v_amount), v_label, case v_covers when 'rental' then 'rental' when 'fees' then 'fees' else 'later charges' end), p_by, 'staff',
    jsonb_build_object('payment_id', v_pay, 'covers', v_covers, 'method', 'card', 'source', v_source, 'amount_cents', v_amount));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'record_card_payment', 'bookings', b.id::text, jsonb_build_object('payment_id', v_pay, 'manual_payment_id', v_mp, 'covers', v_covers, 'amount_cents', v_amount,
          'last4', v_last4, 'source', v_source, 'intent_id', v_intent, 'charge_id', v_charge));
  perform app.ntf_emit('renter_payment_receipt', 'payment', v_pay, 'succeeded', jsonb_build_object('booking_id', b.id, 'renter_id', b.renter_id));
  if b.status = 'pending_payment' and v_covers in ('rental', 'fees') and not v_inner then
    v_conf := app.confirm_offline_booking(p_by, b.id, false);
  end if;
  return jsonb_build_object('ok', true, 'id', v_mp, 'payment_id', v_pay, 'open_cents', app.booking_part_open(b.id, v_covers),
                            'confirmed', coalesce((v_conf ->> 'ok')::boolean, false), 'confirm', v_conf);
end $$;
comment on function app.record_card_payment(uuid, jsonb) is 'Record a card payment or deposit hold taken outside the site, in the Stripe Dashboard or on a card reader (0201).';

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0201;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'ops_do' and p_name = 'record_card_payment' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'finance', 'cs', 'sales')) then
      raise exception 'Only an Admin, Finance, customer service or Sales records a card payment' using errcode = '42501';
    end if;
    -- internal keys of the parts of one payment are never taken from the caller
    return app.record_card_payment(p_user, p_ - '_intent' - '_charge' - '_part_of');
  end if;
  return app.door_pre0201(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0201(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.record_card_payment(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.record_card_payment(uuid, jsonb) to service_role;
revoke all on function app.door_pre0201(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.door_pre0201(uuid, text, text, text, jsonb) to service_role;
