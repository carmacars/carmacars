-- 3350 (release 48, part MAP; docs/changes/2026-11-20-r48-map-people.md): staff and app users on the live map.
-- The owner (Nov 20): where staff are, and where app users are, on the live map (Admin, and the staff portals with a map).
-- 1. Staff: only while on shift (an open clock entry or field shift) or on a field job; never off duty. A one-time
--    electronic monitoring policy line (Ontario ESA Part XI.1) is accepted first; a copy goes by email (staff_location_policy,
--    transactional: locked). Sources: the store app and the staff web portal (the browser asks for permission).
-- 2. Renters and owners: only with the phone's or browser's permission, and only around a booking's pickup or return
--    (two hours either side; for the owner, a booking of their car). Otherwise nothing is stored and nothing is shown.
-- 3. Everyone can turn it off (location_prefs.sharing_on, the privacy card of their settings), except staff during an
--    active field job (in progress, or acknowledged and due within the hour).
-- 4. Only the latest position (person_locations) plus a thinned trail of each job, pickup or return (location_job_points,
--    a point every 2 minutes at most, deleted 30 days after it was taken). No long-term history: a latest position that
--    stops qualifying is deleted at once by the location job; positions are never written to the audit log.
-- 5. Reads: Admin and Fleet see everyone; customer service and Sales see only renters at a pickup or return (the bookings
--    their Visitors map already shows); Finance and field staff see no one (their Car map shows cars only).
-- All through the door (ops_read live_people, my_location; ops_do location_report, location_prefs_save,
-- location_policy_accept); the tables have RLS on and no grants to anon or authenticated. app.door and app.job_tracker are
-- wrapped (_pre3350). SCHEMA_MARKER 3350.
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

-- ================================================================ 1. tables
create table location_prefs (
  user_id            uuid primary key references users (id) on delete cascade,
  sharing_on         boolean not null default true,
  policy_version     text check (policy_version is null or length(policy_version) <= 40),
  policy_accepted_at timestamptz,
  updated_at         timestamptz not null default now(),
  check ((policy_version is null) = (policy_accepted_at is null))
);
comment on table location_prefs is 'Live map locations (3350): whether a person shares their location (on by default; staff cannot turn it off during an active field job) and the electronic monitoring policy a staff member accepted (Ontario ESA). Audited.';
alter table location_prefs enable row level security;
revoke all on location_prefs from anon, authenticated;
grant all on location_prefs to service_role;
create trigger audit_location_prefs after insert or update or delete on location_prefs for each row execute function app.audit_row();

create table person_locations (
  user_id      uuid primary key references users (id) on delete cascade,
  kind         text not null check (kind in ('staff', 'renter', 'owner')),
  reason       text not null check (reason in ('shift', 'job', 'pickup', 'return')),
  lat          numeric(8, 5) not null check (lat between -90 and 90),
  lng          numeric(8, 5) not null check (lng between -180 and 180),
  accuracy_m   integer check (accuracy_m is null or accuracy_m between 0 and 100000),
  source       text not null check (source in ('app', 'web')),
  booking_id   uuid references bookings (id) on delete set null,
  field_job_id uuid references field_jobs (id) on delete set null,
  at           timestamptz not null,
  received_at  timestamptz not null default now()
);
comment on table person_locations is 'Live map locations (3350): each person''s latest position only, while it qualifies (staff on shift or on a job; a renter or owner around a pickup or return). Deleted as soon as it stops qualifying. Never audited (no history).';
create index person_locations_booking_idx on person_locations (booking_id) where booking_id is not null;
create index person_locations_job_idx on person_locations (field_job_id) where field_job_id is not null;
alter table person_locations enable row level security;
revoke all on person_locations from anon, authenticated;
grant all on person_locations to service_role;

create table location_job_points (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references users (id) on delete cascade,
  field_job_id uuid references field_jobs (id) on delete cascade,
  booking_id   uuid references bookings (id) on delete cascade,
  reason       text not null check (reason in ('job', 'pickup', 'return')),
  lat          numeric(8, 5) not null,
  lng          numeric(8, 5) not null,
  accuracy_m   integer,
  at           timestamptz not null,
  check (field_job_id is not null or booking_id is not null)
);
comment on table location_job_points is 'Live map locations (3350): the points of a field job, a pickup or a return (one every 2 minutes at most), kept 30 days as proof of the job, then deleted. Nothing outside a job is kept.';
create index location_job_points_user_idx on location_job_points (user_id, at desc);
create index location_job_points_job_idx on location_job_points (field_job_id) where field_job_id is not null;
create index location_job_points_booking_idx on location_job_points (booking_id) where booking_id is not null;
create index location_job_points_at_idx on location_job_points (at);
alter table location_job_points enable row level security;
revoke all on location_job_points from anon, authenticated;
grant all on location_job_points to service_role;

