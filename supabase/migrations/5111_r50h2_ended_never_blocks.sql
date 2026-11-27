-- 5111 (r50 hotfix2): an ended booking never blocks a car's calendar. 3810 made a confirmed booking whose pickup was never
-- recorded keep its car "presumed out" after its return time, with no end: the owner could not send an offer on the car
-- (it showed Sending, then Send the offer again) until he stopped that booking blocking the calendar by hand. Bookings
-- block only their own dates again (vehicle_is_available before 3810); a returned, closed, cancelled or no-show booking
-- never blocks (it never did). The To dos stay: Fleet, then the Admins, are asked to record the handover, the return or a
-- no-show (app.job_presumed_out), and the conflicts list still names such a booking, as a note that does not block.

create or replace function app.vehicle_is_available(p_vehicle uuid, p_from timestamptz, p_to timestamptz, p_ignore_booking uuid default null) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.vehicle_is_available_pre3810(p_vehicle, p_from, p_to, p_ignore_booking)
$$;

create or replace function app.booking_date_conflicts(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.booking_date_conflicts_pre3810(p_booking);
  b bookings;
  o bookings;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.return_at <= now() then return v; end if;
  o := app.vehicle_presumed_out(b.vehicle_id, b.id);
  if o.id is null or exists (select 1 from jsonb_array_elements(v) x where x ->> 'id' = o.id::text) then return v; end if;
  return v || jsonb_build_array(jsonb_build_object('type', 'booking', 'id', o.id, 'booking_number', o.booking_number, 'status', o.status,
    'pickup_at', o.pickup_at, 'return_at', o.return_at, 'starts_at', o.pickup_at, 'ends_at', o.return_at, 'kind', 'presumed_out', 'placeholder', false,
    'holds', false, 'blocks', false, 'note', 'Ended, but its pickup was never recorded: record the handover and the return, or a no-show (it does not block this car)',
    'renter', (select split_part(btrim(r.legal_name), ' ', 1) from renters r where r.id = o.renter_id)));
end $$;
