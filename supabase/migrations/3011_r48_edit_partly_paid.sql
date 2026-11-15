-- 3011 (release 48): the car and the dates of a booking that is partly paid but not yet confirmed can be changed, with
-- its price and its payments kept (docs/changes/2026-11-14-r48-edit-partly-paid.md).
--
-- Before: Edit the offer refused it ("has a payment for its total already") and Edit booking refused it ("not confirmed
-- yet"), so a booking waiting for the rest of its payment (a payment plan's first instalment paid, a deposit of the
-- rental taken by e-Transfer) could not move to another car. Now:
--   1. app.booking_edit_refusal: a booking waiting for payment with a payment of its total is edited like a confirmed
--      one (Edit booking, the same roles; the connector's change_booking runs the same step). A booking waiting for
--      payment with nothing paid still changes through Edit the offer.
--   2. app.booking_staff_edit (its body, _pre1066): on such a booking the new car, and the new dates, are checked free
--      (the car is held for it while it waits for payment); the car changes with the price as it is, the dates are
--      priced at the booking's own rates as for a confirmed booking, and every payment stays recorded.
--      The offer's terms otherwise stand still while it is out (app.booking_before_write): only this edit, on such a
--      booking, passes (a session mark for the length of the edit).
--   3. app.offer_reopen_for_edit: its refusal says where to go instead.
-- No applied migration is edited: the functions are patched (pg_temp.patch_fn).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '3011: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

create or replace function app.booking_partly_paid(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from bookings b where b.id = p_booking and b.status = 'pending_payment')
     and exists (select 1 from payments x where x.booking_id = p_booking and x.purpose = 'booking_total' and x.kind = 'charge' and x.status = 'succeeded')
$$;
comment on function app.booking_partly_paid(uuid) is '3011: waiting for payment with a payment of its total already: edited with Edit booking (the car, the dates), not by reopening the offer.';
revoke all on function app.booking_partly_paid(uuid) from public, anon, authenticated;
grant execute on function app.booking_partly_paid(uuid) to service_role;

-- ================================================================ 1. who may edit
select pg_temp.patch_fn('app.booking_edit_refusal(uuid, bookings)'::regprocedure,
  $o$    when b.status::text in ('requested', 'offered', 'pending_payment', 'tentative') then$o$,
  $n$    when b.status::text in ('requested', 'offered', 'pending_payment', 'tentative') and not app.booking_partly_paid(b.id) then$n$);

-- ================================================================ 2. the car and the dates checked free
select pg_temp.patch_fn('app.booking_staff_edit_pre1066(uuid, jsonb)'::regprocedure,
  $o$    if b.status::text in ('confirmed', 'on_rent') and not app.vehicle_is_available(v_car,$o$,
  $n$    if b.status::text in ('confirmed', 'on_rent', 'pending_payment') and not app.vehicle_is_available(v_car,$n$);
select pg_temp.patch_fn('app.booking_staff_edit_pre1066(uuid, jsonb)'::regprocedure,
  $o$  if c ? 'km_allowance_per_day' then$o$,
  $n$  -- 3011: a booking waiting for payment holds its car: the new dates are checked free for it
  if b.status::text = 'pending_payment' and b.blocks_calendar and (v_from <> b0.pickup_at or v_to <> b0.return_at)
     and not app.vehicle_is_available(coalesce(v_car, b0.vehicle_id), v_from, v_to, b.id) then
    raise exception '% is not free for the new dates', app.vehicle_name(coalesce(v_car, b0.vehicle_id)) using errcode = '23P01';
  end if;
  if c ? 'km_allowance_per_day' then$n$);

-- the offer's terms stand still while it is out (app.booking_before_write); this edit, on a booking partly paid, is
-- the one exception: the session marks the booking for the length of the edit
select pg_temp.patch_fn('app.booking_staff_edit_pre1066(uuid, jsonb)'::regprocedure,
  $o$  v_before := app.booking_snapshot(b.id);$o$,
  $n$  v_before := app.booking_snapshot(b.id);
  if app.booking_partly_paid(b.id) then perform set_config('app.partly_paid_edit', b.id::text, true); end if;$n$);
select pg_temp.patch_fn('app.booking_staff_edit_pre1066(uuid, jsonb)'::regprocedure,
  $o$  select * into b from bookings where id = b.id;
  v_after$o$,
  $n$  perform set_config('app.partly_paid_edit', '', true);
  select * into b from bookings where id = b.id;
  v_after$n$);
select pg_temp.patch_fn('app.booking_before_write()'::regprocedure,
  $o$  if old.status in ('offered', 'pending_payment') and new.status = old.status and old.current_offer_version is not null$o$,
  $n$  if old.status in ('offered', 'pending_payment') and new.status = old.status and old.current_offer_version is not null
     and coalesce(current_setting('app.partly_paid_edit', true), '') is distinct from old.id::text$n$);

-- ================================================================ 3. the offer's refusal
select pg_temp.patch_fn('app.offer_reopen_for_edit(uuid, uuid, boolean)'::regprocedure,
  $o$'Booking % has a payment for its total already: change it with a booking change after it is confirmed, or refund first'$o$,
  $n$'Booking % has a payment already: change the car or the dates with Edit booking on its page (the price and the payments stay), or refund first'$n$);
