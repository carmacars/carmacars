-- Hotfix (Nov 11): the renter's own check-in is offered from 24 hours before pickup on the booking page, but the
-- database refused it until 3 hours before. The window now matches the page (24 hours).

create or replace function app.self_handover_submit(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s self_handovers;
  v_kind text := p ->> 'kind';
  v_at timestamptz := least(coalesce(nullif(p ->> 'at', '')::timestamptz, now()), now());
  v_km integer := nullif(p ->> 'odometer_km', '')::numeric::integer;
  v_fuel integer := nullif(p ->> 'fuel_pct', '')::numeric::integer;
  v_photos jsonb := coalesce(p -> 'photos', '[]'::jsonb);
  r jsonb;
  v_err text;
  v_task uuid;
begin
  select * into b from bookings where (id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')))) for update;
  if b.id is null or not coalesce(app.is_booking_renter(b.id, p_user), false) then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_kind <> 'pickup' then raise exception 'Use the return form for the return' using errcode = '22023'; end if;
  if b.status not in ('pending_payment', 'confirmed') then raise exception 'Booking % is %: there is no pickup to check in', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514'; end if;
  if now() < b.pickup_at - interval '24 hours' then raise exception 'Check in when you pick the car up (from 24 hours before the pickup time)' using errcode = '23514'; end if;
  if v_km is not null and (v_km < 0 or v_km > 2000000) then raise exception 'Check the odometer reading' using errcode = '22023'; end if;
  if v_fuel is not null and v_fuel not between 0 and 100 then raise exception 'The fuel level is 0 to 100%%' using errcode = '22023'; end if;
  if jsonb_typeof(v_photos) <> 'array' or jsonb_array_length(v_photos) > 40 then raise exception 'Up to 40 photos' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(v_photos) x where x ->> 'bucket' <> 'condition-photos'
               or coalesce(x ->> 'path', '') !~ ('^bookings/' || b.id || '/self-pickup/[0-9a-f-]{36}\.(jpg|png)$')) then
    raise exception 'A photo was not uploaded for this booking' using errcode = '22023';
  end if;
  insert into self_handovers (booking_id, kind, submitted_by, at, odometer_km, fuel_pct, note, photos)
  values (b.id, 'pickup', p_user, v_at, v_km, v_fuel::smallint, nullif(left(btrim(coalesce(p ->> 'note', '')), 1000), ''), v_photos)
  returning * into s;

  if b.status = 'confirmed' and app.handover_complete_enough(v_km, v_fuel, v_photos) then
    begin
      perform set_config('app.self_handover_by', p_user::text, true);
      update bookings set unattended_handover = true where id = b.id and not coalesce(unattended_handover, false);
      r := app.handover_record_now(p_user, jsonb_build_object('booking', b.id, 'kind', 'pickup', 'at', v_at, 'odometer_km', v_km, 'fuel_pct', v_fuel,
             'reason', 'Self check-in by the renter from the booking page'));
      perform app.report_add_photos((r ->> 'report_id')::uuid, b.id, v_photos, p_user);
      perform app.handover_settle_report((r ->> 'report_id')::uuid, p_user, true, format('Self check-in by the renter (%s): odometer %s km, fuel %s%%, %s photos.', app.fmt_at(v_at), v_km, v_fuel, jsonb_array_length(v_photos)));
      perform set_config('app.self_handover_by', '', true);
      update self_handovers set status = 'applied', condition_report_id = (r ->> 'report_id')::uuid where id = s.id;
      return jsonb_build_object('status', 'applied', 'booking_status', (select status from bookings where id = b.id));
    exception when others then
      v_err := sqlerrm;
      perform set_config('app.self_handover_by', '', true);
    end;
  end if;
  v_err := coalesce(v_err, case when b.status <> 'confirmed' then 'the booking is not confirmed yet (payment due)'
                                else 'the odometer, the fuel level or the photos are missing' end);
  v_task := app.raise_task(p_type => 'self_handover_review',
    p_title => left(format('%s: the renter checked the car out themselves', b.booking_number), 200),
    p_detail => left(format('At %s. Odometer: %s. Fuel: %s. Photos: %s. Not recorded by itself: %s. Record the pickup on one screen (their photos are added), or call them.',
                  app.fmt_at(v_at), coalesce(v_km || ' km', 'not given'), coalesce(v_fuel || '%', 'not given'), jsonb_array_length(v_photos), v_err), 2000),
    p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_related_table => 'self_handovers', p_related_id => s.id, p_dedupe => 'self_handover:' || s.id);
  update self_handovers set status = 'review', reason = v_err where id = s.id;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('The renter checked the car out themselves (%s); staff review it: %s', app.fmt_at(v_at), v_err), p_user, 'renter', jsonb_build_object('self_handover_id', s.id, 'task_id', v_task));
  return jsonb_build_object('status', 'review', 'reason', v_err);
end $$;
