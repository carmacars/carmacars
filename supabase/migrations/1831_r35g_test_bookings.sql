-- 1831_r35g_test_bookings.sql
-- r35 gaps, item 3 (owner, 997 and 999: "The 2023 Toyota Corolla LE is not letting me delete it because of two active bookings which I believe were
-- test bookings"; "2023 Hyundai ELANTRA the same thing"). An Admin marks a booking as a test (and can take the mark off). A car whose only
-- bookings are test bookings can then be deleted with them: the Admin still types the plate (or the car's name) to confirm, the test bookings
-- are archived with the car's other requests (deleted_booking_requests) and the audit entry names them. A real booking still stops the delete
-- exactly as before (app.vehicle_delete_blockers, 0046), and so does anything else tied to money the car has (invoices, statements, documents ...).
set local check_function_bodies = off;

alter table bookings
  add column if not exists is_test boolean not null default false,
  add column if not exists test_reason text,
  add column if not exists test_by uuid references users (id),
  add column if not exists test_at timestamptz;
comment on column bookings.is_test is 'A test booking (1831), marked by an Admin: it does not stop the delete of its car, and goes with the car.';

do $$
declare d text;
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = 'booking_events'::regclass and conname = 'booking_events_kind_check';
  if d is not null and d not like '%''test_mark''%' then
    execute 'alter table booking_events drop constraint booking_events_kind_check';
    execute 'alter table booking_events add constraint booking_events_kind_check ' || replace(d, 'ARRAY[', 'ARRAY[''test_mark''::text, ');
  end if;
end $$;

-- Admins mark or unmark a booking as a test: audited, and in the booking's history
create or replace function app.set_booking_test(p_by uuid, p_booking uuid, p_on boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin marks a booking as a test' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'No such booking' using errcode = 'P0002'; end if;
  if p_on is not distinct from b.is_test then
    return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'is_test', b.is_test, 'changed', false);
  end if;
  update bookings set is_test = p_on, test_reason = case when p_on then coalesce(v_reason, 'Test booking') end, test_by = p_by, test_at = now() where id = b.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, case when p_on then 'booking_mark_test' else 'booking_unmark_test' end, 'bookings', b.id::text,
          jsonb_build_object('booking_number', b.booking_number, 'is_test', b.is_test),
          jsonb_build_object('booking_number', b.booking_number, 'is_test', p_on, 'reason', v_reason));
  perform app.log_booking_event(b.id, 'test_mark', b.status::text, b.status::text, null,
    case when p_on then 'Marked as a test booking' || coalesce(': ' || v_reason, '') || '. It does not stop its car from being deleted.'
         else 'Made a real booking again' || coalesce(': ' || v_reason, '') end,
    p_by, 'staff', jsonb_build_object('is_test', p_on, 'reason', v_reason));
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'is_test', p_on, 'changed', true);
end $$;

