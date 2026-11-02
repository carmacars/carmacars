-- 0500: Release 27 consolidation (docs/changes/2026-11-07-consolidation.md). The owner on November 2, 2026: every Admin
-- upgrade reaches each staff role's portal, Live chat inside Visitors, fewer pages, and Call and Text through Quo.
--
-- 1. Staff reads of Admin's pages, scoped to the function and checked here:
--    - va_read live_map: the live map for customer service and Sales (no fleet layer, no money);
--    - va_read visitor_history: Visitors > History for customer service and Sales (the visit's own page stays Admin's);
--    - va_read data_health: the problem lines of the function on its To do (fleet: car gaps; customer service: licences;
--      Sales: stalled leads; finance: unmatched payments and deposits held), without the fixes (Admin's);
--    - va_read marketplace: the Marketplace kits for Sales (read only; logging stays Admin's).
--    These reuse Admin's functions: app.assert_admin lets a call through for the one person a staff read named
--    (app.staff_view, transaction-local, set and cleared around the call by the staff read after its own check).
-- 2. Bookings > Now: finance reads it with the money (as fleet and customer service); Sales without the money and without
--    the renters' phones and emails.
-- 3. Fleet tracking for field staff: the cars of their own jobs only, and only those cars' trips.
-- 4. Call and Text through Quo: program_settings.phone_quo_buttons (on), phone_buttons (read), phone_compose (a text from the
--    CarmaCars number, logged to the person's conversation) and phone_call_log (a call started from the site).
-- No applied migration is edited.
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

-- ================================================================ 1. staff reads of Admin's functions
create or replace function app.assert_admin(p_admin uuid) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  -- a staff read (0500) that has checked the person itself, for the length of that one call
  if p_admin is not null and coalesce(current_setting('app.staff_view', true), '') = p_admin::text then return; end if;
  if p_admin is null or not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin may do this' using errcode = '42501';
  end if;
end $$;

create or replace function app.staff_view(p_user uuid) returns void
language sql volatile security definer set search_path = public, app as $$ select set_config('app.staff_view', coalesce(p_user::text, ''), true); $$;

-- the live map for customer service and Sales: the leads and visitors, no fleet layer, no money
create or replace function app.staff_live_map(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare v jsonb;
begin
  perform app.assert_live_staff(p_by);
  perform app.staff_view(p_by);
  v := app.live_map(p_by, coalesce(p, '{}'::jsonb));
  perform app.staff_view(null);
  if app.user_is_admin(p_by) then return v; end if;
  return v || jsonb_build_object('fleet', '[]'::jsonb, 'tracker_demo', false,
    'kpi', coalesce(v -> 'kpi', '{}'::jsonb) || jsonb_build_object('collected_month_cents', null));
end $$;

create or replace function app.staff_visitor_history(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare v jsonb;
begin
  perform app.assert_live_staff(p_by);
  perform app.staff_view(p_by);
  v := app.visitor_history(p_by, coalesce(p, '{}'::jsonb));
  perform app.staff_view(null);
  return v;
end $$;

-- Data health lines of each office function (the checks of migration 0441), read only
create or replace function app.data_health_keys(p_fn text) returns text[]
language sql immutable as $$
  select case p_fn
    when 'fleet' then array['car_gaps', 'pickup_not_recorded', 'never_closed', 'on_rent_gaps']
    when 'cs' then array['licence_waiting', 'on_rent_gaps', 'offers_stale']
    when 'sales' then array['lead_followup', 'offers_stale', 'sample_requests']
    when 'finance' then array['unmatched_payments', 'deposits_overdue', 'dead_with_money']
    else array[]::text[] end
$$;

create or replace function app.staff_data_health(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_fn text := app.va_active_fn(p_by);
  r data_health_runs;
  v_keys text[];
begin
  if v_fn is null or not app.user_va_has(p_by, v_fn) then raise exception 'Data health is for Admins and office staff' using errcode = '42501'; end if;
  v_keys := app.data_health_keys(v_fn);
  select * into r from data_health_runs order by ran_at desc limit 1;
  if r.id is null then return jsonb_build_object('fn', v_fn, 'ran_at', null, 'issues', 0, 'checks', '[]'::jsonb, 'fixed', '{}'::jsonb); end if;
  return jsonb_build_object('fn', v_fn, 'ran_at', r.ran_at, 'fixed', '{}'::jsonb,
    'checks', coalesce((select jsonb_agg(c || jsonb_build_object('items', coalesce((select jsonb_agg(i || jsonb_build_object('fix', null)) from jsonb_array_elements(c -> 'items') i), '[]'::jsonb))
                                         order by o)
                          from jsonb_array_elements(r.checks) with ordinality e(c, o) where c ->> 'key' = any (v_keys)), '[]'::jsonb),
    'issues', coalesce((select sum((c ->> 'count')::integer) from jsonb_array_elements(r.checks) c where c ->> 'key' = any (v_keys)), 0));
end $$;

-- the Marketplace kits for Sales (r27 consolidation; the Sales Marketing tab builds on it): read only
create or replace function app.staff_marketplace(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare v jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'sales')) then raise exception 'The Marketplace is for Admins and Sales' using errcode = '42501'; end if;
  perform app.staff_view(p_by);
  v := app.marketplace_read(p_by, coalesce(p, '{}'::jsonb));
  perform app.staff_view(null);
  return v;
end $$;

-- ================================================================ 2. Bookings > Now for every office function
create or replace function app.bookings_now_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_full boolean := app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs', 'finance');
  v_sales boolean := app.user_va_has(p_by, 'sales');
  v_field boolean := app.user_is_field(p_by);
  d jsonb;
  k text;
begin
  if not v_full and not v_field and not v_sales then
    raise exception 'Admins and staff only' using errcode = '42501';
  end if;
  d := app.fleet_board(now());
  d := d || jsonb_build_object('scope', case when v_full then 'full' when v_field then 'field' else 'sales' end);
  if v_full then
    -- the list of field staff ids is only for the field view
    foreach k in array array['out', 'going', 'back', 'money', 'stale'] loop
      d := jsonb_set(d, array[k], coalesce((select jsonb_agg(x - 'field_staff') from jsonb_array_elements(d -> k) x), '[]'::jsonb));
    end loop;
    return d;
  end if;
  -- field staff and Sales: the cars, no money; the renter's phone and email only on a field staff member's own jobs
  d := d - 'money';
  d := jsonb_set(d, '{summary}', (d -> 'summary') - 'money' - 'money_cents' - 'money_overdue');
  d := d - 'stale';
  foreach k in array array['out', 'going', 'back'] loop
    d := jsonb_set(d, array[k], coalesce((select jsonb_agg(
            (x - 'pay' - 'deposit' - 'field_staff')
            || jsonb_build_object('renter', case when v_field and coalesce(x -> 'field_staff', '[]'::jsonb) ? p_by::text then x -> 'renter'
                                                 else (x -> 'renter') - 'phone' - 'email' end)
            || case when x ? 'ready' then jsonb_build_object('ready', (x -> 'ready') - 'paid') else '{}'::jsonb end)
          from jsonb_array_elements(d -> k) x), '[]'::jsonb));
  end loop;
  return d;
end $$;

-- ================================================================ 3. Fleet tracking for field staff: their jobs' cars
create or replace function app.field_job_cars(p_user uuid) returns uuid[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(distinct j.vehicle_id), '{}') from field_jobs j
   where j.assigned_to = p_user and j.status in ('scheduled', 'acknowledged', 'in_progress')
     and j.scheduled_at between now() - interval '2 days' and now() + interval '3 days'
$$;

create or replace function app.tracker_assert(p_user uuid, p_manage boolean) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.user_is_admin(p_user) then return; end if;
  if not p_manage and app.user_va_has(p_user, 'fleet') then return; end if;
  -- 0500: field staff read the cars of their own jobs (app.tracker_fleet narrows the answer)
  if not p_manage and app.user_is_field(p_user) then return; end if;
  raise exception '%', case when p_manage then 'Only an Admin can change the trackers' else 'Fleet tracking is for Admins and fleet staff (field staff: the cars of their jobs)' end using errcode = '42501';
end $$;

alter function app.tracker_fleet(uuid, jsonb) rename to tracker_fleet_pre0500;
create function app.tracker_fleet(p_user uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.tracker_fleet_pre0500(p_user, p);
  v_cars uuid[];
begin
  if app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet') then return v; end if;
  v_cars := app.field_job_cars(p_user);
  return v || jsonb_build_object('scope', 'field', 'unpaired', '[]'::jsonb,
    'cars', coalesce((select jsonb_agg(c) from jsonb_array_elements(v -> 'cars') c where (c ->> 'vehicle_id')::uuid = any (v_cars)), '[]'::jsonb),
    'alerts', coalesce((select jsonb_agg(a) from jsonb_array_elements(v -> 'alerts') a where nullif(a ->> 'vehicle_id', '')::uuid = any (v_cars)), '[]'::jsonb),
    'bookings', coalesce((select jsonb_agg(b) from jsonb_array_elements(v -> 'bookings') b where nullif(b ->> 'vehicle_id', '')::uuid = any (v_cars)), '[]'::jsonb),
    'open_alerts', (select count(*) from tracker_alerts where ack_at is null and vehicle_id = any (v_cars)));
end $$;

alter function app.tracker_trip_path(uuid, jsonb) rename to tracker_trip_path_pre0500;
create function app.tracker_trip_path(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet'))
     and not exists (select 1 from tracker_trips t where t.id = nullif(p ->> 'trip', '')::uuid and t.vehicle_id = any (app.field_job_cars(p_user))) then
    raise exception 'Only the trips of the cars of your jobs' using errcode = '42501';
  end if;
  return app.tracker_trip_path_pre0500(p_user, p);
end $$;

-- ================================================================ 4. Call and Text through Quo
alter table program_settings add column if not exists phone_quo_buttons boolean not null default true;
comment on column program_settings.phone_quo_buttons is 'Call and Text buttons (0500): Text opens a composer that sends from the CarmaCars number through Quo and keeps it in the conversation; Call opens the Quo app (or the Quo web app) with the number and logs the call. Off, or with Phone and texts off: the device''s own phone and messages apps.';

-- who may use them: Admins, customer service and Sales for any number; the other staff (fleet, finance, field) for a number
-- that is someone we know (a renter, an owner, a lead or staff), as the Call and Text buttons on their pages show
create or replace function app.phone_button_ok(p_by uuid, p_number text) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_by is null then return false; end if;
  if app.live_staff_ok(p_by) then return true; end if;
  if not (app.user_va_has(p_by) or app.user_is_field(p_by)) then return false; end if;
  return coalesce(app.phone_match(p_number) ->> 'kind', 'unknown') <> 'unknown';
end $$;

create or replace function app.phone_buttons(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare s program_settings := app.settings();
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by) or app.user_is_field(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
  return jsonb_build_object('quo', s.phone_enabled and s.phone_quo_buttons and app.phone_our_number() is not null, 'from', app.phone_our_number(),
    'any_number', app.live_staff_ok(p_by));
end $$;

create or replace function app.phone_booking_of(p jsonb) returns uuid
language sql stable security definer set search_path = public, app as $$
  select b.id from bookings b where b.booking_number = nullif(btrim(coalesce(p ->> 'booking_number', '')), '') limit 1
$$;

create or replace function app.phone_compose(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_number text := app.phone_e164(p ->> 'number');
  v_body text := btrim(coalesce(p ->> 'body', ''));
  v_booking uuid := app.phone_booking_of(p);
  t phone_threads;
  o phone_outbox;
begin
  if v_number is null then raise exception 'That is not a phone number we can text' using errcode = '22023'; end if;
  if not app.phone_button_ok(p_by, v_number) then raise exception 'You can text the people of your work only' using errcode = '42501'; end if;
  if v_body = '' then raise exception 'Write the text first' using errcode = '22023'; end if;
  if length(v_body) > 1600 then raise exception 'A text is at most 1,600 characters' using errcode = '22023'; end if;
  if not (app.settings()).phone_enabled then raise exception 'Phone and texts are off in Program settings' using errcode = '23514'; end if;
  t := app.phone_thread_for(v_number);
  if t.opted_out_at is not null then raise exception 'This number opted out of texts. They can text START to allow them again.' using errcode = '23514'; end if;
  o := app.phone_outbox_put(t.number, v_body, 'staff', coalesce(v_booking, t.booking_id), t.renter_id, null, null, null, now(), 'sending', p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'phone_compose', 'phone_threads', t.id::text, jsonb_build_object('outbox', o.id, 'booking', v_booking, 'chars', length(v_body)));
  return jsonb_build_object('ok', true, 'thread_id', t.id, 'send', jsonb_build_object('id', o.id, 'to', o.to_number, 'body', o.body), 'from', app.phone_our_number());
end $$;

create or replace function app.phone_call_log(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_number text := app.phone_e164(p ->> 'number');
  v_booking uuid := app.phone_booking_of(p);
  t phone_threads;
  a uuid;
begin
  if v_number is null then raise exception 'That is not a phone number' using errcode = '22023'; end if;
  if not app.phone_button_ok(p_by, v_number) then raise exception 'You can call the people of your work only' using errcode = '42501'; end if;
  if not (app.settings()).phone_enabled then return jsonb_build_object('ok', true, 'logged', false); end if;
  t := app.phone_thread_for(v_number);
  -- one attempt a minute per person and number (a double tap logs once)
  if exists (select 1 from phone_activity x where x.thread_id = t.id and x.kind = 'call' and x.direction = 'out' and x.status = 'dialed' and x.sent_by = p_by
              and x.started_at > now() - interval '1 minute') then
    return jsonb_build_object('ok', true, 'logged', false, 'thread_id', t.id);
  end if;
  insert into phone_activity (thread_id, kind, direction, status, started_at, renter_id, owner_id, lead_id, staff_user_id, booking_id, sent_by)
  values (t.id, 'call', 'out', 'dialed', now(), t.renter_id, t.owner_id, t.lead_id, t.staff_user_id, coalesce(v_booking, t.booking_id), p_by)
  returning id into a;
  update phone_threads set last_at = now(), last_preview = 'Call started from the site', last_direction = 'out' where id = t.id;
  return jsonb_build_object('ok', true, 'logged', true, 'thread_id', t.id, 'id', a);
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0500;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if p_call = 'va_read' and p_name in ('live_map', 'visitor_history', 'data_health', 'marketplace') then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'live_map' then app.staff_live_map(p_user, p_ - '_va')
      when 'visitor_history' then app.staff_visitor_history(p_user, p_ - '_va')
      when 'data_health' then app.staff_data_health(p_user)
      else app.staff_marketplace(p_user, p_ - '_va') end;
  end if;
  if p_call in ('admin_read', 'va_read', 'ops_read', 'field_read') and p_name = 'phone_buttons' then
    perform app.door_begin(p_user, p_aal);
    return app.phone_buttons(p_user);
  end if;
  if p_call in ('admin_do', 'va_do', 'ops_do', 'field_do') and p_name in ('phone_compose', 'phone_call_log') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'phone_compose' then app.phone_compose(p_user, p_ - '_va') else app.phone_call_log(p_user, p_ - '_va') end;
  end if;
  return app.door_pre0500(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0500(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges (the replaced functions keep theirs)
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('staff_view', 'staff_live_map', 'staff_visitor_history', 'data_health_keys', 'staff_data_health', 'staff_marketplace',
              'field_job_cars', 'tracker_fleet', 'tracker_fleet_pre0500', 'tracker_trip_path', 'tracker_trip_path_pre0500',
              'phone_button_ok', 'phone_buttons', 'phone_booking_of', 'phone_compose', 'phone_call_log', 'door_pre0500') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
