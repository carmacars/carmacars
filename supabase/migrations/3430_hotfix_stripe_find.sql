-- 3430 (hotfix, Nov 23, CC-10607): a card taken in the Stripe Dashboard app (Tap to Pay) carries no booking in Stripe, so the
-- connector could not see it (stripe_booking finds intents by their booking metadata) nor record it (stripe_record_paid
-- refused an intent not made for the booking), and record_payment refuses a card ("A card is paid through Collect a card").
--   1. stripe_find_payments {from?, to?, hours?, amount_cents?} (admin:read): the database checks the key, the scope and the
--      window (24 hours by default, 30 days at most) and logs the call; the web lists Stripe's PaymentIntents in it (GET
--      only) and asks app.stripe_known_many which ones the platform already recorded, and on which booking.
--   2. stripe_record_paid takes such an untied payment (no booking in its Stripe metadata): app.stripe_untied_plan says how
--      it would be linked, only when Stripe says it succeeded in Canadian dollars, nothing on the platform knows it, the
--      booking is not cancelled, declined or expired, and its amount is exactly what is open on the booking: the rental and
--      fees, the deposit, or both together. server_stripe_link_untied records it through 1081's app.link_stripe_payment
--      (0201's record_card_payment, the path of Collect a card > Link a Stripe payment), audited; rental and deposit
--      together are recorded as the two parts, both carrying the PaymentIntent. Nothing is charged, captured or refunded.
-- No applied migration is edited: app.api_call is wrapped (_pre3430).
-- SCHEMA_MARKER 3430. docs/changes/2026-11-23-hotfix-stripe-find.md.
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

-- ================================================================ 1. which Stripe payments the platform knows, and where
-- {pi_...: {booking_number, where}} for every id the platform recorded (a payment, a pay link, an owner debit)
create or replace function app.stripe_known_many(p_intents text[]) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_object_agg(k.i, jsonb_build_object('booking_number', k.booking_number, 'where', k.w)), '{}'::jsonb)
    from (select distinct on (x.i) x.i, x.booking_number, x.w from (
            select d.processor_payment_id i, b.booking_number, 'payment' w, 1 o
              from payment_processor_details d join payments p on p.id = d.payment_id left join bookings b on b.id = p.booking_id
             where d.processor_payment_id = any (p_intents)
            union all
            select q.processor_intent_id, b.booking_number, 'pay link (' || q.status::text || ')', 2
              from payment_requests q join bookings b on b.id = q.booking_id where q.processor_intent_id = any (p_intents)
            union all
            select a.processor_intent_id, null, 'owner debit', 3 from owner_debit_attempts a where a.processor_intent_id = any (p_intents)
          ) x order by x.i, x.o) k
$$;
comment on function app.stripe_known_many(text[]) is 'r48 hotfix (3430): which of these Stripe PaymentIntents the platform recorded, and on which booking (stripe_find_payments).';

create or replace function public.server_stripe_known_many(p_intents text[]) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.stripe_known_many(coalesce(p_intents, '{}')) $$;

