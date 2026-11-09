-- 0881: where a field person clocks in and out (Release 35, part T; docs/changes/2026-11-08-r35-field-assign-gate.md). No applied
-- migration is edited. The phone's location is asked at the moment of clock in and clock out only (no tracking in between) and kept on
-- the shift: latitude, longitude, accuracy, the phone's time, the distance from the company location (Settings > Program) when
-- that is set, and a flag. A clock in or out more than 500 m away, or with the location refused, still works but needs a reason, and
-- Fleet and Admin see the flag. Read by the person, Fleet, Admin and Finance through the hours screens (field_shifts is not open
-- to other roles).
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter table field_shifts
  add column in_lat numeric(9, 6) check (in_lat between -90 and 90),
  add column in_lng numeric(9, 6) check (in_lng between -180 and 180),
  add column in_accuracy_m integer check (in_accuracy_m >= 0),
  add column in_located_at timestamptz,
  add column in_distance_m integer check (in_distance_m >= 0),
  add column in_flag text check (in_flag in ('far', 'no_location')),
  add column in_reason text check (length(in_reason) <= 300),
  add column out_lat numeric(9, 6) check (out_lat between -90 and 90),
  add column out_lng numeric(9, 6) check (out_lng between -180 and 180),
  add column out_accuracy_m integer check (out_accuracy_m >= 0),
  add column out_located_at timestamptz,
  add column out_distance_m integer check (out_distance_m >= 0),
  add column out_flag text check (out_flag in ('far', 'no_location')),
  add column out_reason text check (length(out_reason) <= 300);
comment on column field_shifts.in_lat is 'Where the phone was at clock in (0881): asked once at that moment, never tracked in between. in_flag far: over 500 m from the company location; no_location: refused or unavailable. A flagged clock in needs in_reason. Same for out_*.';

