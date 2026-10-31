-- 0262: a higher deposit on a debit or prepaid card (the owner, Release 24b). docs/changes/2026-11-04-debit-deposit.md.
--
-- A debit or prepaid card is taken for the deposit only on a booking that allows it (0230's override, the site-wide
-- setting, a car needing no credit card). On such a card the deposit is higher: program_settings.debit_deposit_multiplier
-- (2: a $300 deposit becomes $600), or the amount staff set for the booking (bookings.debit_deposit_cents, an Admin, with
-- the reason, audited). It applies to the automatic hold of the pickup day (0261), the deposit link and staff's Collect a
-- card > The deposit hold: the pay page says the debit amount before the card is entered, and a hold placed with the
-- other kind of card than its amount was for is voided and asked again for the right amount (nothing is held twice).
-- The Money tab shows "Debit deposit: 2x ($600.00)". No applied migration is edited.
set local check_function_bodies = off;

alter table program_settings add column if not exists debit_deposit_multiplier numeric(4, 2) not null default 2 check (debit_deposit_multiplier between 1 and 5);
comment on column program_settings.debit_deposit_multiplier is 'Deposit with a debit or prepaid card (0262): the car''s deposit times this (2: $300 becomes $600). Staff can set another amount per booking.';
alter table bookings add column if not exists debit_deposit_cents bigint check (debit_deposit_cents is null or debit_deposit_cents > 0);
comment on column bookings.debit_deposit_cents is 'The deposit on a debit or prepaid card for this booking, set by staff (0262); empty: the deposit times program_settings.debit_deposit_multiplier.';

-- the deposit on a debit or prepaid card
create or replace function app.debit_deposit_cents(b bookings) returns bigint
language sql stable security definer set search_path = public, app as $$
  select case when coalesce(b.deposit_cents, 0) <= 0 then 0
              else coalesce(b.debit_deposit_cents, round(b.deposit_cents * coalesce((app.settings()).debit_deposit_multiplier, 2))::bigint) end
$$;

-- the deposit held on a card: higher on a debit or prepaid card the booking takes
create or replace function app.deposit_hold_amount(b bookings, p_funding text) returns bigint
language sql stable security definer set search_path = public, app as $$
  select case when coalesce(p_funding, 'credit') in ('debit', 'prepaid') and app.booking_card_ok(b.id, jsonb_build_object('funding', p_funding))
              then app.debit_deposit_cents(b) else b.deposit_cents end
$$;

-- the pay page and its server: the hold this request needs for that card (null: not a deposit hold)
create or replace function public.server_payreq_hold_required(p_id uuid, p_card jsonb) returns bigint
language sql stable security definer set search_path = public, app as $$
  select app.deposit_hold_amount(b, coalesce(p_card ->> 'funding', 'credit'))
    from payment_requests q join bookings b on b.id = q.booking_id
   where q.id = p_id and q.kind = 'hold' and q.status = 'open' and q.channel <> 'reader'
$$;

-- a hold asked again for another amount: the request's amount and its new authorization
create or replace function public.server_payreq_hold_reset(p_id uuid, p_intent text, p_amount bigint) returns void
language plpgsql security definer set search_path = public, app as $$
declare q payment_requests;
begin
  select * into q from payment_requests where id = p_id for update;
  if q.id is null or q.kind <> 'hold' or q.status <> 'open' then raise exception 'That deposit hold is not open' using errcode = '23514'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'The amount is missing' using errcode = '22023'; end if;
  update payment_requests set amount_cents = p_amount, processor_intent_id = p_intent,
         last_error = format('hold_amount: asked again for %s', app.fmt_money(p_amount)) where id = q.id;
end $$;

-- what the pay page says before the card: the deposit with a debit or prepaid card, when the booking takes one
create or replace function public.server_payreq_debit_deposit(p_id uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select case when public.booking_takes_debit(b.id) then app.debit_deposit_cents(b) end
    from payment_requests q join bookings b on b.id = q.booking_id where q.id = p_id and q.kind = 'hold'
$$;

-- the offer and the booking summary: the deposit with a debit or prepaid card, once the booking takes one (null: it does not)
create or replace function public.server_booking_debit_deposit(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select case when public.booking_takes_debit(b.id) and b.deposit_cents > 0 then app.debit_deposit_cents(b) end from bookings b where b.id = p_booking
$$;

-- staff set the debit deposit of one booking (an Admin, with the reason); empty: back to the multiplier
create or replace function app.booking_debit_deposit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id::text = p ->> 'booking_id' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_amount is not null and v_amount < b.deposit_cents then raise exception 'The debit deposit is at least the deposit (%)', app.fmt_money(b.deposit_cents) using errcode = '22023'; end if;
  if v_reason is null then raise exception 'Give the reason' using errcode = '22023'; end if;
  update bookings set debit_deposit_cents = v_amount, updated_at = now() where id = b.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'booking_debit_deposit', 'bookings', b.id::text, jsonb_build_object('debit_deposit_cents', b.debit_deposit_cents),
          jsonb_build_object('debit_deposit_cents', v_amount, 'reason', v_reason));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('Deposit with a debit or prepaid card: %s (%s)', coalesce(app.fmt_money(v_amount), 'the standard multiple'), v_reason), p_by, 'staff', null);
  select * into b from bookings where id = b.id;
  return jsonb_build_object('booking_id', b.id, 'debit_deposit_cents', app.debit_deposit_cents(b));
end $$;

-- the Money tab
alter function app.booking_money(uuid, jsonb) rename to booking_money_pre0262;
create function app.booking_money(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.booking_money_pre0262(p_by, p);
  b bookings;
begin
  if v is null or nullif(v ->> 'booking_id', '') is null then return v; end if;
  select * into b from bookings where id = (v ->> 'booking_id')::uuid;
  return v || jsonb_build_object('debit_deposit', case when b.deposit_cents > 0 then jsonb_build_object('cents', app.debit_deposit_cents(b),
    'multiplier', (app.settings()).debit_deposit_multiplier, 'set_by_staff', b.debit_deposit_cents is not null, 'takes', public.booking_takes_debit(b.id)) end);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0262;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'booking_debit_deposit' then
    perform app.door_begin(p_user, p_aal);
    return app.booking_debit_deposit(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0262(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare g text; f record;
begin
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    execute format('revoke all on function app.door(uuid, text, text, text, jsonb) from %I', g);
    if has_function_privilege(g, 'app.door_pre0262(uuid, text, text, text, jsonb)', 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
    execute format('revoke all on function app.booking_money(uuid, jsonb) from %I', g);
    if has_function_privilege(g, 'app.booking_money_pre0262(uuid, jsonb)', 'execute') then execute format('grant execute on function app.booking_money(uuid, jsonb) to %I', g); end if;
  end loop;
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public';
  execute 'revoke all on function app.booking_money(uuid, jsonb) from public';
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('debit_deposit_cents', 'deposit_hold_amount', 'booking_debit_deposit', 'door_pre0262', 'booking_money_pre0262'))
               or (n.nspname = 'public' and p.proname in ('server_payreq_hold_required', 'server_payreq_hold_reset', 'server_payreq_debit_deposit', 'server_booking_debit_deposit')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