CREATE OR REPLACE FUNCTION app.vehicle_delete_blockers(p_vehicle uuid)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  v vehicles;
  b text[] := '{}';
  n bigint;
  v_nums text;
  t record;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return array['Vehicle not found']; end if;
  select count(*), string_agg(x.booking_number, ', ' order by x.booking_number) into n, v_nums
    from (select bk.booking_number from bookings bk where bk.vehicle_id = v.id and not bk.is_test and not app.booking_never_confirmed(bk.id) order by bk.booking_number limit 1000) x;
  if n > 0 then b := b || format('%s confirmed or paid booking%s (%s)', n, case when n = 1 then '' else 's' end,
                                 case when n > 5 then split_part(v_nums, ', ', 1) || ', ' || split_part(v_nums, ', ', 2) || ' and ' || (n - 2) || ' more' else v_nums end); end if;
  select count(*) into n from booking_vehicle_swaps w where (w.from_vehicle_id = v.id or w.to_vehicle_id = v.id) and not exists (select 1 from bookings tb where tb.id = w.booking_id and tb.is_test);
  if n > 0 then b := b || format('%s vehicle swap(s)', n); end if;
  select count(*) into n from payments p where p.booking_id in (select id from bookings where vehicle_id = v.id and not is_test);
  if n > 0 then b := b || format('%s payment(s)', n); end if;
  select count(*) into n from owner_invoices i where i.vehicle_id = v.id and (i.status not in ('draft', 'void') or i.paid_cents > 0);
  if n > 0 then b := b || format('%s owner invoice(s) issued', n); end if;
  for t in select * from (values
      ('owner_statement_vehicles', 'owner statement line(s)'), ('booking_splits', 'booking split(s)'), ('company_statement_lines', 'company statement line(s)'),
      ('toll_tickets', 'toll or ticket notice(s)'), ('damage_intakes', 'damage intake(s)'), ('incidents', 'incident(s)'), ('turo_trips', 'Turo trip(s)'),
      ('company_expenses', 'expense(s)'), ('owner_deductions', 'owner deduction(s)'), ('vehicle_prepaids', 'prepaid month(s)'),
      ('referral_kickbacks', 'referral kickback(s)'), ('fleet_report_vehicles', 'fleet report line(s)')) x(tbl, label) loop
    if to_regclass('public.' || t.tbl) is not null then
      execute format('select count(*) from public.%I x where x.vehicle_id = $1%s', t.tbl,
                     case when t.tbl = 'booking_splits' then ' and not exists (select 1 from bookings tb where tb.id = x.booking_id and tb.is_test)' else '' end) into n using v.id;
      if n > 0 then b := b || format('%s %s', n, t.label); end if;
    end if;
  end loop;
  if not coalesce(v.is_sample, false) then
    select count(*) into n from vehicle_schedules s where s.vehicle_id = v.id and (s.signed_at is not null or s.document_id is not null);
    if n > 0 then b := b || format('%s signed vehicle schedule(s)', n); end if;
  end if;
  select count(*) into n from documents d where d.vehicle_id = v.id and d.purged_at is null;
  if n > 0 then b := b || format('%s stored document(s)', n); end if;
  return b;
end $function$;

CREATE OR REPLACE FUNCTION app.vehicle_delete_removes(p_vehicle uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status::text, 'is_test', b.is_test,
           'renter', r.legal_name, 'pickup_at', b.pickup_at,
           'text', format('%s, %s, %s, pickup %s', b.booking_number, replace(b.status::text, '_', ' '), coalesce(r.legal_name, 'renter'),
                          to_char(b.pickup_at at time zone 'America/Toronto', 'Mon DD, YYYY')))
           order by b.pickup_at, b.booking_number), '[]'::jsonb)
    from bookings b left join renters r on r.id = b.renter_id
   where b.vehicle_id = p_vehicle and (b.is_test or app.booking_never_confirmed(b.id))
$function$;

