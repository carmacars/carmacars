-- 0912_r35w_accident_report.sql
-- Release 35 part W (docs/changes/2026-11-08-r35-accident-card.md, "Report an accident"). SCHEMA_MARKER 0912. The owner,
-- November 8: renters report an accident from the accident card on their booking page: what happened, when, where (the
-- phone's location), photos and videos from the camera roll, the other party (name, phone, plate, their coverage), the
-- police report number if any, anyone hurt, can the car be driven. It opens the incident staff already work (0020's
-- app.open_incident, its first-response steps, its Fleet and Admin To dos), sends an urgent alert to Admin and Fleet on duty,
-- and shows the renter the next steps and our phone number. The photos and videos are the incident's documents; more can be
-- added after it is sent. No applied migration is edited.
set local check_function_bodies = off;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('accident_reported', 'Accident reported by a renter', 'Bookings', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, false,
   'A renter reported an accident from the accident card on their booking (0912): the incident is open with its first-response steps. Call the renter now.', 47)
on conflict (rule) do nothing;

-- the photos and videos a renter uploaded for this booking's accident report: only this booking's own keys
create or replace function app.accident_media_add(p_incident uuid, p_booking uuid, p_by uuid, p_media jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  m jsonb;
  b bookings;
  v_doc uuid;
  n integer := 0;
begin
  if p_media is null or jsonb_typeof(p_media) <> 'array' then return 0; end if;
  if jsonb_array_length(p_media) > 20 then raise exception 'Up to 20 photos or videos at a time' using errcode = '22023'; end if;
  select * into b from bookings where id = p_booking;
  for m in select * from jsonb_array_elements(p_media) loop
    if m ->> 'bucket' <> 'condition-photos' or coalesce(m ->> 'path', '') !~ ('^bookings/' || p_booking || '/accident/[0-9a-f-]{36}\.(jpg|png|mp4|mov|webm)$') then
      raise exception 'A photo or video was not uploaded for this booking' using errcode = '22023';
    end if;
    if exists (select 1 from documents d where d.incident_id = p_incident and d.storage_path = m ->> 'path') then continue; end if;
    insert into documents (kind, title, storage_bucket, storage_path, mime_type, retention, renter_id, booking_id, incident_id, uploaded_by)
    values ('incident_report', case when m ->> 'path' ~ '\.(mp4|mov|webm)$' then 'Accident video from the renter' else 'Accident photo from the renter' end,
            'condition-photos', m ->> 'path',
            case substring(m ->> 'path' from '\.([a-z0-9]+)$') when 'png' then 'image/png' when 'mp4' then 'video/mp4' when 'mov' then 'video/quicktime'
                 when 'webm' then 'video/webm' else 'image/jpeg' end,
            'records_7y', b.renter_id, p_booking, p_incident, p_by)
    returning id into v_doc;
    insert into incident_events (incident_id, kind, detail, document_id, actor_user_id)
    values (p_incident, 'message', 'The renter added a photo or video', v_doc, p_by);
    n := n + 1;
  end loop;
  if n > 0 then update incidents set renter_report_received_at = coalesce(renter_report_received_at, now()) where id = p_incident; end if;
  return n;
end $$;

-- p {booking, description, occurred_at?, place?, latitude?, longitude?, other_party {name, phone, plate, coverage}?,
--    police_report_number?, anyone_hurt, drivable, media [{bucket, path}]}: the renter's report
create or replace function app.renter_accident_report(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_id uuid;
  i incidents;
  v_lat numeric := nullif(p ->> 'latitude', '')::numeric;
  v_lng numeric := nullif(p ->> 'longitude', '')::numeric;
  v_place text := nullif(btrim(coalesce(p ->> 'place', '')), '');
  op jsonb := coalesce(p -> 'other_party', '{}'::jsonb);
  v_op jsonb;
  v_n integer;
  ss site_settings;
  s program_settings := app.settings();
begin
  select * into b from bookings where id::text = p ->> 'booking';
  if b.id is null or p_by is null or not app.is_booking_renter(b.id, p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if b.status::text <> 'on_rent' then raise exception 'An accident is reported while you have the car. Call us for anything else.' using errcode = '23514'; end if;
  if length(btrim(coalesce(p ->> 'description', ''))) < 5 then raise exception 'Say what happened' using errcode = '22023'; end if;
  if (p ->> 'anyone_hurt') is null or (p ->> 'drivable') is null then raise exception 'Answer whether anyone is hurt and whether the car can be driven' using errcode = '22023'; end if;
  if nullif(p ->> 'occurred_at', '')::timestamptz > now() + interval '5 minutes' then raise exception 'The time of the accident is not in the future' using errcode = '22023'; end if;
  if v_lat is not null and (v_lat not between -90 and 90 or v_lng is null or v_lng not between -180 and 180) then v_lat := null; v_lng := null; end if;
  v_place := coalesce(v_place, case when v_lat is not null then format('Phone location %s, %s', round(v_lat, 6), round(v_lng, 6)) end);
  v_op := jsonb_strip_nulls(jsonb_build_object('name', nullif(btrim(left(op ->> 'name', 200)), ''), 'phone', nullif(btrim(left(op ->> 'phone', 40)), ''),
            'plate', nullif(upper(btrim(left(op ->> 'plate', 20))), ''), 'coverage', nullif(btrim(left(op ->> 'coverage', 300)), ''),
            'latitude', v_lat, 'longitude', v_lng));
  v_id := app.open_incident('accident', b.vehicle_id, p_by, jsonb_build_object(
            'description', left(btrim(p ->> 'description'), 4000), 'occurred_at', coalesce(nullif(p ->> 'occurred_at', '')::timestamptz, now()),
            'place', left(v_place, 500), 'other_party', case when v_op = '{}'::jsonb then null else v_op end,
            'police_report_number', nullif(btrim(left(p ->> 'police_report_number', 60)), ''),
            'anyone_hurt', (p ->> 'anyone_hurt')::boolean, 'drivable', (p ->> 'drivable')::boolean,
            'driver_id', (select d.driver_id from booking_drivers d join drivers x on x.id = d.driver_id where d.booking_id = b.id and x.user_id = p_by limit 1)),
          b.id, 'renter');
  v_n := app.accident_media_add(v_id, b.id, p_by, p -> 'media');
  select * into i from incidents where id = v_id;
  perform app.staff_alert('accident_reported', 'incident', v_id, 'reported',
    left(format('Accident reported: %s, %s%s', b.booking_number, app.vehicle_name(b.vehicle_id), case when i.anyone_hurt then ' (someone is hurt)' else '' end), 200),
    left(format('%s. %s%s. Call the renter now.', coalesce(i.place, 'Place not given'), case when i.drivable then 'The car can be driven' else 'The car cannot be driven' end,
                case when v_n > 0 then format(', %s photos or videos', v_n) else '' end), 1000),
    jsonb_build_object('path_admin', '/admin/incidents', 'path_staff', '/staff/bookings/' || b.booking_number));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('Accident reported by the renter from the accident card: incident %s', i.incident_number), p_by, 'renter',
    jsonb_build_object('incident_id', v_id, 'media', v_n));
  select * into ss from site_settings limit 1;
  return jsonb_build_object('incident_id', v_id, 'incident_number', i.incident_number, 'media', v_n,
    'phone', coalesce(ss.phone_display, s.company_phone), 'roadside_phone', coalesce(ss.roadside_phone_display, s.incident_line_phone),
    'report_hours', s.incident_report_hours, 'drivable', i.drivable, 'anyone_hurt', i.anyone_hurt);
end $$;

-- more photos or videos after the report is sent (the renter of the booking, while the incident is open)
create or replace function app.renter_accident_media(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i incidents;
begin
  select * into i from incidents where id::text = p ->> 'incident';
  if i.id is null or i.booking_id is null or p_by is null or not app.is_booking_renter(i.booking_id, p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if i.status = 'closed' then raise exception 'This report is closed: send anything else to us by message' using errcode = '23514'; end if;
  return jsonb_build_object('added', app.accident_media_add(i.id, i.booking_id, p_by, p -> 'media'));
end $$;

-- the renter's open accident reports on a booking (the booking page shows that it was sent)
create or replace function public.server_renter_accidents(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return coalesce((select jsonb_agg(jsonb_build_object('incident_id', i.id, 'incident_number', i.incident_number, 'reported_at', i.reported_at, 'status', i.status,
            'media', (select count(*) from documents d where d.incident_id = i.id)) order by i.reported_at desc)
    from incidents i where i.booking_id = p_booking and i.kind = 'accident' and i.opened_by = p_by), '[]'::jsonb);
end $$;
create or replace function public.server_renter_accident_report(p_by uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.renter_accident_report(p_by, p) $$;
create or replace function public.server_renter_accident_media(p_by uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.renter_accident_media(p_by, p) $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['accident_media_add', 'renter_accident_report', 'renter_accident_media']))
               or (n.nspname = 'public' and p.proname = any (array['server_renter_accidents', 'server_renter_accident_report', 'server_renter_accident_media']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
