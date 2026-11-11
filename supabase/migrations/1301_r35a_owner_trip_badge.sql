-- 1301_r35a_owner_trip_badge.sql
-- Release 35, part A (helper A), task 4 (docs/changes/2026-11-11-r35a-request-offers.md). The owner: when an owner books their
-- own car, a clear "Owner's own trip ($0)" badge on requests, bookings, lists, the calendar and the staff alert when it comes
-- in, so a salesperson is not confused by a $0 booking.
--   1. A staff alert when an owner books their own car (rule owner_trip_new: the Admins and customer service, Sales and
--      Fleet on duty), titled "Owner's own trip ($0)". The other booking alerts already leave owner trips out (sa_booking_ok).
--   2. The request's To do says it too ("Owner's own trip ($0): booking request N"), so nobody prices it.
--   3. app.booking_cards (Requests and offers, All bookings) carries owner_trip for the badge on each row.
-- No applied migration is edited.
set local check_function_bodies = off;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('owner_trip_new', 'Owner booked their own car ($0)', 'Bookings', '{admin,on_duty:cs,on_duty:sales,on_duty:fleet}', 'normal', 'requests', true, false,
   'An owner booked their own car for their own use (1301): no charge, nothing to price or send. Get the car ready for the dates.', 46)
on conflict (rule) do nothing;

create function app.owner_trip_words() returns text language sql immutable as $$ select 'Owner''s own trip ($0)'::text $$;

create function app.owner_trip_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.staff_alert('owner_trip_new', 'booking', new.id, 'new',
    left(app.owner_trip_words() || ': ' || app.sa_booking_line(new), 200),
    left(format('The owner booked their own car, %s to %s. No charge: nothing to price or send. Get the car ready.', app.fmt_at(new.pickup_at), app.fmt_at(new.return_at)), 240),
    app.sa_booking_paths(new));
  return null;
end $$;
create trigger bookings_owner_trip_alert after insert on bookings
  for each row when (new.booking_type = 'owner') execute function app.owner_trip_after();

-- the request's To do names it
create function app.owner_trip_task_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from bookings b where b.id = new.booking_id and b.booking_type = 'owner') and new.title not like app.owner_trip_words() || '%' then
    new.title := left(app.owner_trip_words() || ': ' || new.title, 200);
    new.detail := 'The owner booked their own car: no charge, nothing to price or send. ' || coalesce(new.detail, '');
  end if;
  return new;
end $$;
create trigger tasks_owner_trip_title before insert on tasks
  for each row when (new.task_type = 'booking_request' and new.booking_id is not null) execute function app.owner_trip_task_before();

-- the rows' cards: owner_trip
alter function app.booking_cards(uuid, jsonb) rename to booking_cards_pre1301;
create function app.booking_cards(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.booking_cards_pre1301(p_by, p);
  x record;
begin
  for x in select b.id from bookings b where b.id = any (app.uuid_list(p -> 'ids', 300)) and b.booking_type = 'owner' loop
    if v ? x.id::text then v := jsonb_set(v, array[x.id::text, 'owner_trip'], 'true'::jsonb); end if;
  end loop;
  return v;
end $$;

-- booking_cards keeps the grants it had
do $$
declare g text;
begin
  execute 'revoke all on function app.booking_cards(uuid, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.booking_cards_pre1301(uuid, jsonb)', 'execute') then execute format('grant execute on function app.booking_cards(uuid, jsonb) to %I', g); end if;
  end loop;
end $$;
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['owner_trip_after', 'owner_trip_task_before', 'booking_cards_pre1301'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
grant execute on function app.owner_trip_words() to authenticated, service_role;