CREATE OR REPLACE FUNCTION app.vehicle_delete(p_by uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  v vehicles;
  v_block text[];
  v_files jsonb;
  v_removes jsonb;
  v_confirm text := upper(regexp_replace(coalesce(p ->> 'confirm', ''), '\s', '', 'g'));
  n integer;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = (p ->> 'vehicle_id')::uuid for update;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  if not coalesce((p ->> 'bulk')::boolean, false)
     and v_confirm not in (upper(regexp_replace(coalesce(v.plate, '-'), '\s', '', 'g')), upper(regexp_replace(app.vehicle_name(v.id), '\s', '', 'g'))) then
    raise exception 'Type the plate (or the car''s name, %) to confirm', app.vehicle_name(v.id) using errcode = '22023';
  end if;
  v_block := app.vehicle_delete_blockers(v.id);
  if cardinality(v_block) > 0 then
    raise exception 'This car cannot be deleted: it has %. Retire it instead', array_to_string(v_block, ', ') using errcode = '23514';
  end if;
  v_removes := app.vehicle_delete_removes(v.id);
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_files from (
    select jsonb_build_object('bucket', 'vehicle-public', 'path', ph.processed_path) as x from vehicle_photos ph where ph.vehicle_id = v.id and ph.processed_path is not null
    union all select jsonb_build_object('bucket', 'vehicle-originals', 'path', ph.original_path) from vehicle_photos ph where ph.vehicle_id = v.id and ph.original_path is not null
    union all select jsonb_build_object('bucket', 'vehicle-originals', 'path', ph.uncovered_path) from vehicle_photos ph where ph.vehicle_id = v.id and ph.uncovered_path is not null
    union all select jsonb_build_object('bucket', 'vehicle-public', 'path', vv ->> 'path')
                from vehicle_photos ph cross join lateral jsonb_array_elements(case when jsonb_typeof(ph.variants) = 'array' then ph.variants else '[]'::jsonb end) vv
               where ph.vehicle_id = v.id and vv ->> 'path' is not null) q;
  -- the requests: archived, then removed with the car
  insert into deleted_booking_requests (booking_id, booking_number, vehicle_id, vehicle_name, renter_id, status, pickup_at, return_at, booking, events, offers, message_ids, deleted_by)
  select b.id, b.booking_number, v.id, app.vehicle_name(v.id), b.renter_id, b.status::text, b.pickup_at, b.return_at, to_jsonb(b),
         coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at) from booking_events e where e.booking_id = b.id), '[]'::jsonb),
         coalesce((select jsonb_agg(to_jsonb(o) order by o.version) from booking_offers o where o.booking_id = b.id), '[]'::jsonb),
         coalesce((select jsonb_agg(m.id) from messages m where m.booking_id = b.id), '[]'::jsonb), p_by
    from bookings b where b.vehicle_id = v.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before)
  values (p_by, 'vehicle_delete', 'vehicles', v.id::text,
          jsonb_build_object('name', app.vehicle_name(v.id), 'vin', v.vin, 'plate', v.plate, 'supply_type', v.supply_type, 'is_sample', v.is_sample, 'status', v.status,
                             'requests_removed', v_removes, 'test_bookings', (select coalesce(jsonb_agg(b.booking_number order by b.booking_number), '[]'::jsonb) from bookings b where b.vehicle_id = v.id and b.is_test)));
  perform set_config('app.vehicle_delete', v.id::text, true);
  if jsonb_array_length(v_removes) > 0 then
    alter table booking_events disable trigger booking_events_append_only;
    alter table messages disable trigger messages_append_only;
  end if;
  n := app.purge_rows('public.vehicles'::regclass, format('id = %L', v.id));
  if jsonb_array_length(v_removes) > 0 then
    alter table booking_events enable trigger booking_events_append_only;
    alter table messages enable trigger messages_append_only;
  end if;
  perform set_config('app.vehicle_delete', '', true);
  return jsonb_build_object('vehicle_id', v.id, 'deleted', true, 'rows', n, 'files', v_files, 'requests_removed', v_removes);
end $function$;

-- the booking page's detail carries the mark
alter function app.admin_booking_detail(uuid) rename to admin_booking_detail_pre1831;
create function app.admin_booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_booking_detail_pre1831(p_booking);
begin
  if v is null then return v; end if;
  return v || jsonb_build_object('test', coalesce((select jsonb_build_object('on', b.is_test, 'reason', b.test_reason, 'at', b.test_at,
                                                    'by', (select u.full_name from users u where u.id = b.test_by)) from bookings b where b.id = p_booking), '{}'::jsonb));
end $$;

-- the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1831;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'admin_do') and p_name = 'booking_test_set' then
    perform app.door_begin(p_user, p_aal);
    return app.set_booking_test(p_user, (select b.id from bookings b where b.id::text = coalesce(nullif(p ->> 'booking_id', ''), p ->> 'booking') or b.booking_number = upper(btrim(coalesce(p ->> 'booking', '')))),
                                coalesce((p ->> 'on')::boolean, true), p ->> 'reason');
  end if;
  return app.door_pre1831(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare
  g text;
  pair text[];
begin
  foreach pair slice 1 in array array[
      array['app.admin_booking_detail(uuid)', 'app.admin_booking_detail_pre1831(uuid)'],
      array['app.door(uuid, text, text, text, jsonb)', 'app.door_pre1831(uuid, text, text, text, jsonb)']] loop
    execute format('revoke all on function %s from public, anon, authenticated', pair[1]);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, pair[2]::regprocedure, 'execute') then execute format('grant execute on function %s to %I', pair[1], g); end if;
    end loop;
  end loop;
  foreach pair slice 1 in array array[array['app.set_booking_test(uuid, uuid, boolean, text)'], array['app.admin_booking_detail_pre1831(uuid)'], array['app.door_pre1831(uuid, text, text, text, jsonb)']] loop
    execute format('revoke all on function %s from public, anon, authenticated', pair[1]);
    execute format('grant execute on function %s to service_role', pair[1]);
  end loop;
end $$;
