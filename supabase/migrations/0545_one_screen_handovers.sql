-- 0545: one-screen check-out and check-in, renter self check-in and self checkout, many photos at once
-- (docs/changes/2026-11-07-r28-operations.md, A2 and A3).
--
-- The owner: "renters should be able to do their own checkout. Check-in and checkout are still too complicated for
-- both parties" and "upload from camera roll, multiple at a time, not one per angle; suggested angles; ask renters to do
-- these photos; if they don't we do them; we can add onto renters' photos".
--
--   1. Photos: condition_report_photos.angle keeps the suggested angle a photo was tagged with (front, front left, ...,
--      odometer, fuel gauge, interior front, interior rear, trunk, wheels, damage), beside the report's own shot; who
--      took each stays uploaded_by. No angle is required: the angles are a checklist.
--   2. Self check-in (pickup), from the renter's booking page: one screen (photos, km, fuel, the time, now by default).
--      Kept in self_handovers. When the booking is ready to go out (signed, deposit taken, identity checked: the same
--      rules as any pickup) and km, fuel and at least one photo are given, the pickup is recorded at once as an
--      unattended handover with the renter's readings and photos on the check-out report; otherwise a To do for staff
--      ("self_handover_review") with what stopped it. Staff can review and add photos after.
--   3. Self checkout (return): the r27 "I've returned the car" form (the same component, from the booking page or the
--      overdue link). With km, fuel and at least one photo the trip is completed at once (the return recorded at the
--      renter's actual time: late charges from it), staff can still adjust after; otherwise the r27 To do. Every overdue
--      message stops either way.
--   4. Staff on one screen (app.handover_one_screen): the pickup or the return with the time, km, fuel, any photos,
--      notes; optional fields optional; the renter's own photos of the booking are added to the same report. The
--      multi-step checklist stays available but is no longer the way in.
-- No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. photos
alter table condition_report_photos add column if not exists angle text check (angle is null or angle ~ '^[a-z_]{2,30}$');
comment on column condition_report_photos.angle is 'The suggested angle the photo was tagged with (0545), when any: front, front_left, ..., odometer, fuel, interior_front, interior_rear, trunk, wheels, damage.';

create or replace function app.angle_shot(p_angle text) returns text
language sql immutable as $$
  select case p_angle
    when 'front' then 'front' when 'front_left' then 'front_left' when 'left' then 'left' when 'rear_left' then 'rear_left'
    when 'rear' then 'rear' when 'rear_right' then 'rear_right' when 'right' then 'right' when 'front_right' then 'front_right'
    when 'odometer' then 'instrument_cluster' when 'fuel' then 'instrument_cluster' when 'interior_front' then 'front_seats'
    when 'interior_rear' then 'rear_seats' when 'trunk' then 'trunk' when 'wheels' then 'wheel_front_left' else 'other' end
$$;

-- photos [{bucket, path, angle}] added to a report, after its last one; only this booking's own keys
create or replace function app.report_add_photos(p_report uuid, p_booking uuid, p_photos jsonb, p_by uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_seq integer;
  ph jsonb;
  n integer := 0;
begin
  if p_photos is null or jsonb_typeof(p_photos) <> 'array' then return 0; end if;
  select coalesce(max(seq), 0) into v_seq from condition_report_photos where condition_report_id = p_report;
  for ph in select * from jsonb_array_elements(p_photos) loop
    if ph ->> 'bucket' <> 'condition-photos' or coalesce(ph ->> 'path', '') !~ ('^bookings/' || p_booking || '/(return-claim|self-pickup|one-screen)/[0-9a-f-]{36}\.(jpg|png)$') then
      raise exception 'A photo was not uploaded for this booking' using errcode = '22023';
    end if;
    if exists (select 1 from condition_report_photos x where x.condition_report_id = p_report and x.storage_path = ph ->> 'path') then continue; end if;
    v_seq := v_seq + 1;
    insert into condition_report_photos (condition_report_id, seq, shot, angle, storage_bucket, storage_path, uploaded_by)
    values (p_report, v_seq, app.angle_shot(nullif(ph ->> 'angle', '')), nullif(ph ->> 'angle', ''), ph ->> 'bucket', ph ->> 'path', p_by);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ================================================================ 2. the renter's own check-in and checkout
create table if not exists self_handovers (
  id                  uuid primary key default gen_random_uuid(),
  booking_id          uuid not null references bookings (id) on delete cascade,
  kind                text not null check (kind in ('pickup', 'return')),
  submitted_by        uuid references users (id) on delete set null,
  submitted_at        timestamptz not null default now(),
  at                  timestamptz not null,
  odometer_km         integer check (odometer_km >= 0),
  fuel_pct            smallint check (fuel_pct between 0 and 100),
  note                text check (char_length(note) <= 1000),
  photos              jsonb not null default '[]'::jsonb check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 40),
  status              text not null default 'review' check (status in ('applied', 'review')),
  reason              text,
  condition_report_id uuid references condition_reports (id) on delete set null
);
create index if not exists self_handovers_booking on self_handovers (booking_id, submitted_at desc);
alter table self_handovers enable row level security;
create policy admin_all on self_handovers for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_self_handovers after insert or update or delete on self_handovers for each row execute function app.audit_row();
comment on table self_handovers is 'A renter''s own check-in (pickup) or checkout (return) from the booking page (0545): applied at once when complete and allowed, else reviewed by staff.';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, description)
values ('self_handover_review', 'fleet', 'The renter checked the car in or out themselves: review it', 'high', 'none', 0, 1,
        'A renter''s own pickup or return (0545) that could not be recorded by itself: record it on one screen with their photos and readings, or call them.')