-- ================================================================ 2. how an untied payment would be linked to a booking
-- ok, as (rental | deposit | rental_deposit), rental_cents, deposit_cents, balance_open_cents, deposit_open_cents; or ok false
-- and the reason
create or replace function app.stripe_untied_plan(p_booking uuid, p_amount bigint, p_currency text, p_intent text, p_charge text) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  v_known jsonb;
  v_bal bigint;
  v_dep bigint := 0;
  v_dstatus text;
  v_as text;
  no jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  no := jsonb_build_object('ok', false, 'booking_number', b.booking_number);
  if coalesce(p_intent, '') !~ '^pi_[A-Za-z0-9_]{6,}$' then return no || jsonb_build_object('reason', 'Stripe gave no PaymentIntent for this payment'); end if;
  if app.stripe_known(p_intent, nullif(p_charge, '')) then
    v_known := app.stripe_known_many(array[p_intent]) -> p_intent;
    return no || jsonb_build_object('reason', format('This Stripe payment is already recorded%s: nothing is recorded twice',
      coalesce(' on ' || (v_known ->> 'booking_number'), case when v_known ->> 'where' = 'owner debit' then ' as an owner debit' else ' on the platform' end)));
  end if;
  if lower(coalesce(p_currency, '')) <> 'cad' then
    return no || jsonb_build_object('reason', format('Stripe says this payment is in %s, not Canadian dollars', upper(coalesce(nullif(p_currency, ''), 'another currency'))));
  end if;
  if b.status in ('cancelled', 'declined', 'expired') then
    return no || jsonb_build_object('reason', format('Booking %s is %s: nothing is owed on it. Reopen it first, then record the payment', b.booking_number, b.status));
  end if;
  v_bal := greatest(coalesce(app.booking_part_open(b.id, 'balance'), 0), 0);
  select d.status into v_dstatus from deposits d where d.booking_id = b.id;
  if b.booking_type <> 'owner' and coalesce(b.deposit_cents, 0) > 0 and b.status in ('pending_payment', 'confirmed', 'on_rent', 'returned')
     and coalesce(v_dstatus, 'pending') in ('pending', 'failed') then
    v_dep := b.deposit_cents;
  end if;
  v_as := case when v_bal > 0 and p_amount = v_bal then 'rental'
               when v_dep > 0 and p_amount = v_dep then 'deposit'
               when v_bal > 0 and v_dep > 0 and p_amount = v_bal + v_dep then 'rental_deposit' end;
  if v_as is null then
    return no || jsonb_build_object('reason', format('Stripe says %s was paid; open on %s: the rental and fees %s, the deposit %s%s. An untied payment is linked only when it is exactly one of these',
      app.fmt_money(coalesce(p_amount, 0)), b.booking_number, app.fmt_money(v_bal), app.fmt_money(v_dep),
      case when v_bal > 0 and v_dep > 0 then ', both ' || app.fmt_money(v_bal + v_dep) else '' end),
      'balance_open_cents', v_bal, 'deposit_open_cents', v_dep);
  end if;
  return jsonb_build_object('ok', true, 'as', v_as, 'booking_id', b.id, 'booking_number', b.booking_number,
    'rental_cents', case when v_as in ('rental', 'rental_deposit') then v_bal else 0 end,
    'deposit_cents', case when v_as in ('deposit', 'rental_deposit') then v_dep else 0 end,
    'balance_open_cents', v_bal, 'deposit_open_cents', v_dep);
end $$;
comment on function app.stripe_untied_plan(uuid, bigint, text, text, text) is 'r48 hotfix (3430): how a Stripe payment with no booking (Tap to Pay in the Dashboard) would be linked to a booking: its amount is exactly the open rental and fees, the deposit, or both; never one the platform knows.';

create or replace function public.server_stripe_untied_plan(p_booking uuid, p_amount bigint, p_currency text, p_intent text, p_charge text) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.stripe_untied_plan(p_booking, p_amount, p_currency, p_intent, p_charge) $$;