-- p: {lat, lng, accuracy, located_at, location_reason}. Returns the pieces to keep; refuses a flagged one without a reason.
create function app.fp_loc(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_lat numeric := case when coalesce(p ->> 'lat', '') ~ '^-?[0-9.]+$' then (p ->> 'lat')::numeric end;
  v_lng numeric := case when coalesce(p ->> 'lng', '') ~ '^-?[0-9.]+$' then (p ->> 'lng')::numeric end;
  v_acc integer := case when coalesce(p ->> 'accuracy', '') ~ '^[0-9.]+$' then round((p ->> 'accuracy')::numeric)::integer end;
  v_reason text := nullif(btrim(coalesce(p ->> 'location_reason', '')), '');
  s program_settings := app.settings();
  v_dist integer;
  v_flag text;
begin
  if v_lat is null or v_lng is null or v_lat not between -90 and 90 or v_lng not between -180 and 180 then v_lat := null; v_lng := null; v_acc := null; end if;
  if length(coalesce(v_reason, '')) > 300 then raise exception 'The reason is at most 300 characters' using errcode = '22023'; end if;
  if v_lat is null then
    v_flag := 'no_location';
  elsif s.company_latitude is not null and s.company_longitude is not null then
    v_dist := round(app.distance_km(s.company_latitude, s.company_longitude, v_lat, v_lng) * 1000)::integer;
    if v_dist > 500 then v_flag := 'far'; end if;
  end if;
  if v_flag = 'no_location' and v_reason is null then raise exception 'Your location is needed. Allow it in the browser, or write why you cannot' using errcode = '22023'; end if;
  if v_flag = 'far' and v_reason is null then raise exception 'You are % m from the lot. Write why you are clocking here', v_dist using errcode = '22023'; end if;
  return jsonb_build_object('lat', v_lat, 'lng', v_lng, 'accuracy', v_acc, 'located_at', case when v_lat is not null then coalesce(nullif(p ->> 'located_at', '')::timestamptz, now()) end,
                            'distance_m', v_dist, 'flag', v_flag, 'reason', case when v_flag is not null then v_reason end);
end $$;

alter function app.field_clock_in(uuid, jsonb) rename to field_clock_in_pre0881;
create function app.field_clock_in(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l jsonb;
  x field_shifts;
begin
  if not app.user_is_field(p_by) then raise exception 'Only field staff clock in' using errcode = '42501'; end if;
  l := app.fp_loc(p);
  perform app.field_clock_in_pre0881(p_by, p);
  update field_shifts set in_lat = (l ->> 'lat')::numeric, in_lng = (l ->> 'lng')::numeric, in_accuracy_m = (l ->> 'accuracy')::integer, in_located_at = (l ->> 'located_at')::timestamptz,
         in_distance_m = (l ->> 'distance_m')::integer, in_flag = l ->> 'flag', in_reason = l ->> 'reason'
   where staff_id = p_by and ended_at is null and voided_at is null returning * into x;
  if l ->> 'flag' is not null then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'field_clock_in_flagged', 'field_shifts', x.id::text, jsonb_build_object('flag', l ->> 'flag', 'distance_m', l -> 'distance_m', 'reason', l ->> 'reason'));
  end if;
  return app.fp_shift_json(x);
end $$;

alter function app.field_clock_out(uuid, jsonb) rename to field_clock_out_pre0881;
create function app.field_clock_out(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l jsonb;
  x field_shifts;
  v_id uuid;
begin
  if not app.user_is_field(p_by) then raise exception 'Only field staff clock out' using errcode = '42501'; end if;
  l := app.fp_loc(p);
  select id into v_id from field_shifts where staff_id = p_by and ended_at is null and voided_at is null;
  perform app.field_clock_out_pre0881(p_by, p);
  update field_shifts set out_lat = (l ->> 'lat')::numeric, out_lng = (l ->> 'lng')::numeric, out_accuracy_m = (l ->> 'accuracy')::integer, out_located_at = (l ->> 'located_at')::timestamptz,
         out_distance_m = (l ->> 'distance_m')::integer, out_flag = l ->> 'flag', out_reason = l ->> 'reason'
   where id = v_id returning * into x;
  if l ->> 'flag' is not null then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'field_clock_out_flagged', 'field_shifts', x.id::text, jsonb_build_object('flag', l ->> 'flag', 'distance_m', l -> 'distance_m', 'reason', l ->> 'reason'));
  end if;
  return app.fp_shift_json(x, true);
end $$;

-- every screen that shows a shift carries where it started and ended
create or replace function app.fp_shift_json(x field_shifts, p_jobs boolean default false) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', x.id, 'staff_id', x.staff_id, 'started_at', x.started_at, 'ended_at', x.ended_at, 'note', x.note, 'source', x.source,
    'minutes', case when x.ended_at is not null then round(extract(epoch from (x.ended_at - x.started_at)) / 60)::integer
                    else floor(extract(epoch from (now() - x.started_at)) / 60)::integer end,
    'open', x.ended_at is null and x.voided_at is null, 'day', app.local_date(x.started_at),
    'locked', app.fp_locked(app.local_date(x.started_at)),
    'edits', (select count(*) from field_shift_edits e where e.shift_id = x.id and e.action <> 'add'),
    'jobs', case when p_jobs then app.fp_shift_jobs(x.staff_id, x.started_at, coalesce(x.ended_at, now())) end,
    'loc', jsonb_build_object(
      'in', case when x.source = 'clock' then jsonb_build_object('lat', x.in_lat, 'lng', x.in_lng, 'accuracy', x.in_accuracy_m, 'at', x.in_located_at, 'distance_m', x.in_distance_m, 'flag', x.in_flag, 'reason', x.in_reason) end,
      'out', case when x.source = 'clock' and x.ended_at is not null then jsonb_build_object('lat', x.out_lat, 'lng', x.out_lng, 'accuracy', x.out_accuracy_m, 'at', x.out_located_at, 'distance_m', x.out_distance_m, 'flag', x.out_flag, 'reason', x.out_reason) end))
$$;

select pg_temp.copy_grants('app.field_clock_in(uuid, jsonb)'::regprocedure, 'app.field_clock_in_pre0881(uuid, jsonb)'::regprocedure);
select pg_temp.copy_grants('app.field_clock_out(uuid, jsonb)'::regprocedure, 'app.field_clock_out_pre0881(uuid, jsonb)'::regprocedure);
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('fp_loc', 'field_clock_in_pre0881', 'field_clock_out_pre0881')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
