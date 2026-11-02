-- 0502: two owner bugs found on r27.
-- 1. Reopen on an expired offer sends a new one: the request goes back to "requested" (history kept: the old offer stays
--    expired, a "reopened" event is logged), the booking is re-priced as of now (lead-time pricing, current rates and
--    fees) and a new offer version is sent with a fresh expiry (program settings, offer_expiry_hours) when the pickup
--    is still ahead and the car is free; otherwise it stays a request for staff to edit and send.
-- 2. Staff can change the return of a trip after its return time while the guest still has the car (the same rule as
--    the renter's extension: app.booking_still_out, no return recorded), through Propose a change: the price is the
--    whole booking at its new length less what was charged, that is, the added time from the original return.
-- No applied migration is edited.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0502: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

create or replace function app.reopen_expired_offer(p_booking uuid, p_by uuid, p_note text default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_version integer;
begin
  perform app.reopen_expired_request(p_booking, p_by, p_note);
  select * into b from bookings where id = p_booking;
  if b.pickup_at <= now() or not app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) then
    perform app.log_booking_event(p_booking, 'adjusted', 'requested', 'requested', b.current_offer_version,
      'Reopened without a new offer: the pickup time has passed or the car is no longer free for these dates. Edit the dates and send an offer.', p_by, 'staff');
    return null;
  end if;
  perform app.reprice_booking(p_booking);
  v_version := app.send_offer(p_booking, p_by, nullif(btrim(coalesce(p_note, '')), ''), now() + make_interval(hours => (app.settings()).offer_expiry_hours));
  return v_version;
end $$;
revoke all on function app.reopen_expired_offer(uuid, uuid, text) from public, anon, authenticated;
grant execute on function app.reopen_expired_offer(uuid, uuid, text) to service_role;

select pg_temp.patch_fn('app.admin_do_0030(uuid, text, jsonb)'::regprocedure,
  $o$perform app.reopen_expired_request(b.id, p_admin, nullif(btrim(p_ ->> 'note'), ''));$o$,
  $n$perform app.reopen_expired_offer(b.id, p_admin, nullif(btrim(p_ ->> 'note'), ''));$n$);

-- a change of the return of a trip that is still out after its return time
select pg_temp.patch_fn('app.preview_booking_change(uuid, jsonb)'::regprocedure,
  $o$  if b.status <> 'confirmed' then$o$,
  $n$  if b.status <> 'confirmed' and not (b.status = 'on_rent' and app.booking_still_out(b) and ch ? 'return_at'
                                        and not (ch ? 'pickup_at') and not (ch ? 'vehicle_id')) then$n$);
