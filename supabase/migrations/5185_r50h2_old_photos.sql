-- 5185 (R50 hotfix 2): "Add old photos". The owner (Nov 27): field staff have phone photos of earlier check-ins and
-- check-outs they could not upload because of bugs, and they cannot even see those past bookings (2815's list shows a
-- field staff member only the bookings they handled or were given, and only the ones with no report).
--   * program_settings.old_photos_days (60): how far back the list goes. old_photos_match_hours (12): how far from a
--     pickup or return a photo's capture time may be for the bulk suggestion. old_photos_group_minutes (30): photos taken
--     this close together are one group in the bulk flow.
--   * old_photos_plate_daily (30): plate reads one person may ask for a day, so the shared plate_detect allowance is not
--     drained. provider_calls.created_by: who asked for a recorded read.
--   * condition_report_photos.added_later_at: set on a photo added afterwards (the report says "Added later by <name>"),
--     client_key: the phone's id of the upload, so a retry on a bad signal never adds the photo twice.
--   * app.old_photo_bookings: every past booking (out, returned or closed) whose pickup or return is within the window,
--     whoever handled it, searchable by plate, car, renter or number, newest first. Admin, Fleet, customer service and
--     field staff.
--   * app.old_photo_gate: before the bytes are stored, the person may add photos to that check-in or check-out, and
--     whether this upload is already attached.
--   * app.old_photo_attach: one photo on the booking's check-in (pickup) or check-out (return) report, shot 'other' (the
--     photo standard and the plate cover never take a photo whose angle nobody checked), capture time kept. A booking with
--     no report gets one made "details later" as 2815 does (who, when, "Added after the trip"), so the readings still show
--     as missing. No renter or owner notice: no booking status changes, the log line is an internal 'adjusted' event.
--   * app.old_photo_suggest: for groups of photos (capture time span, and the plate read from one of them if any), the
--     check-in or check-out nearest in time, on the car with that plate when it was read.
-- Tests: supabase/tests/99_r50h2_old_photos.sql. No applied migration is edited.

alter table program_settings
  add column old_photos_days integer not null default 60 check (old_photos_days between 1 and 400),
  add column old_photos_match_hours integer not null default 12 check (old_photos_match_hours between 1 and 72),
  add column old_photos_group_minutes integer not null default 30 check (old_photos_group_minutes between 1 and 240),
  add column old_photos_plate_daily integer not null default 30 check (old_photos_plate_daily between 1 and 500);
comment on column program_settings.old_photos_days is 'Add old photos: how far back the past bookings go, in days (5185)';
comment on column program_settings.old_photos_match_hours is 'Add old photos: hours from a pickup or return within which a photo is suggested for it (5185)';
comment on column program_settings.old_photos_group_minutes is 'Add old photos: photos taken within this many minutes of each other are one group (5185)';
comment on column program_settings.old_photos_plate_daily is 'Add old photos: plate reads one person may ask for in a day (Toronto time) (5185)';

alter table provider_calls add column created_by uuid references users (id);
comment on column provider_calls.created_by is 'Who asked for the call, when a person did (the Add old photos plate read, 5185)';
create index provider_calls_plate_user_idx on provider_calls (created_by, created_at) where purpose = 'plate_detect';

alter table condition_report_photos
  add column added_later_at timestamptz,
  add column client_key uuid;
comment on column condition_report_photos.added_later_at is 'When the photo was added after the check-in or check-out (Add old photos, 5185); uploaded_by is who';
comment on column condition_report_photos.client_key is 'The phone''s id of the upload: a retried upload is attached once (5185)';
create unique index condition_report_photos_client_key on condition_report_photos (condition_report_id, client_key) where client_key is not null;

-- a photo added later never shows to an owner (or a renter) through a browser session: staff and field staff only
create policy added_later_staff_only on condition_report_photos as restrictive for select to authenticated
  using (added_later_at is null or app.is_staff() or app.is_field());

