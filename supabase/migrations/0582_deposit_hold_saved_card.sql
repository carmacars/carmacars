-- 0582_deposit_hold_saved_card.sql
-- Release 29, C0 (docs/changes/2026-11-06-booking-money-tab.md): the booking's Money tab in two panels, Rental charges and
-- Security deposit. The one backend gap: "Collect $X deposit" with the card on file. The pickup-day job (0261) placed a
-- hold on the saved card by itself only; staff could send a deposit link or charge the deposit, not hold it now on the
-- card on file. ops_do deposit_hold_saved_begin makes the same one-request-per-booking hold request (a deposit only, never
-- the rental), the server places the hold with Stripe (manual capture) and records it as every hold (server_payreq_settle);
-- a refusal is recorded on the request (deposit_hold_saved_failed) and said on the screen. Finance or an Admin.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

create or replace function app.deposit_hold_saved_begin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c jsonb;
  v_amount bigint;
  q payment_requests;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin holds the deposit on the card on file' using errcode = '42501'; end if;
  if nullif(p ->> 'token_sha256', '') is null or p ->> 'token_sha256' !~ '^[0-9a-f]{64}$' then raise exception 'The token is missing' using errcode = '22023'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status not in ('pending_payment', 'confirmed', 'on_rent') then raise exception 'A deposit is taken for a booking that is confirmed or on the road' using errcode = '23514'; end if;
  if coalesce(b.deposit_cents, 0) <= 0 then raise exception 'This booking has no deposit to take' using errcode = '23514'; end if;
  if exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured', 'settled')) then
    raise exception 'The deposit on % is already taken', b.booking_number using errcode = '23514';
  end if;
  c := app.deposit_auto_card(b);
  if c is null or c ->> 'customer_id' is null then raise exception 'No card is saved for this renter: send the deposit link instead' using errcode = '23514'; end if;
  if not app.booking_card_ok(b.id, jsonb_build_object('funding', c ->> 'funding')) then
    raise exception 'The card on file is a % card and this booking needs a credit card: send the deposit link, or allow debit cards for this booking', coalesce(nullif(c ->> 'funding', 'unknown'), 'non-credit') using errcode = '23514';
  end if;
  -- one open deposit request per booking: an older one (a link, the pickup-day try) is replaced
  update payment_requests set status = 'cancelled', completed_at = now(), last_error = 'Replaced: the deposit was held on the card on file'
   where booking_id = b.id and kind = 'hold' and covers = 'deposit' and status = 'open';
  v_amount := app.deposit_hold_amount(b, coalesce(c ->> 'funding', 'credit'));
  insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, reason, token_sha256, channel, expires_at, created_by, auto, status)
  values (b.id, b.renter_id, 'hold', 'deposit', v_amount, 'Deposit hold on the card on file', p ->> 'token_sha256', 'auto', now() + interval '1 day', p_by, false, 'open')
  returning * into q;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('Deposit hold of %s on the card on file asked by staff.', app.fmt_money(v_amount)), p_by, 'staff', jsonb_build_object('payment_request_id', q.id));
  return jsonb_build_object('ok', true, 'id', q.id, 'booking_id', b.id, 'booking_number', b.booking_number, 'amount_cents', v_amount,
    'customer_id', c ->> 'customer_id', 'method_id', c ->> 'method_id', 'card', jsonb_build_object('brand', c ->> 'brand', 'last4', c ->> 'last4', 'funding', c ->> 'funding'));
end $$;

create or replace function app.deposit_hold_saved_failed(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare q payment_requests;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into q from payment_requests where id = (p ->> 'id')::uuid for update;
  if q.id is null or q.kind <> 'hold' or q.covers <> 'deposit' or q.created_by is distinct from p_by then raise exception 'Not a deposit hold you asked for' using errcode = '22023'; end if;
  if q.status <> 'open' then return jsonb_build_object('ok', true, 'status', q.status); end if;
  update payment_requests set status = 'failed', last_error = left(coalesce(nullif(btrim(p ->> 'error'), ''), 'the card was declined'), 300), completed_at = now() where id = q.id;
  return jsonb_build_object('ok', true, 'status', 'failed');
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0582;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'ops_do' and p_name in ('deposit_hold_saved_begin', 'deposit_hold_saved_failed') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'deposit_hold_saved_begin' then app.deposit_hold_saved_begin(p_user, v) else app.deposit_hold_saved_failed(p_user, v) end;
  end if;
  return app.door_pre0582(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0582(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.deposit_hold_saved_begin(uuid, jsonb), app.deposit_hold_saved_failed(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.deposit_hold_saved_begin(uuid, jsonb), app.deposit_hold_saved_failed(uuid, jsonb) to service_role;
