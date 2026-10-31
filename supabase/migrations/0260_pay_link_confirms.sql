-- 0260: a payment staff take through a pay link (or by charging the saved card) moves the booking on like the renter's
-- pay page (docs/changes/2026-11-04-pay-link-confirms.md).
--
-- Live case: booking CC-10053 was waiting for payment (offer approved, agreement signed by the renter). Staff texted a pay
-- link for "Everything open" (payment_requests.covers 'balance'); the renter paid it, every part was then $0 open and the
-- card was saved, but the booking stayed pending_payment: 0129's confirmation after a pay link only looked at a payment
-- of the rental or of the fees, never of the balance (added by 0139), and the history line called it "later charges".
--
-- 1. app.confirm_when_paid(booking, by): the one confirmation of a booking paid in full. On a booking waiting for payment
--    whose current offer is approved and with nothing open for the rental and the fees, it runs the confirmation staff
--    run by hand (app.confirm_offline_booking: the car checked free, status confirmed, CarmaCars countersigns a signed
--    agreement, the confirmation messages and the calendar follow the status as on the pay page). Anything else: nothing.
--    It runs once: once confirmed, the booking is no longer waiting for payment.
-- 2. It runs after a pay link charge of the rental, the fees or the balance (public.server_payreq_settle), and after a
--    charge of the saved card for the rental or the fees (app.card_charge_finish). The payment of a balance counts for the
--    booking total (purpose booking_total, the rental first then the fees), as before; its history line says so.
-- 3. A booking that is already stuck (paid in full by a pay link, approved, still waiting for payment) is confirmed now.
-- No applied migration is edited.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0260: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- the confirmation staff run by hand also runs for a payment the system recorded (no staff member pressed Confirm)
select pg_temp.patch_fn('app.confirm_offline_booking(uuid, uuid, boolean)'::regprocedure,
  $o$  if app.offer_role(p_by) is null and not app.user_runs_finance(p_by) then raise exception$o$,
  $n$  if app.offer_role(p_by) is null and not app.user_runs_finance(p_by)
     and coalesce(current_setting('app.confirm_paid', true), '') is distinct from p_booking::text then raise exception$n$);

-- ================================================================ 1. the one confirmation of a booking paid in full
create or replace function app.confirm_when_paid(p_booking uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.status <> 'pending_payment' or b.booking_type = 'owner'
     or b.offer_approved_version is null or b.offer_approved_version is distinct from b.current_offer_version then
    return null;
  end if;
  if app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees') > 0 then return null; end if;
  perform set_config('app.confirm_paid', b.id::text, true);
  v := app.confirm_offline_booking(p_by, b.id, false);
  perform set_config('app.confirm_paid', '', true);
  -- the renter's signed copy, as after the pay page (a background job)
  if coalesce((v ->> 'ok')::boolean, false) and not coalesce((v ->> 'awaiting_signature')::boolean, false) then
    perform app.pdf_jobs_enqueue(jsonb_build_array(jsonb_build_object('kind', 'renter_signed_copy', 'ref', b.id,
      'user_id', (select r.user_id from renters r where r.id = b.renter_id))));
  end if;
  return v;
end $$;
revoke all on function app.confirm_when_paid(uuid, uuid) from public, anon, authenticated;
grant execute on function app.confirm_when_paid(uuid, uuid) to service_role;

-- ================================================================ 2. after a pay link, after a charge of the saved card
-- the history line of a balance payment (it was "for the later charges")
select pg_temp.patch_fn('public.server_payreq_settle_pre0202(uuid, jsonb)'::regprocedure,
  $o$case q.covers when 'rental' then 'rental' when 'fees' then 'fees' else 'later charges' end$o$,
  $n$case q.covers when 'rental' then 'rental' when 'fees' then 'fees' when 'balance' then 'booking (everything open)' else 'later charges' end$n$);

alter function public.server_payreq_settle(uuid, jsonb) rename to server_payreq_settle_pre0260;
create function public.server_payreq_settle(p_id uuid, p_intent jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q payment_requests;
  v_out jsonb := public.server_payreq_settle_pre0260(p_id, p_intent);
  v_conf jsonb;
begin
  select * into q from payment_requests where id = p_id;
  if q.kind = 'charge' and q.covers in ('rental', 'fees', 'balance') and q.status = 'paid' and coalesce((v_out ->> 'ok')::boolean, false) then
    v_conf := app.confirm_when_paid(q.booking_id, q.created_by);
    if v_conf is not null then v_out := v_out || jsonb_build_object('confirm', v_conf); end if;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('public.server_payreq_settle(uuid, jsonb)'::regprocedure, 'public.server_payreq_settle_pre0260(uuid, jsonb)'::regprocedure);

alter function app.card_charge_finish(uuid, jsonb) rename to card_charge_finish_pre0260;
create function app.card_charge_finish(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.card_charge_finish_pre0260(p_by, p);
  pay payments;
  v_conf jsonb;
begin
  select * into pay from payments where id = (p ->> 'payment')::uuid;
  if pay.purpose = 'booking_total' and pay.status = 'succeeded' and coalesce((v_out ->> 'ok')::boolean, false) and v_out ->> 'repeat' is null then
    v_conf := app.confirm_when_paid(pay.booking_id, p_by);
    if v_conf is not null then v_out := v_out || jsonb_build_object('confirm', v_conf); end if;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.card_charge_finish(uuid, jsonb)'::regprocedure, 'app.card_charge_finish_pre0260(uuid, jsonb)'::regprocedure);

-- ================================================================ 3. the bookings already stuck
do $$
declare r record;
begin
  for r in select distinct b.id, q.created_by from bookings b join payment_requests q on q.booking_id = b.id
            where b.status = 'pending_payment' and q.kind = 'charge' and q.covers in ('rental', 'fees', 'balance') and q.status = 'paid'
              and b.pickup_at > now() - interval '7 days' loop
    perform app.confirm_when_paid(r.id, r.created_by);
  end loop;
end $$;