-- ================================================================ 3. linking it (the connector's stripe_record_paid, confirmed)
-- p_verified: the website's read of the PaymentIntent at Stripe (intent_id, charge_id, status, amount_cents, capturable_cents,
-- currency, last4, brand, fingerprint, capture_before), as Link a Stripe payment takes it (1081)
create or replace function public.server_stripe_link_untied(p_by uuid, p_booking uuid, p_verified jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  d deposits;
  v jsonb := case when jsonb_typeof(p_verified) = 'object' then p_verified end;
  plan jsonb;
  v_intent text;
  v_charge text;
  v_last4 text;
  v_brand text;
  v_note text := 'Card taken in the Stripe Dashboard (no booking in Stripe), linked by the connector';
  v_dep bigint;
  v_refuse text;
  v_pay uuid;
  v_mp uuid;
  r jsonb;
  r2 jsonb;
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v is null then raise exception 'The payment is read at Stripe first' using errcode = '22023'; end if;
  if coalesce(v ->> 'status', '') <> 'succeeded' then
    raise exception 'Stripe says this payment is %, not succeeded: nothing is recorded (and nothing is captured here)', replace(coalesce(v ->> 'status', 'unknown'), '_', ' ') using errcode = '23514';
  end if;
  v_intent := nullif(v ->> 'intent_id', '');
  v_charge := nullif(v ->> 'charge_id', '');
  v_last4 := nullif(v ->> 'last4', '');
  v_brand := nullif(lower(v ->> 'brand'), '');
  plan := app.stripe_untied_plan(b.id, (v ->> 'amount_cents')::bigint, v ->> 'currency', v_intent, v_charge);
  if not (plan ->> 'ok')::boolean then raise exception '%', plan ->> 'reason' using errcode = '23514'; end if;

  if plan ->> 'as' in ('rental', 'deposit') then
    r := app.link_stripe_payment(p_by, jsonb_build_object('booking', b.id, 'as', plan ->> 'as', 'verified', v, 'note', v_note));
  else
    -- the rental and fees, then the deposit, from one payment: both parts carry the PaymentIntent (the first its charge too,
    -- so a refund finds it); the deposit is kept as captured, like a deposit charged in Stripe (1081)
    if v_last4 is null or v_last4 !~ '^[0-9]{4}$' then raise exception 'Stripe shows no card on this payment: record it with Record a payment instead' using errcode = '23514'; end if;
    r := app.record_card_payment(p_by, jsonb_build_object('booking', b.id, 'covers', 'both', 'amount_cents', (plan ->> 'rental_cents')::bigint, 'last4', v_last4, 'brand', v_brand,
           'source', 'dashboard', 'stripe_id', v_intent, 'verified', v || jsonb_build_object('amount_cents', (plan ->> 'rental_cents')::bigint), 'note', v_note));
    v_dep := (plan ->> 'deposit_cents')::bigint;
    v_refuse := app.booking_payment_allowed(p_by, v_dep);
    if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
    select * into d from deposits where booking_id = b.id for update;
    if d.id is not null and d.status not in ('pending', 'failed') then raise exception 'The deposit on % has already been taken', b.booking_number using errcode = '23514'; end if;
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, card_brand, card_last4, processed_at, created_by)
    values (b.id, b.renter_id, 'deposit', 'charge', 'card', v_dep, 'succeeded', v_brand, v_last4, now(), p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, raw)
    values (v_pay, 'stripe', v_intent, null, jsonb_build_object('recorded_by', p_by, 'source', 'dashboard', 'covers', 'deposit', 'note', v_note, 'outside_site', true, 'linked', true,
            'part_of', v_intent, 'charge_id', v_charge));
    insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by, covers, card_last4, card_source, stripe_verified)
    values (v_pay, 'booking', b.id, b.renter_id, 'card', v_dep, app.today(), v_intent, v_note, p_by, 'deposit', v_last4, 'dashboard', true)
    returning id into v_mp;
    insert into deposits as x (booking_id, amount_cents, method, status, hold_payment_id, taken_at, captured_cents)
    values (b.id, v_dep, 'charged', 'captured', v_pay, now(), v_dep)
    on conflict (booking_id) do update set amount_cents = excluded.amount_cents, method = 'charged', paid_method = null, status = 'captured', hold_payment_id = excluded.hold_payment_id,
           taken_at = excluded.taken_at, hold_expires_at = null, captured_cents = excluded.captured_cents
     where x.status in ('pending', 'failed')
    returning * into d;
    if d.id is null then raise exception 'The deposit on % has already been taken', b.booking_number using errcode = '23514'; end if;
    insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by)
    values (d.id, 'taken', v_dep, v_pay, 'charged in Stripe with the rental, linked by the connector', p_by);
    update bookings set deposit_pay_method = 'card' where id = b.id and deposit_pay_method is distinct from 'card';
    perform app.resolve_tasks(array['take_deposit', 'deposit_declined'], b.id, p_by, 'Deposit linked from Stripe');
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
      format('Deposit of %s charged in Stripe with the rental (%s ending %s), linked', app.fmt_money(v_dep), initcap(coalesce(v_brand, 'card')), v_last4), p_by, 'staff',
      jsonb_build_object('payment_id', v_pay, 'covers', 'deposit', 'method', 'card', 'intent_id', v_intent));
    r2 := jsonb_build_object('payment_id', v_pay, 'deposit_id', d.id, 'id', v_mp, 'captured', true);
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'link_stripe_payment', 'bookings', b.id::text, jsonb_build_object('as', 'rental_deposit', 'intent_id', v_intent, 'charge_id', v_charge, 'status', 'succeeded',
            'amount_cents', (v ->> 'amount_cents')::bigint, 'payment_id', r ->> 'payment_id', 'deposit_payment_id', v_pay, 'last4', v_last4));
    delete from stripe_unlinked where intent_id = v_intent or (v_charge is not null and charge_id = v_charge);
    r := jsonb_build_object('ok', true, 'rental', r, 'deposit', r2, 'linked', true, 'as', 'rental_deposit', 'booking_number', b.booking_number);
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'connector_stripe_link_untied', 'bookings', b.id::text, jsonb_build_object('intent_id', v_intent, 'charge_id', v_charge, 'amount_cents', (v ->> 'amount_cents')::bigint,
          'as', plan ->> 'as', 'rental_cents', (plan ->> 'rental_cents')::bigint, 'deposit_cents', (plan ->> 'deposit_cents')::bigint, 'last4', v_last4));
  return r || jsonb_build_object('as', plan ->> 'as', 'booking_number', b.booking_number, 'rental_cents', (plan ->> 'rental_cents')::bigint, 'deposit_cents', (plan ->> 'deposit_cents')::bigint);