-- ================================================================ 2. the rules
-- the policy line staff accept once (Ontario Employment Standards Act, Part XI.1: a written policy on electronic monitoring)
create function app.location_policy() returns jsonb
language sql immutable as $$
  select jsonb_build_object('version', 'esa-em-2026-11',
    'text', 'Electronic monitoring policy: while you are on shift or on a job, CarmaCars records where you are from the CarmaCars app or the staff portal (with your permission), to dispatch jobs, keep you safe and prove a pickup or return. Never off duty. Only your latest position is kept, plus the points of each job for 30 days. Admins and Fleet see it on the live map.')
$$;

/** What a person is for the map: admin, fleet, cs, sales, finance, field, owner or renter (the first that applies). */
create function app.location_role(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when app.user_is_admin(p_user) then 'admin'
              when app.user_va_has(p_user, 'fleet') then 'fleet'
              when app.user_va_has(p_user, 'cs') then 'cs'
              when app.user_va_has(p_user, 'sales') then 'sales'
              when app.user_va_has(p_user, 'finance') then 'finance'
              when app.user_is_field(p_user) then 'field'
              when exists (select 1 from owners o where o.user_id = p_user) then 'owner'
              when exists (select 1 from renters r where r.user_id = p_user) then 'renter'
              else null end
$$;

/** A staff member's active field job: in progress, or acknowledged or scheduled and due within the hour (or up to 3 hours late). */
create function app.location_active_job(p_user uuid, p_now timestamptz default now()) returns uuid
language sql stable security definer set search_path = public, app as $$
  select j.id from field_jobs j
   where j.assigned_to = p_user
     and (j.status = 'in_progress' or (j.status in ('scheduled', 'acknowledged') and j.scheduled_at between p_now - interval '3 hours' and p_now + interval '1 hour'))
   order by (j.status = 'in_progress') desc, abs(extract(epoch from j.scheduled_at - p_now)) limit 1
$$;

create function app.location_on_shift(p_user uuid, p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from staff_clock_entries c where c.user_id = p_user and c.ended_at is null and c.voided_at is null and c.started_at between p_now - interval '16 hours' and p_now)
      or exists (select 1 from field_shifts f where f.staff_id = p_user and f.ended_at is null and f.voided_at is null and f.started_at between p_now - interval '16 hours' and p_now)
$$;

/** A renter's or owner's booking at a pickup or return now: two hours either side of it, the booking confirmed or on rent. */
create function app.location_booking_window(p_user uuid, p_kind text, p_now timestamptz default now()) returns table (booking_id uuid, reason text)
language sql stable security definer set search_path = public, app as $$
  select b.id, case when abs(extract(epoch from b.pickup_at - p_now)) <= abs(extract(epoch from b.return_at - p_now)) then 'pickup' else 'return' end
    from bookings b
   where b.status::text in ('confirmed', 'on_rent') and not coalesce(b.is_placeholder, false)
     and ((b.status::text = 'confirmed' and b.pickup_at between p_now - interval '2 hours' and p_now + interval '2 hours')
       or (b.return_at between p_now - interval '2 hours' and p_now + interval '2 hours'))
     and case p_kind when 'renter' then b.renter_id in (select r.id from renters r where r.user_id = p_user) and b.booking_type::text <> 'owner'
                     when 'owner' then b.vehicle_id in (select v.id from vehicles v join owners o on o.id = v.owner_id where o.user_id = p_user)
                     else false end
   order by least(abs(extract(epoch from b.pickup_at - p_now)), abs(extract(epoch from b.return_at - p_now))) limit 1
$$;

/** Whether this person's location may be taken now, and why: {share, kind, reason, booking_id, field_job_id, locked, policy}. */
create function app.location_state(p_user uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_role text := app.location_role(p_user);
  v_staff boolean := v_role in ('admin', 'fleet', 'cs', 'sales', 'finance', 'field');
  p location_prefs;
  v_job uuid;
  v_shift boolean := false;
  w record;
  v_pol jsonb := app.location_policy();
begin
  select * into p from location_prefs where user_id = p_user;
  if v_role is null then return jsonb_build_object('share', false, 'kind', null, 'why', 'none'); end if;
  if v_staff then
    v_job := app.location_active_job(p_user, p_now);
    v_shift := app.location_on_shift(p_user, p_now);
    return jsonb_build_object('kind', 'staff', 'role', v_role,
      'policy', jsonb_build_object('version', v_pol ->> 'version', 'text', v_pol ->> 'text', 'accepted_at', case when p.policy_version = v_pol ->> 'version' then p.policy_accepted_at end),
      'sharing_on', coalesce(p.sharing_on, true), 'locked', v_job is not null, 'field_job_id', v_job, 'on_shift', v_shift,
      'reason', case when v_job is not null then 'job' when v_shift then 'shift' end,
      'share', p.policy_version is not distinct from v_pol ->> 'version' and p.policy_accepted_at is not null
               and (v_job is not null or (v_shift and coalesce(p.sharing_on, true))),
      'why', case when p.policy_accepted_at is null or p.policy_version is distinct from v_pol ->> 'version' then 'policy'
                  when v_job is not null then 'job' when not v_shift then 'off_duty' when not coalesce(p.sharing_on, true) then 'off' else 'shift' end);
  end if;
  select * into w from app.location_booking_window(p_user, v_role, p_now);
  return jsonb_build_object('kind', v_role, 'role', v_role, 'sharing_on', coalesce(p.sharing_on, true), 'locked', false, 'booking_id', w.booking_id, 'reason', w.reason,
    'share', coalesce(p.sharing_on, true) and w.booking_id is not null,
    'why', case when not coalesce(p.sharing_on, true) then 'off' when w.booking_id is null then 'no_booking' else w.reason end);
end $$;

-- ================================================================ 3. writes
-- p: {lat, lng, accuracy_m, at (ISO, at most 2 minutes old), source: app | web}. Stored only when the state says so; otherwise
-- the latest position is deleted. A report less than 20 seconds after the last one is not stored (the page sends every 60).
create function app.location_report(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s jsonb := app.location_state(p_user);
  v_lat numeric; v_lng numeric; v_acc integer; v_at timestamptz; v_src text := coalesce(p ->> 'source', 'web');
  v_reason text := s ->> 'reason';
  v_job uuid := nullif(s ->> 'field_job_id', '')::uuid;
  v_booking uuid := nullif(s ->> 'booking_id', '')::uuid;
  v_last timestamptz;
begin
  if not coalesce((s ->> 'share')::boolean, false) then
    delete from person_locations where user_id = p_user;
    return jsonb_build_object('stored', false, 'why', s ->> 'why');
  end if;
  begin
    v_lat := round((p ->> 'lat')::numeric, 5); v_lng := round((p ->> 'lng')::numeric, 5);
    v_acc := least(100000, greatest(0, round(coalesce((p ->> 'accuracy_m')::numeric, 0))))::integer;
    v_at := coalesce((p ->> 'at')::timestamptz, now());
  exception when others then
    raise exception 'That position could not be read' using errcode = '22023';
  end;
  if v_lat is null or v_lng is null or v_lat not between -90 and 90 or v_lng not between -180 and 180 then raise exception 'That position could not be read' using errcode = '22023'; end if;
  if v_src not in ('app', 'web') then v_src := 'web'; end if;
  if v_at > now() + interval '1 minute' or v_at < now() - interval '2 minutes' then return jsonb_build_object('stored', false, 'why', 'stale'); end if;
  select received_at into v_last from person_locations where user_id = p_user;
  if v_last is not null and v_last > now() - interval '20 seconds' then return jsonb_build_object('stored', false, 'why', 'soon'); end if;
  insert into person_locations as l (user_id, kind, reason, lat, lng, accuracy_m, source, booking_id, field_job_id, at, received_at)
  values (p_user, case when s ->> 'kind' = 'staff' then 'staff' else s ->> 'kind' end, v_reason, v_lat, v_lng, v_acc, v_src, v_booking, v_job, v_at, now())
  on conflict (user_id) do update set kind = excluded.kind, reason = excluded.reason, lat = excluded.lat, lng = excluded.lng, accuracy_m = excluded.accuracy_m,
    source = excluded.source, booking_id = excluded.booking_id, field_job_id = excluded.field_job_id, at = excluded.at, received_at = excluded.received_at;
  -- the job's own points, thinned to one every 2 minutes
  if v_reason in ('job', 'pickup', 'return') and not exists (select 1 from location_job_points j where j.user_id = p_user and j.at > v_at - interval '2 minutes'
       and (j.field_job_id is not distinct from v_job) and (j.booking_id is not distinct from v_booking)) then
    insert into location_job_points (user_id, field_job_id, booking_id, reason, lat, lng, accuracy_m, at) values (p_user, v_job, v_booking, v_reason, v_lat, v_lng, v_acc, v_at);
  end if;
  return jsonb_build_object('stored', true, 'reason', v_reason);
end $$;

-- p: {sharing_on}. Staff cannot turn it off during an active field job.
create function app.location_prefs_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_on boolean := coalesce((p ->> 'sharing_on')::boolean, true);
begin
  if app.location_role(p_user) is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if not v_on and app.location_role(p_user) in ('admin', 'fleet', 'cs', 'sales', 'finance', 'field') and app.location_active_job(p_user) is not null then
    raise exception 'Location sharing stays on during an active job. You can turn it off once the job is done.' using errcode = '23514';
  end if;
  insert into location_prefs as l (user_id, sharing_on, updated_at) values (p_user, v_on, now())
  on conflict (user_id) do update set sharing_on = excluded.sharing_on, updated_at = now() where l.sharing_on is distinct from excluded.sharing_on;
  if not v_on then delete from person_locations where user_id = p_user and not coalesce((app.location_state(p_user) ->> 'share')::boolean, false); end if;
  return app.location_state(p_user);
end $$;

-- p: {version}: the policy shown. Once per version; a copy by email (branded, transactional) with its in-app and push alert.
create function app.location_policy_accept(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_pol jsonb := app.location_policy();
  v_first text := coalesce((select nullif(split_part(btrim(u.full_name), ' ', 1), '') from users u where u.id = p_user), 'there');
  v_new boolean;
begin
  if coalesce(app.location_role(p_user), '') not in ('admin', 'fleet', 'cs', 'sales', 'finance', 'field') then raise exception 'Staff only' using errcode = '42501'; end if;
  if coalesce(p ->> 'version', '') <> v_pol ->> 'version' then raise exception 'The policy changed: reload the page and read it again' using errcode = '23514'; end if;
  v_new := not exists (select 1 from location_prefs where user_id = p_user and policy_version = v_pol ->> 'version');
  insert into location_prefs as l (user_id, policy_version, policy_accepted_at, updated_at) values (p_user, v_pol ->> 'version', now(), now())
  on conflict (user_id) do update set policy_version = excluded.policy_version, policy_accepted_at = excluded.policy_accepted_at, updated_at = now()
   where l.policy_version is distinct from excluded.policy_version;
  if v_new then
    perform app.emit_event('staff_location_policy', 'user', p_user, jsonb_build_object('recipient_user_id', p_user, 'first_name', v_first,
      'policy_text', v_pol ->> 'text', 'policy_version', v_pol ->> 'version', 'accepted_on', app.fmt_at(now()),
      'settings_url', rtrim((app.settings()).notify_base_url, '/') || case when app.location_role(p_user) = 'field' then '/staff/field/profile#location' else '/staff/profile#location' end), 'staff_location_policy:' || p_user || ':' || (v_pol ->> 'version'));
  end if;
  return app.location_state(p_user);
end $$;

-- ================================================================ 4. reads
create function app.my_location(p_user uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return app.location_state(p_user) || jsonb_build_object('latest', (select jsonb_build_object('lat', l.lat::float8, 'lng', l.lng::float8, 'at', l.at) from person_locations l where l.user_id = p_user));
end $$;

-- The map's people layer: {people: [{id, kind, role, name, lat, lng, accuracy_m, at, reason, source, booking_number, job}], scope: all | renters | none}
create function app.live_people(p_user uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_all boolean := app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet');
  v_renters boolean := app.user_va_has(p_user, 'cs', 'sales');
  v_scope text := case when v_all then 'all' when v_renters then 'renters' else 'none' end;
begin
  if not (app.user_is_admin(p_user) or app.user_is_staff(p_user) or app.user_is_field(p_user)) then raise exception 'Staff only' using errcode = '42501'; end if;
  if v_scope = 'none' then return jsonb_build_object('scope', v_scope, 'people', '[]'::jsonb); end if;
  return jsonb_build_object('scope', v_scope, 'people', coalesce((select jsonb_agg(x order by x ->> 'role', x ->> 'name') from (
    select jsonb_strip_nulls(jsonb_build_object('id', l.user_id, 'kind', l.kind, 'role', case when l.kind = 'staff' then app.location_role(l.user_id) else l.kind end,
      'name', coalesce(nullif(btrim(u.full_name), ''), 'Unnamed'), 'lat', l.lat::float8, 'lng', l.lng::float8, 'accuracy_m', l.accuracy_m, 'at', l.at, 'reason', l.reason, 'source', l.source,
      'booking_number', b.booking_number, 'job', case when j.id is not null then jsonb_build_object('id', j.id, 'kind', j.kind, 'status', j.status) end)) x
      from person_locations l join users u on u.id = l.user_id
      left join bookings b on b.id = l.booking_id left join field_jobs j on j.id = l.field_job_id
     where l.at > now() - interval '2 hours'
       and coalesce((app.location_state(l.user_id) ->> 'share')::boolean, false)
       and (v_all or (l.kind = 'renter' and l.booking_id is not null))
     limit 500) s), '[]'::jsonb));
end $$;

-- ================================================================ 5. the location job: what stops qualifying is deleted
create function app.location_purge(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare n bigint := 0; m bigint := 0;
begin
  delete from person_locations l where l.received_at < p_now - interval '2 hours' or not coalesce((app.location_state(l.user_id, p_now) ->> 'share')::boolean, false);
  get diagnostics n = row_count;
  delete from location_job_points where at < p_now - interval '30 days';
  get diagnostics m = row_count;
  return jsonb_build_object('locations_deleted', n, 'job_points_deleted', m);
end $$;

alter function app.job_tracker(timestamptz) rename to job_tracker_pre3350;
create function app.job_tracker(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.job_tracker_pre3350(p_now) || app.location_purge(p_now);
end $$;
select pg_temp.copy_grants('app.job_tracker(timestamptz)'::regprocedure, 'app.job_tracker_pre3350(timestamptz)'::regprocedure);

-- a field job that ends takes its staff member's position off the map at once (unless they are still on shift)
create function app.location_job_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.assigned_to is not null then
    delete from person_locations l where l.user_id = new.assigned_to and l.field_job_id = new.id and not coalesce((app.location_state(l.user_id) ->> 'share')::boolean, false);
    update person_locations set field_job_id = null, reason = 'shift' where user_id = new.assigned_to and field_job_id = new.id;
  end if;
  return null;
end $$;
create trigger location_job_after after update of status on field_jobs for each row when (new.status in ('done', 'cancelled') and old.status is distinct from new.status)
  execute function app.location_job_after();

-- ================================================================ 6. the notification (staff_location_policy)
-- CATALOGUE 3350 START (generated by supabase/seed/3350_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('staff_location_policy', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your copy: the CarmaCars electronic monitoring policy', 'Your location is shown only while you are on shift or on a job.', 'Immediate, once per policy version', 'A staff member accepts the electronic monitoring policy before their location is shown on the live map (migration 3350; Ontario Employment Standards Act, Part XI.1). Once per policy version: their copy of the policy.', null, null, '[{"name":"accepted_on","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"policy_text","type":"string"},{"name":"policy_version","type":"string"},{"name":"settings_url","type":"url"}]'::jsonb, 'templates/staff_location_policy.html', 'templates/staff_location_policy.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 3350 END
update notification_catalogue set push_topic = 'documents', hold_to_merge = false, user_can_mute = false, emitted_by = 'app.location_policy_accept (3350): a staff member accepted the electronic monitoring policy'
 where code = 'staff_location_policy';

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3350;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'ops_do' and p_name in ('location_report', 'location_prefs_save', 'location_policy_accept') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'location_report' then app.location_report(p_user, v)
                       when 'location_prefs_save' then app.location_prefs_save(p_user, v)
                       else app.location_policy_accept(p_user, v) end;
  end if;
  if p_call = 'ops_read' and p_name in ('live_people', 'my_location') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'live_people' then app.live_people(p_user, v) else app.my_location(p_user, v) end;
  end if;
  return app.door_pre3350(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3350(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f text;
begin
  foreach f in array array['app.location_policy()', 'app.location_role(uuid)', 'app.location_active_job(uuid, timestamptz)', 'app.location_on_shift(uuid, timestamptz)',
    'app.location_booking_window(uuid, text, timestamptz)', 'app.location_state(uuid, timestamptz)', 'app.location_report(uuid, jsonb)', 'app.location_prefs_save(uuid, jsonb)',
    'app.location_policy_accept(uuid, jsonb)', 'app.my_location(uuid, jsonb)', 'app.live_people(uuid, jsonb)', 'app.location_purge(timestamptz)',
    'app.job_tracker_pre3350(timestamptz)', 'app.location_job_after()', 'app.door_pre3350(uuid, text, text, text, jsonb)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
