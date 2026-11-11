-- 1107_r35x_prepare_progress.sql
-- Release 35, UX batch (docs/changes/2026-11-09-r35-ux-batch.md). SCHEMA_MARKER 1109 (1106 to 1109 are one batch).
-- The owner, November 9:
--   "it should be clear to field staff what add ons are necessary to prepare for each rental."
--   "sales and fleet and customer service should also be able to see the field staff's progress on preparing each rental
--    (when they click the car or something)."
-- Field staff already tick each add-on as in the car before the pickup (0930's field_addon_ticks, audited; the handover
-- waits for every tick). The Prepare checklist is the same list, shown on every pickup and delivery card and job. This adds
-- its progress, read only, for the office: app.prepare_progress gives, for a booking (or a car's next booking), the
-- add-ons with their quantities, each ticked or not with who and when, the count, and the pickup or delivery job with its
-- status, its field person and its time. ops_read 'prepare_progress' answers an Admin and every staff function (Sales,
-- customer service, Fleet, Finance); field staff read it on their own cards as before.
set local check_function_bodies = off;

create or replace function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- p: booking (id or number), or vehicle (the car's next booking not yet handed over)
create or replace function app.prepare_progress(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_items jsonb;
  j record;
begin
  if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs', 'sales', 'fleet', 'finance')) then
    raise exception 'Only an Admin or staff read the preparation of a rental' using errcode = '42501';
  end if;
  if coalesce(p ->> 'booking', '') <> '' then
    select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(p ->> 'booking'));
  elsif coalesce(p ->> 'vehicle', '') <> '' then
    select * into b from bookings x
     where x.vehicle_id::text = p ->> 'vehicle' and x.status in ('pending_payment', 'confirmed', 'tentative') and x.handed_over_at is null
       and x.booking_type <> 'owner' and x.pickup_at > now() - interval '1 day'
     order by x.pickup_at limit 1;
  end if;
  if b.id is null then return null; end if;
  v_items := app.fx_addons(b.id);
  select fj.id, fj.kind, fj.status, fj.scheduled_at, fj.started_at, fj.completed_at, (select u.full_name from users u where u.id = fj.assigned_to) as who
    into j from field_jobs fj
   where fj.booking_id = b.id and fj.kind in ('handover', 'delivery') and fj.status <> 'cancelled'
   order by fj.scheduled_at desc limit 1;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at,
    'items', v_items, 'total', jsonb_array_length(v_items),
    'ticked', (select count(*) from jsonb_array_elements(v_items) x where (x ->> 'ticked')::boolean),
    'job', case when j.id is not null then jsonb_build_object('id', j.id, 'kind', j.kind, 'status', j.status, 'scheduled_at', j.scheduled_at,
                                                               'started_at', j.started_at, 'completed_at', j.completed_at, 'who', j.who) end);
end $$;
comment on function app.prepare_progress(uuid, jsonb) is 'The Prepare checklist of a rental (1107): its add-ons in the car, each ticked or not by field staff (who, when), and the pickup or delivery job. Read only, for an Admin and every staff function.';

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1107;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'admin_read', 'va_read') and p_name = 'prepare_progress' then
    perform app.door_begin(p_user, p_aal);
    return app.prepare_progress(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1107(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1107(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['prepare_progress', 'door_pre1107'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