on conflict (task_type) do nothing;

-- the renter acts as the one who hands over, inside these functions only (the handover's own checks still apply)
alter function app.user_may_handover(uuid) rename to user_may_handover_pre0545;
create function app.user_may_handover(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_may_handover_pre0545(p_user)
      or (p_user is not null and coalesce(current_setting('app.self_handover_by', true), '') = p_user::text)
$$;
select pg_temp.copy_grants('app.user_may_handover(uuid)'::regprocedure, 'app.user_may_handover_pre0545(uuid)'::regprocedure);

-- complete when km, fuel and at least one photo are there
create or replace function app.handover_complete_enough(p_km integer, p_fuel integer, p_photos jsonb) returns boolean
language sql immutable as $$ select p_km is not null and p_fuel is not null and jsonb_array_length(coalesce(p_photos, '[]'::jsonb)) > 0 $$;

-- what record now leaves behind when the report is complete: no "add the details" To do, the report done
create or replace function app.handover_settle_report(p_report uuid, p_by uuid, p_complete boolean, p_note text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_complete then
    update condition_reports set details_pending = false, completed_at = coalesce(completed_at, now()), completed_by = coalesce(completed_by, p_by),
           notes = left(concat_ws(' ', notes, p_note), 4000)
     where id = p_report;
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Recorded on one screen with the readings and photos'
     where task_type = 'handover_details' and related_table = 'condition_reports' and related_id = p_report and status in ('open', 'in_progress', 'waiting');
  elsif p_note is not null then
    update condition_reports set notes = left(concat_ws(' ', notes, p_note), 4000) where id = p_report;
  end if;
end $$;

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
  if now() < b.pickup_at - interval '3 hours' then raise exception 'Check in when you pick the car up (from 3 hours before the pickup time)' using errcode = '23514'; end if;
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

-- the renter's checkout: complete with km, fuel and photos, the trip is completed at once (r27's report otherwise)
alter function public.server_return_claim_submit(uuid, jsonb, uuid) rename to server_return_claim_submit_pre0545;
create function public.server_return_claim_submit(p_token uuid, p jsonb, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
  c return_claims;
  b bookings;
  r jsonb;
begin
  -- the angles ride along on the photos; r27 keeps bucket and path only
  v := public.server_return_claim_submit_pre0545(p_token, p, p_user);
  if v ->> 'status' <> 'pending' or (v ->> 'claim_id') is null then return v; end if;
  select * into c from return_claims where id = (v ->> 'claim_id')::uuid;
  select * into b from bookings where id = c.booking_id;
  if b.status <> 'on_rent' or not app.handover_complete_enough(c.odometer_km, c.fuel_pct, c.photos) then return v; end if;
  begin
    perform set_config('app.self_handover_by', coalesce(p_user, (select r2.user_id from renters r2 where r2.id = b.renter_id))::text, true);
    r := app.return_claim_decide(coalesce(p_user, (select r2.user_id from renters r2 where r2.id = b.renter_id)),
           jsonb_build_object('booking', b.id, 'decision', 'confirm', 'reason', 'Self checkout by the renter with the odometer, fuel and photos (completed automatically; staff may adjust)'));
    perform set_config('app.self_handover_by', '', true);
    -- the angles the renter tagged
    update condition_report_photos x set angle = nullif(ph ->> 'angle', ''), shot = app.angle_shot(nullif(ph ->> 'angle', ''))
      from jsonb_array_elements(coalesce(p -> 'photos', '[]'::jsonb)) ph
     where x.condition_report_id = (r ->> 'report_id')::uuid and x.storage_path = ph ->> 'path' and coalesce(ph ->> 'angle', '') <> '';
    perform app.handover_settle_report((r ->> 'report_id')::uuid, p_user, true, null);
    insert into self_handovers (booking_id, kind, submitted_by, at, odometer_km, fuel_pct, note, photos, status, condition_report_id)
    values (b.id, 'return', p_user, coalesce(c.returned_at, now()), c.odometer_km, c.fuel_pct, c.note, c.photos, 'applied', (r ->> 'report_id')::uuid);
    return jsonb_build_object('status', 'completed', 'claim_id', c.id, 'booking_status', (select status from bookings where id = b.id));
  exception when others then
    perform set_config('app.self_handover_by', '', true);
    raise warning '0545 self checkout of %: %', b.booking_number, sqlerrm;
    return v;
  end;
end $$;
select pg_temp.copy_grants('public.server_return_claim_submit(uuid, jsonb, uuid)'::regprocedure, 'public.server_return_claim_submit_pre0545(uuid, jsonb, uuid)'::regprocedure);

-- ================================================================ 3. staff on one screen
create or replace function app.handover_one_screen(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_kind text := p ->> 'kind';
  v_km integer := nullif(p ->> 'odometer_km', '')::numeric::integer;
  v_fuel integer := nullif(p ->> 'fuel_pct', '')::numeric::integer;
  v_photos jsonb := coalesce(p -> 'photos', '[]'::jsonb);
  v_renter jsonb := '[]'::jsonb;
  r jsonb;
  c condition_reports;
  v_note text := nullif(left(btrim(coalesce(p ->> 'note', '')), 1000), '');
  v_n integer;
begin
  if not app.user_may_handover(p_by) then raise exception 'Only an Admin, Fleet, Sales, Customer service or field staff record a check-out or check-in' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_kind not in ('pickup', 'return') then raise exception 'Record the pickup or the return' using errcode = '22023'; end if;
  select * into c from condition_reports where booking_id = b.id and kind = v_kind;
  if c.completed_at is not null then
    -- already recorded: the photos and readings are added to its report (staff add onto the renter's set)
    perform app.report_add_photos(c.id, b.id, v_photos, p_by);
    update condition_reports set odometer_km = coalesce(odometer_km, v_km), fuel_pct = coalesce(fuel_pct, v_fuel::smallint),
           notes = case when v_note is null then notes else left(concat_ws(' ', notes, v_note), 4000) end where id = c.id;
    return jsonb_build_object('report_id', c.id, 'added', true, 'booking_status', b.status);
  end if;
  r := app.handover_record_now(p_by, (p - 'photos' - 'note') || jsonb_build_object('reason', coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), 'Recorded on one screen')));
  v_n := app.report_add_photos((r ->> 'report_id')::uuid, b.id, v_photos, p_by);
  -- the renter's own photos of the same moment join the report
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_renter
    from self_handovers s, jsonb_array_elements(s.photos) x where s.booking_id = b.id and s.kind = v_kind and s.status = 'review';
  if jsonb_array_length(v_renter) > 0 then
    perform app.report_add_photos((r ->> 'report_id')::uuid, b.id, v_renter, (select submitted_by from self_handovers where booking_id = b.id and kind = v_kind order by submitted_at desc limit 1));
    update self_handovers set status = 'applied', condition_report_id = (r ->> 'report_id')::uuid where booking_id = b.id and kind = v_kind and status = 'review';
    perform app.resolve_tasks(array['self_handover_review'], b.id, p_by, 'Recorded on one screen with the renter''s photos');
  end if;
  perform app.handover_settle_report((r ->> 'report_id')::uuid, p_by, app.handover_complete_enough(v_km, v_fuel, v_photos || v_renter), v_note);
  return r || jsonb_build_object('photos', v_n + jsonb_array_length(v_renter));
end $$;

create or replace function app.self_handover_view(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'kind', s.kind, 'at', s.at, 'submitted_at', s.submitted_at, 'odometer_km', s.odometer_km, 'fuel_pct', s.fuel_pct,
           'note', s.note, 'photos', jsonb_array_length(s.photos), 'status', s.status, 'reason', s.reason) order by s.submitted_at desc), '[]'::jsonb)
    from self_handovers s where s.booking_id = p_booking
$$;

revoke all on function app.angle_shot(text), app.report_add_photos(uuid, uuid, jsonb, uuid), app.handover_complete_enough(integer, integer, jsonb),
  app.handover_settle_report(uuid, uuid, boolean, text), app.self_handover_submit(uuid, jsonb), app.handover_one_screen(uuid, jsonb), app.self_handover_view(uuid)
  from public, anon, authenticated;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0545;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'admin_do') and p_name = 'handover_one_screen' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.handover_one_screen(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'ops_read' and p_name = 'self_handovers' then
    perform app.door_begin(p_user, p_aal);
    if not app.user_may_handover(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.self_handover_view((select id from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1));
  end if;
  return app.door_pre0545(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0545(uuid, text, text, text, jsonb)'::regprocedure);

-- the renter's own check-in, through the server (the session's user)
create or replace function public.server_self_handover_submit(p_user uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.self_handover_submit(p_user, p) $$;
revoke all on function public.server_self_handover_submit(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.server_self_handover_submit(uuid, jsonb) to service_role;