end $$;
comment on function public.server_stripe_link_untied(uuid, uuid, jsonb) is 'r48 hotfix (3430): the connector''s stripe_record_paid, confirmed, for a Stripe payment with no booking: linked as Link a Stripe payment does (1081), audited. Never charges, captures or refunds.';

-- ================================================================ 4. the connector: stripe_find_payments
alter function app.api_call(text, text, jsonb, text) rename to api_call_pre3430;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_to timestamptz;
  v_from timestamptz;
  v_hours numeric;
  v_amount bigint;
  v_result jsonb;
begin
  if p_tool <> 'stripe_find_payments' then return app.api_call_pre3430(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:read', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  begin
    v_to := coalesce(nullif(a ->> 'to', '')::timestamptz, now());
    if v_to > now() then v_to := now(); end if;
    v_hours := coalesce(nullif(a ->> 'hours', '')::numeric, 24);
    if v_hours <= 0 or v_hours > 720 then raise exception 'hours: from 1 to 720 (30 days)' using errcode = '22023'; end if;
    v_from := coalesce(nullif(a ->> 'from', '')::timestamptz, v_to - make_interval(secs => v_hours * 3600));
    if v_from >= v_to then raise exception 'from must be before to' using errcode = '22023'; end if;
    if v_to - v_from > interval '30 days' then raise exception 'The window is 30 days at most' using errcode = '22023'; end if;
    v_amount := nullif(a ->> 'amount_cents', '')::bigint;
    if v_amount is not null and v_amount <= 0 then raise exception 'amount_cents: a positive amount in cents' using errcode = '22023'; end if;
    v_result := jsonb_build_object('run', 'stripe_find', 'from', v_from, 'to', v_to,
      'since', floor(extract(epoch from v_from))::bigint, 'until', ceil(extract(epoch from v_to))::bigint, 'amount_cents', v_amount);
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, p_tool, a, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case when sqlstate in ('22023', '22007', '22008', '22P02') then 400 when sqlstate = '42501' then 403 else 400 end,
      'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client) values (k.id, k.user_id, p_tool, p_tool, a, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre3430(text, text, jsonb, text)'::regprocedure);

-- ================================================================ 5. privileges
revoke all on function app.api_call_pre3430(text, text, jsonb, text), app.stripe_known_many(text[]), app.stripe_untied_plan(uuid, bigint, text, text, text),
  public.server_stripe_known_many(text[]), public.server_stripe_untied_plan(uuid, bigint, text, text, text), public.server_stripe_link_untied(uuid, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function app.api_call_pre3430(text, text, jsonb, text), app.stripe_known_many(text[]), app.stripe_untied_plan(uuid, bigint, text, text, text),
  public.server_stripe_known_many(text[]), public.server_stripe_untied_plan(uuid, bigint, text, text, text), public.server_stripe_link_untied(uuid, uuid, jsonb)
  to service_role;