-- who adds old photos: an Admin, Fleet, customer service or field staff
create function app.old_photos_may(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(app.user_is_admin(p_by), false) or coalesce(app.user_va_has(p_by, 'fleet', 'cs'), false) or coalesce(app.user_is_field(p_by), false)
$$;

-- when a booking's check-in (pickup) or check-out (return) happened
create function app.old_photo_at(b bookings, p_kind text) returns timestamptz
language sql stable set search_path = public, app, pg_temp as $$
  select case p_kind when 'pickup' then coalesce(b.handed_over_at, b.pickup_at) when 'return' then coalesce(b.checked_in_at, b.return_at) end
$$;

-- that check-in or check-out is past and inside the window
create function app.old_photo_ok(b bookings, p_kind text) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select b.id is not null and app.handover_past_stage(b, p_kind)
     and app.old_photo_at(b, p_kind) >= now() - make_interval(days => coalesce((app.settings()).old_photos_days, 60))
$$;

create function app.old_photo_plate(p text) returns text
language sql immutable set search_path = public, app, pg_temp as $$ select nullif(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')), '') $$;

create function app.old_photo_booking(p_by uuid, p jsonb) returns bookings
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  v_kind text := p ->> 'kind';
begin
  if not app.old_photos_may(p_by) then raise exception 'Only an Admin, Fleet, customer service or field staff add old photos' using errcode = '42501'; end if;
  select * into b from bookings where id::text = coalesce(p ->> 'booking', '') or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_kind is null or v_kind not in ('pickup', 'return') then raise exception 'Choose the check-in or the check-out' using errcode = '22023'; end if;
  if not app.old_photo_ok(b, v_kind) then
    raise exception 'Booking % has no % in the last % days', b.booking_number, case v_kind when 'pickup' then 'check-in' else 'check-out' end,
      coalesce((app.settings()).old_photos_days, 60) using errcode = '23514';
  end if;
  return b;
end $$;

-- the list: every past booking in the window, whoever handled it, newest first
create function app.old_photo_bookings(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_q text := nullif(btrim(coalesce(p ->> 'q', '')), '');
  v_plate text := app.old_photo_plate(p ->> 'q');
  v_since timestamptz := now() - make_interval(days => coalesce((app.settings()).old_photos_days, 60));
begin
  if not app.old_photos_may(p_by) then raise exception 'Only an Admin, Fleet, customer service or field staff add old photos' using errcode = '42501'; end if;
  return jsonb_build_object('days', coalesce((app.settings()).old_photos_days, 60), 'group_minutes', coalesce((app.settings()).old_photos_group_minutes, 30), 'rows', coalesce((select jsonb_agg(x.j order by x.at desc, x.n) from (
    select b.booking_number n, greatest(case when app.old_photo_ok(b, 'pickup') then app.old_photo_at(b, 'pickup') end,
                                        case when app.old_photo_ok(b, 'return') then app.old_photo_at(b, 'return') end) at,
           jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'car', app.vehicle_name(b.vehicle_id), 'plate', v.plate,
             'renter', r.legal_name, 'pickup_at', app.old_photo_at(b, 'pickup'), 'return_at', case when app.handover_past_stage(b, 'return') then app.old_photo_at(b, 'return') end,
             'kinds', to_jsonb(array_remove(array[case when app.old_photo_ok(b, 'pickup') then 'pickup' end, case when app.old_photo_ok(b, 'return') then 'return' end], null)),
             'photos', jsonb_build_object(
               'pickup', (select count(*) from condition_reports c join condition_report_photos ph on ph.condition_report_id = c.id where c.booking_id = b.id and c.kind = 'pickup' and ph.shot <> 'licence'),
               'return', (select count(*) from condition_reports c join condition_report_photos ph on ph.condition_report_id = c.id where c.booking_id = b.id and c.kind = 'return' and ph.shot <> 'licence'))) j
      from bookings b left join vehicles v on v.id = b.vehicle_id left join renters r on r.id = b.renter_id
     where b.booking_type <> 'owner' and b.status::text in ('on_rent', 'returned', 'closed')
       and (coalesce(b.handed_over_at, b.pickup_at) >= v_since or (b.status::text in ('returned', 'closed') and coalesce(b.checked_in_at, b.return_at) >= v_since))
       and (v_q is null or b.booking_number ilike '%' || v_q || '%' or r.legal_name ilike '%' || v_q || '%'
            or app.vehicle_name(b.vehicle_id) ilike '%' || v_q || '%' or (v_plate is not null and app.old_photo_plate(v.plate) like '%' || v_plate || '%'))
     order by 2 desc, 1 limit 60) x), '[]'::jsonb));
end $$;

-- before the bytes are stored: may this person add to it, and is this upload attached already
create function app.old_photo_gate(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  b bookings := app.old_photo_booking(p_by, p);
  v_key uuid := case when coalesce(p ->> 'key', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (p ->> 'key')::uuid end;
  v_path text;
begin
  select ph.storage_path into v_path from condition_reports c join condition_report_photos ph on ph.condition_report_id = c.id
   where c.booking_id = b.id and c.kind = p ->> 'kind' and ph.client_key = v_key;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'duplicate', v_path is not null, 'path', v_path);
end $$;

-- one photo on the check-in or check-out report, marked added later, with its capture time
create function app.old_photo_attach(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings := app.old_photo_booking(p_by, p);
  v_kind text := p ->> 'kind';
  v_key uuid := case when coalesce(p ->> 'key', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (p ->> 'key')::uuid end;
  v_path text := p ->> 'path';
  v_at timestamptz;
  v_claim timestamptz;
  c condition_reports;
  ph condition_report_photos;
  v_seq integer;
  v_word text := case v_kind when 'pickup' then 'check-in' else 'check-out' end;
begin
  if v_key is null then raise exception 'The upload has no id' using errcode = '22023'; end if;
  if v_path is null or v_path !~ ('^bookings/' || b.id || '/old/[0-9a-f-]{36}\.(jpg|png)$') then raise exception 'Unexpected path' using errcode = '22023'; end if;
  begin v_at := nullif(p ->> 'taken_at', '')::timestamptz; exception when others then v_at := null; end;
  -- a clock far off (the future, or years back) is not a capture time
  if v_at > now() + interval '1 day' or v_at < now() - interval '3 years' then v_at := null; end if;
  -- the phone's claim is kept as the device time; it is the capture time only inside the booking's own dates, 3 days either side
  v_claim := v_at;
  if v_at < b.pickup_at - interval '3 days' or v_at > b.return_at + interval '3 days' then v_at := null; end if;

  insert into condition_reports (vehicle_id, booking_id, kind, performed_by, performed_by_role, performed_at, details_pending, recorded_now, renter_present)
  values (b.vehicle_id, b.id, v_kind, p_by, 'staff', app.old_photo_at(b, v_kind), true,
          jsonb_build_object('by', p_by, 'at', now(), 'reason', 'Added after the trip'), false)
  on conflict (booking_id, kind) where kind in ('pickup', 'return') do nothing
  returning * into c;
  if c.id is not null then
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
      format('The %s photos and readings are added after the trip', v_word), p_by, 'staff', jsonb_build_object('kind', v_kind, 'after_trip', true, 'old_photos', true));
  end if;
  select * into c from condition_reports where booking_id = b.id and kind = v_kind for update;

  select * into ph from condition_report_photos where condition_report_id = c.id and client_key = v_key;
  if ph.id is not null then return jsonb_build_object('photo_id', ph.id, 'seq', ph.seq, 'report_id', c.id, 'duplicate', true); end if;
  if (select count(*) from condition_report_photos x where x.condition_report_id = c.id) >= 200 then
    raise exception 'The % report already has 200 photos', v_word using errcode = '23514';
  end if;

  -- one line in the booking's log a day per person and side, not one a photo
  if not exists (select 1 from condition_report_photos x where x.condition_report_id = c.id and x.uploaded_by = p_by and x.added_later_at > now() - interval '1 day') then
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
      format('Photos of the %s added later by %s', v_word, coalesce((select full_name from users where id = p_by), 'staff')), p_by, 'staff',
      jsonb_build_object('kind', v_kind, 'old_photos', true));
  end if;
  select coalesce(max(seq), 0) + 1 into v_seq from condition_report_photos where condition_report_id = c.id;
  insert into condition_report_photos (condition_report_id, seq, shot, storage_path, taken_at, device_taken_at, uploaded_by, width, height, added_later_at, client_key)
  values (c.id, v_seq, 'other', v_path, coalesce(v_at, now()), v_claim, p_by,
          nullif(greatest(coalesce((p ->> 'width')::integer, 0), 0), 0), nullif(greatest(coalesce((p ->> 'height')::integer, 0), 0), 0), now(), v_key)
  returning * into ph;
  return jsonb_build_object('photo_id', ph.id, 'seq', ph.seq, 'report_id', c.id, 'duplicate', false, 'booking_number', b.booking_number);
end $$;

-- the bulk flow: each group of photos {i, from, to, plate} gets the nearest check-in or check-out (and up to 3 others)
create function app.old_photo_suggest(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_hours integer := coalesce((app.settings()).old_photos_match_hours, 12);
  v_since timestamptz := now() - make_interval(days => coalesce((app.settings()).old_photos_days, 60));
  g jsonb;
  v_from timestamptz;
  v_to timestamptz;
  v_plate text;
  v_car uuid;
  v_out jsonb := '[]'::jsonb;
begin
  if not app.old_photos_may(p_by) then raise exception 'Only an Admin, Fleet, customer service or field staff add old photos' using errcode = '42501'; end if;
  if jsonb_typeof(p -> 'groups') is distinct from 'array' or jsonb_array_length(p -> 'groups') > 200 then raise exception 'Send the groups' using errcode = '22023'; end if;
  for g in select * from jsonb_array_elements(p -> 'groups') loop
    begin v_from := (g ->> 'from')::timestamptz; v_to := coalesce((g ->> 'to')::timestamptz, v_from); exception when others then v_from := null; end;
    v_plate := app.old_photo_plate(g ->> 'plate');
    v_car := case when v_plate is not null then (select v.id from vehicles v where app.old_photo_plate(v.plate) = v_plate limit 1) end;
    v_out := v_out || jsonb_build_object('i', g -> 'i', 'plate', v_plate, 'plate_matched', v_car is not null, 'options', coalesce((
      select jsonb_agg(o.j order by o.off, o.mine desc, o.n) from (
        select b.booking_number n, e.off, app.field_handled(p_by, b.id) mine,
               jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'kind', k.kind, 'at', app.old_photo_at(b, k.kind), 'car', app.vehicle_name(b.vehicle_id),
                 'plate', v.plate, 'renter', r.legal_name, 'minutes_off', round(e.off / 60)) j
          from bookings b cross join (values ('pickup'), ('return')) k(kind)
          left join vehicles v on v.id = b.vehicle_id left join renters r on r.id = b.renter_id
          cross join lateral (select case when v_from is null then 0
                                          when app.old_photo_at(b, k.kind) between v_from and v_to then 0
                                          else least(abs(extract(epoch from app.old_photo_at(b, k.kind) - v_from)), abs(extract(epoch from app.old_photo_at(b, k.kind) - v_to))) end off) e
         where b.booking_type <> 'owner' and b.status::text in ('on_rent', 'returned', 'closed')
           and (coalesce(b.handed_over_at, b.pickup_at) >= v_since or coalesce(b.checked_in_at, b.return_at) >= v_since)
           and app.old_photo_ok(b, k.kind) and (v_car is null or b.vehicle_id = v_car)
           and (v_from is null or e.off <= v_hours * 3600)
         order by e.off, 3 desc, 1 limit 4) o), '[]'::jsonb));
  end loop;
  return jsonb_build_object('hours', v_hours, 'groups', v_out);
end $$;

-- the plate read of the bulk flow: may this person ask, and does the day's vision allowance have room (as the dashboard read, 0910)
create function app.old_photo_plate_gate(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare a jsonb;
begin
  if not app.old_photos_may(p_by) then raise exception 'Only an Admin, Fleet, customer service or field staff add old photos' using errcode = '42501'; end if;
  if (select count(*) from provider_calls x where x.created_by = p_by and x.purpose = 'plate_detect' and app.local_date(x.created_at) = app.today())
       >= coalesce((app.settings()).old_photos_plate_daily, 30) then
    return jsonb_build_object('allowed', false, 'reason', 'daily');
  end if;
  if not coalesce((app.ai_vision_budget(now()) ->> 'enabled')::boolean, false) then return jsonb_build_object('allowed', false, 'reason', 'off'); end if;
  a := app.ai_allow('plate_detect', 150, now());
  return jsonb_build_object('allowed', coalesce((a ->> 'ok')::boolean, false), 'reason', case when not coalesce((a ->> 'ok')::boolean, false) then 'allowance' end,
                            'model', (app.settings()).ai_vision_model, 'fallback_model', (app.settings()).ai_vision_fallback_model);
end $$;
create function app.old_photo_plate_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if not app.old_photos_may(p_by) then raise exception 'Only an Admin, Fleet, customer service or field staff add old photos' using errcode = '42501'; end if;
  insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit, created_by)
  values (left(coalesce(p ->> 'model', 'workers-ai'), 120), 'plate_detect', coalesce((p ->> 'ok')::boolean, false), left(p ->> 'error', 500),
          greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0, greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons', p_by);
  return jsonb_build_object('ok', true);
end $$;

revoke all on function app.old_photos_may(uuid), app.old_photo_at(bookings, text), app.old_photo_ok(bookings, text), app.old_photo_plate(text),
  app.old_photo_booking(uuid, jsonb), app.old_photo_bookings(uuid, jsonb), app.old_photo_gate(uuid, jsonb), app.old_photo_attach(uuid, jsonb),
  app.old_photo_suggest(uuid, jsonb), app.old_photo_plate_gate(uuid), app.old_photo_plate_record(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.old_photos_may(uuid), app.old_photo_at(bookings, text), app.old_photo_ok(bookings, text), app.old_photo_plate(text),
  app.old_photo_booking(uuid, jsonb), app.old_photo_bookings(uuid, jsonb), app.old_photo_gate(uuid, jsonb), app.old_photo_attach(uuid, jsonb),
  app.old_photo_suggest(uuid, jsonb), app.old_photo_plate_gate(uuid), app.old_photo_plate_record(uuid, jsonb) to service_role;
