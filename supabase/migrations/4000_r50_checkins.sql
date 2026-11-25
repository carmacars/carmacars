-- 4000 (release 50; docs/changes/2026-11-24-r50-checkins.md): monthly check-in visits for long-term renters.
--
-- The owner (Nov 24): a renter on a long rental (about 30 days or more, a long-term weekly rental, a rideshare driver)
-- is asked, never required and never charged, to bring the car in about once a month so staff can look at its condition
-- and damage and see whether maintenance is due. Built on what exists:
--   eligibility        a rental of at least checkin_min_days (28), a long-term weekly rental (rolling_rentals, 2981), a
--                      rideshare driver (rideshare_doc_requests, 1303) or a booking switched on by staff; on by default
--                      (checkin_enabled), and a booking can be switched off (checkin_booking_switch)
--   the schedule       the next visit is checkin_interval_days (30) after the pickup or the last visit; the visit is made
--                      checkin_lead_days (5) before it is due, with the renter's reminder (email and text through the
--                      notification routing: the channel policy of 2971 and sms_opt_out_at of 0085 apply), and one gentle
--                      follow-up on the due date when no time was picked
--   a time             the renter picks a slot at the office (checkin_slot_minutes, opening hours, checkin_slot_capacity
--                      a slot) or asks for a time by request (staff confirm); Fleet and the Admins are told
--                      (staff_checkin_booked), and the morning of the day (staff_checkin_today)
--   the visit          a short checklist by staff (Admin, customer service, Fleet, field work): photos of the four sides
--                      and the odometer, damage, tire tread, fluids and warning lights, notes. It writes the odometer
--                      reading (source checkin) and the tread of the tires on the car into the maintenance tracker (0089),
--                      snapshots the next service due, raises a Fleet To do when something needs maintenance, and logs a
--                      damage intake (the Damage tab, 0021) with an Admin To do when damage is found
--   records            the booking's timeline (log_booking_event), the owner's car page (maint_owner_history: the
--                      visits of their car, condition only)
-- Staff read and write through the door: ops_read/field_read checkin_queue and checkin_visit, ops_do/field_do checkin_do.
-- The renter: public.server_checkin_renter, server_checkin_book (the server role, for the signed-in renter).
-- New tables: row-level security with admin_all, the audit trigger. No applied migration is edited: the door and
-- maint_owner_history are wrapped (_pre4000). SCHEMA_MARKER 4002.
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

-- ================================================================ 1. settings, tables
alter table program_settings
  add column if not exists checkin_enabled boolean not null default true,
  add column if not exists checkin_min_days integer not null default 28 check (checkin_min_days between 7 and 365),
  add column if not exists checkin_interval_days integer not null default 30 check (checkin_interval_days between 7 and 120),
  add column if not exists checkin_lead_days integer not null default 5 check (checkin_lead_days between 1 and 30),
  add column if not exists checkin_slot_minutes integer not null default 30 check (checkin_slot_minutes in (15, 20, 30, 45, 60)),
  add column if not exists checkin_day_start_hour integer not null default 10 check (checkin_day_start_hour between 6 and 20),
  add column if not exists checkin_day_end_hour integer not null default 18 check (checkin_day_end_hour between 8 and 22),
  add column if not exists checkin_slot_capacity integer not null default 2 check (checkin_slot_capacity between 1 and 10),
  add column if not exists checkin_place_text text not null default 'At the CarmaCars office' check (char_length(checkin_place_text) between 3 and 200);
comment on column program_settings.checkin_enabled is 'r50 (4000): monthly check-in visits for long-term renters, on by default. A suggestion to the renter, never a requirement or a fee.';
comment on column program_settings.checkin_min_days is 'r50 (4000): a rental this many days or longer gets monthly check-in visits (28 by default); long-term weekly rentals and rideshare drivers always do.';
comment on column program_settings.checkin_interval_days is 'r50 (4000): days between check-in visits, from the pickup or the last visit (30 by default).';
comment on column program_settings.checkin_lead_days is 'r50 (4000): the renter''s reminder goes this many days before a visit is due (5 by default); one follow-up on the due date if no time was picked.';

create table if not exists checkin_booking_switch (
  booking_id  uuid primary key references bookings (id) on delete cascade,
  mode        text not null check (mode in ('on', 'off')),
  set_by      uuid references users (id) on delete set null,
  set_at      timestamptz not null default now()
);
create index if not exists checkin_booking_switch_set_by_idx on checkin_booking_switch (set_by) where set_by is not null;
comment on table checkin_booking_switch is 'r50 (4000): check-in visits switched on (any booking) or off for one booking by staff. No row: the eligibility rule.';

create table if not exists checkin_visits (
  id               uuid primary key default gen_random_uuid(),
  booking_id       uuid not null references bookings (id) on delete cascade,
  vehicle_id       uuid not null references vehicles (id) on delete cascade,
  due_on           date not null,
  status           text not null default 'due' check (status in ('due', 'booked', 'done', 'skipped', 'cancelled')),
  place            text check (place in ('office', 'request')),
  slot_at          timestamptz,
  request_note     text check (char_length(request_note) <= 500),
  booked_by        uuid references users (id) on delete set null,
  booked_at        timestamptz,
  reminded_at      timestamptz,
  followup_at      timestamptz,
  today_told_on    date,
  done_at          timestamptz,
  done_by          uuid references users (id) on delete set null,
  odometer_km      integer check (odometer_km between 1 and 2000000),
  photos           jsonb not null default '[]'::jsonb check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 20),
  damage_found     boolean,
  damage_note      text check (char_length(damage_note) <= 1000),
  tread_mm         numeric(4, 1) check (tread_mm between 0 and 20),
  fluids_ok        boolean,
  warning_lights   text check (char_length(warning_lights) <= 300),
  next_service     jsonb,
  notes            text check (char_length(notes) <= 2000),
  task_id          uuid references tasks (id) on delete set null,
  damage_intake_id uuid references damage_intakes (id) on delete set null,
  closed_reason    text check (char_length(closed_reason) <= 300),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (status <> 'booked' or (place is not null and (slot_at is not null or place = 'request'))),
  check (status <> 'done' or (done_at is not null and odometer_km is not null))
);
create unique index if not exists checkin_visits_one_open on checkin_visits (booking_id) where status in ('due', 'booked');
create index if not exists checkin_visits_booking_idx on checkin_visits (booking_id, due_on desc);
create index if not exists checkin_visits_vehicle_idx on checkin_visits (vehicle_id, due_on desc);
create index if not exists checkin_visits_open_idx on checkin_visits (due_on) where status in ('due', 'booked');
create index if not exists checkin_visits_slot_idx on checkin_visits (slot_at) where status = 'booked';
create index if not exists checkin_visits_task_idx on checkin_visits (task_id) where task_id is not null;
create index if not exists checkin_visits_damage_idx on checkin_visits (damage_intake_id) where damage_intake_id is not null;
comment on table checkin_visits is 'r50 (4000): one monthly check-in visit of a long-term rental: due, booked (a slot at the office or by request), done (the checklist), skipped or cancelled. Read and written through the door and the renter''s server functions only.';

create trigger checkin_visits_updated before update on checkin_visits for each row execute function app.set_updated_at();
create trigger audit_checkin_visits after insert or update or delete on checkin_visits for each row execute function app.audit_row();
create trigger audit_checkin_booking_switch after insert or update or delete on checkin_booking_switch for each row execute function app.audit_row();

alter table checkin_visits enable row level security;
alter table checkin_booking_switch enable row level security;
create policy admin_all on checkin_visits for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on checkin_booking_switch for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on checkin_visits, checkin_booking_switch from public, anon, authenticated;
grant select on checkin_visits, checkin_booking_switch to authenticated;
grant all on checkin_visits, checkin_booking_switch to service_role;

-- the odometer reading of a visit feeds the maintenance tracker
alter table vehicle_odometer_readings drop constraint if exists vehicle_odometer_readings_source_check;
alter table vehicle_odometer_readings add constraint vehicle_odometer_readings_source_check
  check (source in ('handover', 'return', 'condition_report', 'move', 'rental', 'listing', 'car', 'service', 'manual', 'checkin'));

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('checkin_maintenance', 'fleet', 'Check-in visit: maintenance to book', 'normal', 'none', null,
   'A monthly check-in visit (4000) found something to look after: a service due soon or overdue, low tire tread, fluids or a warning light. Book it with the renter and record it on the car''s Maintenance tab.'),
  ('checkin_damage', 'admin', 'Check-in visit: damage found', 'high', 'none', null,
   'A monthly check-in visit (4000) found damage on a car that is out on a long rental. A damage intake is logged with the photos (Damage tab): match it and choose how it is billed.')
on conflict (task_type) do nothing;

-- ================================================================ 2. the rules
create function app.checkin_staff(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select p_by is not null and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet') or app.user_is_field(p_by))
$$;

-- whether a booking gets check-in visits (confirmed or out), and why
create function app.checkin_why(b bookings) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case
    when b.id is null or b.booking_type = 'owner' or b.status not in ('confirmed', 'on_rent') then null
    when not coalesce((app.settings()).checkin_enabled, true) then null
    when (select mode from checkin_booking_switch w where w.booking_id = b.id) = 'off' then null
    when (select mode from checkin_booking_switch w where w.booking_id = b.id) = 'on' then 'switched_on'
    when exists (select 1 from rolling_rentals r where r.booking_id = b.id and r.stopped_at is null) then 'rolling'
    when exists (select 1 from rideshare_doc_requests x where x.booking_id = b.id) then 'rideshare'
    when b.return_at - b.pickup_at >= make_interval(days => coalesce((app.settings()).checkin_min_days, 28)) then 'long'
    else null end
$$;

-- the next visit's due date: the interval after the last visit (done, skipped) or the pickup; null when the rental ends first
create function app.checkin_next_due(b bookings) returns date
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when app.checkin_why(b) is null then null
              when d > app.local_date(b.return_at) and not exists (select 1 from rolling_rentals r where r.booking_id = b.id and r.stopped_at is null) then null
              else d end
    from (select coalesce((select v.due_on from checkin_visits v where v.booking_id = b.id and v.status in ('due', 'booked')),
                          coalesce((select max(coalesce(app.local_date(v.done_at), v.due_on)) from checkin_visits v where v.booking_id = b.id and v.status in ('done', 'skipped')),
                                   app.local_date(b.pickup_at)) + coalesce((app.settings()).checkin_interval_days, 30)) as d) q
$$;

create function app.checkin_place_words(v checkin_visits) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when v.place = 'request' then 'By request' || coalesce(': ' || v.request_note, '')
              else coalesce((app.settings()).checkin_place_text, 'At the CarmaCars office') end
$$;

create function app.checkin_time_words(v checkin_visits) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when v.slot_at is not null then app.fmt_date(v.slot_at) || ', ' || app.fmt_time(v.slot_at)
              when v.status = 'booked' then 'By request, a time to confirm with the renter'
              else 'Due ' || to_char(v.due_on, 'FMDay, FMMonth FMDD') || ', no time picked yet' end
$$;

-- the office slots offered for a visit: from 3 days before it is due (not before tomorrow) to 7 days after, Monday to
-- Saturday, opening hours, each with room left
create function app.checkin_slots(v checkin_visits, p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with s as (select app.settings() as x),
  days as (
    select d::date as d from s, generate_series(greatest(v.due_on - 3, app.local_date(p_now) + 1), greatest(v.due_on - 3, app.local_date(p_now) + 1) + 10, interval '1 day') d
     where extract(isodow from d) between 1 and 6),
  slots as (
    select ((days.d + make_interval(hours => (s.x).checkin_day_start_hour)) + n * make_interval(mins => (s.x).checkin_slot_minutes)) at time zone 'America/Toronto' as at
      from days, s, generate_series(0, (((s.x).checkin_day_end_hour - (s.x).checkin_day_start_hour) * 60 / (s.x).checkin_slot_minutes) - 1) n)
  select coalesce(jsonb_agg(jsonb_build_object('at', sl.at, 'day', app.local_date(sl.at)) order by sl.at), '[]'::jsonb)
    from slots sl, s
   where sl.at > p_now + interval '2 hours'
     and (select count(*) from checkin_visits o where o.status = 'booked' and o.slot_at = sl.at and o.id <> v.id) < (s.x).checkin_slot_capacity
$$;

create function app.checkin_json(v checkin_visits) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('id', v.id, 'booking_id', v.booking_id, 'vehicle_id', v.vehicle_id, 'due_on', v.due_on, 'status', v.status,
    'bucket', case when v.status = 'booked' and coalesce(app.local_date(v.slot_at), v.due_on) < app.today() then 'overdue'
                   when v.status = 'due' and v.due_on < app.today() then 'overdue'
                   when v.status in ('done', 'skipped', 'cancelled') then 'done' else v.status end,
    'place', v.place, 'slot_at', v.slot_at, 'request_note', v.request_note, 'place_words', app.checkin_place_words(v), 'time_words', app.checkin_time_words(v),
    'reminded_at', v.reminded_at, 'followup_at', v.followup_at, 'done_at', v.done_at, 'done_by_name', (select u.full_name from users u where u.id = v.done_by),
    'odometer_km', v.odometer_km, 'damage_found', v.damage_found, 'damage_note', v.damage_note, 'tread_mm', v.tread_mm, 'fluids_ok', v.fluids_ok,
    'warning_lights', v.warning_lights, 'next_service', v.next_service, 'notes', v.notes, 'photos', v.photos, 'closed_reason', v.closed_reason,
    'task_id', v.task_id, 'damage_intake_id', v.damage_intake_id)
$$;

-- ================================================================ 3. the sweep: visits, reminders, the follow-up, staff on the day
create function app.checkin_emit_payload(v checkin_visits) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('booking_id', v.booking_id, 'visit_id', v.id, 'vehicle_id', v.vehicle_id,
    'checkin_due_date', to_char(v.due_on, 'FMDay, FMMonth FMDD'), 'checkin_place', app.checkin_place_words(v),
    'checkin_time', app.checkin_time_words(v), 'checkin_note', coalesce(nullif(btrim(coalesce(v.request_note, '')), ''), 'None'))
$$;

create function app.checkin_sweep(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_today date := app.local_date(p_now);
  b bookings;
  v checkin_visits;
  v_due date;
  n integer := 0;
begin
  -- visits whose rental ended or is no longer eligible close by themselves
  update checkin_visits c set status = 'cancelled', closed_reason = 'The rental ended or no longer has check-in visits'
    from bookings x where x.id = c.booking_id and c.status in ('due', 'booked') and (x.status <> 'on_rent' or app.checkin_why(x) is null);
  if not coalesce(s.checkin_enabled, true) then return 0; end if;
  -- 1. the next visit, the lead days before it is due, with the renter's reminder
  for b in select x.* from bookings x where x.status = 'on_rent' and x.booking_type <> 'owner'
              and not exists (select 1 from checkin_visits c where c.booking_id = x.id and c.status in ('due', 'booked')) limit 200 loop
    v_due := app.checkin_next_due(b);
    continue when v_due is null or v_due - s.checkin_lead_days > v_today;
    insert into checkin_visits (booking_id, vehicle_id, due_on, reminded_at) values (b.id, b.vehicle_id, greatest(v_due, v_today), p_now)
    on conflict do nothing returning * into v;
    continue when v.id is null;
    perform app.ntf_emit('renter_checkin_reminder', 'booking', b.id, 'checkin:' || v.id, app.checkin_emit_payload(v));
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
      format('Check-in visit suggested around %s: the renter was reminded (nothing to pay)', to_char(v.due_on, 'FMMonth FMDD')), null, 'system',
      jsonb_build_object('checkin_visit', v.id, 'due_on', v.due_on));
    n := n + 1;
  end loop;
  -- 2. one gentle follow-up on the due date when no time was picked
  for v in select c.* from checkin_visits c where c.status = 'due' and c.followup_at is null and c.due_on <= v_today limit 200 loop
    update checkin_visits set followup_at = p_now where id = v.id;
    perform app.ntf_emit('renter_checkin_followup', 'booking', v.booking_id, 'checkin_followup:' || v.id, app.checkin_emit_payload(v));
    n := n + 1;
  end loop;
  -- 3. staff, the morning of the day: booked for today, or due today without a time
  if extract(hour from p_now at time zone 'America/Toronto') >= 7 then
    for v in select c.* from checkin_visits c
              where c.today_told_on is distinct from v_today
                and ((c.status = 'booked' and coalesce(app.local_date(c.slot_at), c.due_on) = v_today) or (c.status = 'due' and c.due_on = v_today)) limit 200 loop
      update checkin_visits set today_told_on = v_today where id = v.id;
      perform app.ntf_emit('staff_checkin_today', 'booking', v.booking_id, 'checkin_today:' || v.id || ':' || v_today, app.checkin_emit_payload(v));
      n := n + 1;
    end loop;
  end if;
  return n;
end $$;

-- ================================================================ 4. the renter
create function app.checkin_renter_booking(p_user uuid, p_booking text) returns bookings
language sql stable security definer set search_path = public, app, pg_temp as $$
  select b.* from bookings b join renters r on r.id = b.renter_id
   where r.user_id = p_user and p_user is not null and (b.id::text = p_booking or b.booking_number = upper(btrim(coalesce(p_booking, ''))))
$$;

-- what the renter sees: whether the booking has visits, the next one (around a date), the open visit and the slots
create function public.server_checkin_renter(p_user uuid, p_booking text) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  b bookings := app.checkin_renter_booking(p_user, p_booking);
  v checkin_visits;
begin
  if b.id is null or app.checkin_why(b) is null then return jsonb_build_object('on', false); end if;
  select * into v from checkin_visits where booking_id = b.id and status in ('due', 'booked');
  return jsonb_build_object('on', true, 'booking_number', b.booking_number, 'why', app.checkin_why(b), 'next_on', app.checkin_next_due(b),
    'interval_days', (app.settings()).checkin_interval_days, 'place_text', (app.settings()).checkin_place_text,
    'visit', case when v.id is not null then app.checkin_json(v) - 'photos' - 'notes' - 'task_id' - 'damage_intake_id' - 'done_by_name' end,
    'slots', case when v.id is not null and b.status = 'on_rent' then app.checkin_slots(v) else '[]'::jsonb end,
    'last', (select jsonb_build_object('done_on', app.local_date(x.done_at), 'odometer_km', x.odometer_km) from checkin_visits x
              where x.booking_id = b.id and x.status = 'done' order by x.done_at desc limit 1));
end $$;

-- book a time (shared by the renter and staff): {slot_at} at the office, or {place: request, note}; {cancel: true} takes the time back
create function app.checkin_book(p_by uuid, v checkin_visits, p jsonb, p_staff boolean) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  v_at timestamptz := nullif(p ->> 'slot_at', '')::timestamptz;
  v_place text := coalesce(nullif(p ->> 'place', ''), case when nullif(p ->> 'slot_at', '') is not null then 'office' end);
  v_note text := nullif(left(btrim(coalesce(p ->> 'note', '')), 500), '');
begin
  if v.id is null or v.status not in ('due', 'booked') then raise exception 'There is no check-in visit to book on this rental right now' using errcode = '23514'; end if;
  select * into b from bookings where id = v.booking_id;
  if b.status <> 'on_rent' then raise exception 'A check-in visit is booked while the car is out with you' using errcode = '23514'; end if;
  if coalesce((p ->> 'cancel')::boolean, false) then
    update checkin_visits set status = 'due', place = null, slot_at = null, request_note = null, booked_by = null, booked_at = null where id = v.id returning * into v;
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null, 'Check-in visit: the time was taken back', p_by, case when p_staff then 'staff' else 'renter' end, jsonb_build_object('checkin_visit', v.id));
    return jsonb_build_object('ok', true, 'visit', app.checkin_json(v));
  end if;
  if v_place is null or v_place not in ('office', 'request') then raise exception 'Pick a time at the office, or ask for a time by request' using errcode = '22023'; end if;
  if v_place = 'office' then
    if v_at is null then raise exception 'Pick a time' using errcode = '22023'; end if;
    if not p_staff and not exists (select 1 from jsonb_array_elements(app.checkin_slots(v)) x where (x ->> 'at')::timestamptz = v_at) then
      raise exception 'That time is no longer free: pick another one' using errcode = '23514';
    end if;
    if p_staff and v_at < now() - interval '1 day' then raise exception 'The time is in the past' using errcode = '22023'; end if;
  elsif v_note is null or length(v_note) < 3 then
    raise exception 'Say when and where suits you (for example: weekday evenings, near Yonge and Eglinton)' using errcode = '22023';
  end if;
  update checkin_visits set status = 'booked', place = v_place, slot_at = v_at, request_note = v_note,
         booked_by = p_by, booked_at = now(), today_told_on = null where id = v.id returning * into v;
  perform app.ntf_emit('staff_checkin_booked', 'booking', b.id, 'checkin_booked:' || v.id || ':' || extract(epoch from now())::bigint, app.checkin_emit_payload(v));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    'Check-in visit booked: ' || app.checkin_time_words(v) || ' (' || app.checkin_place_words(v) || ')', p_by, case when p_staff then 'staff' else 'renter' end,
    jsonb_build_object('checkin_visit', v.id, 'slot_at', v.slot_at, 'place', v.place));
  return jsonb_build_object('ok', true, 'visit', app.checkin_json(v));
end $$;

create function public.server_checkin_book(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings := app.checkin_renter_booking(p_user, p ->> 'booking');
  v checkin_visits;
begin
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into v from checkin_visits where booking_id = b.id and status in ('due', 'booked') for update;
  return app.checkin_book(p_user, v, p, false);
end $$;

-- ================================================================ 5. staff: the queue, a visit, the checklist
create function app.checkin_queue(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if not app.checkin_staff(p_by) then raise exception 'Staff only' using errcode = '42501'; end if;
  return jsonb_build_object('today', app.today(), 'may_switch', app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet'),
    'settings', (select jsonb_build_object('enabled', s.checkin_enabled, 'interval_days', s.checkin_interval_days, 'lead_days', s.checkin_lead_days, 'min_days', s.checkin_min_days)
                   from (select (app.settings()).*) s),
    'visits', coalesce((select jsonb_agg(app.checkin_json(v) || jsonb_build_object('booking_number', b.booking_number, 'renter_name', r.legal_name,
                   'renter_phone', r.mobile, 'vehicle_name', concat_ws(' ', vh.year, vh.make, vh.model), 'plate', vh.plate)
                   order by case v.status when 'booked' then 0 when 'due' then 1 else 2 end, coalesce(v.slot_at, app.local_midnight(v.due_on)), v.due_on)
                from checkin_visits v join bookings b on b.id = v.booking_id join vehicles vh on vh.id = v.vehicle_id left join renters r on r.id = b.renter_id
               where v.status in ('due', 'booked') or (v.status in ('done', 'skipped') and coalesce(v.done_at, v.updated_at) > now() - interval '30 days')), '[]'::jsonb),
    'upcoming', coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'next_on', app.checkin_next_due(b),
                   'vehicle_name', concat_ws(' ', vh.year, vh.make, vh.model), 'renter_name', r.legal_name, 'why', app.checkin_why(b)) order by app.checkin_next_due(b))
                from bookings b join vehicles vh on vh.id = b.vehicle_id left join renters r on r.id = b.renter_id
               where b.status = 'on_rent' and app.checkin_why(b) is not null and app.checkin_next_due(b) is not null
                 and not exists (select 1 from checkin_visits c where c.booking_id = b.id and c.status in ('due', 'booked'))), '[]'::jsonb));
end $$;

create function app.checkin_visit_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v checkin_visits;
  b bookings;
begin
  if not app.checkin_staff(p_by) then raise exception 'Staff only' using errcode = '42501'; end if;
  if nullif(p ->> 'id', '') is not null then
    select * into v from checkin_visits where id::text = p ->> 'id';
  else
    select c.* into v from checkin_visits c join bookings x on x.id = c.booking_id
     where x.id::text = p ->> 'booking' or x.booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) order by (c.status in ('due', 'booked')) desc, c.due_on desc limit 1;
  end if;
  select * into b from bookings where id = coalesce(v.booking_id, (select x.id from bookings x where x.id::text = p ->> 'booking' or x.booking_number = upper(btrim(coalesce(p ->> 'booking', '')))));
  if b.id is null then raise exception 'Check-in visit not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('visit', case when v.id is not null then app.checkin_json(v) end,
    'booking', jsonb_build_object('id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at),
    'on', app.checkin_why(b) is not null, 'why', app.checkin_why(b), 'next_on', app.checkin_next_due(b),
    'switch', (select mode from checkin_booking_switch where booking_id = b.id),
    'may_switch', app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet'),
    'car', (select jsonb_build_object('name', concat_ws(' ', vh.year, vh.make, vh.model), 'plate', vh.plate, 'current_km', app.maint_current_km(vh.id),
              'tread_mm', (select t.tread_mm from vehicle_tire_sets t where t.vehicle_id = vh.id and t.on_car and t.retired_on is null order by t.tread_measured_on desc nulls last limit 1),
              'next', app.maint_owner_history_pre4000(vh.id) -> 'next')
              from vehicles vh where vh.id = b.vehicle_id),
    'renter', (select jsonb_build_object('name', r.legal_name, 'phone', r.mobile) from renters r where r.id = b.renter_id),
    'history', coalesce((select jsonb_agg(app.checkin_json(x) - 'photos' order by x.due_on desc) from checkin_visits x where x.booking_id = b.id and x.id is distinct from v.id), '[]'::jsonb),
    'slots', case when v.id is not null and v.status in ('due', 'booked') then app.checkin_slots(v) else '[]'::jsonb end);
end $$;

-- the checklist. p: {id, odometer_km, photos: [{angle, bucket, path}] (front, rear, left, right, odometer), damage_found,
-- damage_note, tread_mm, fluids_ok, warning_lights, notes}
create function app.checkin_complete(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v checkin_visits;
  b bookings;
  vh vehicles;
  v_km integer := nullif(p ->> 'odometer_km', '')::numeric::integer;
  v_photos jsonb := case when jsonb_typeof(p -> 'photos') = 'array' then p -> 'photos' else '[]'::jsonb end;
  v_damage boolean := (p ->> 'damage_found')::boolean;
  v_dnote text := nullif(left(btrim(coalesce(p ->> 'damage_note', '')), 1000), '');
  v_tread numeric := nullif(p ->> 'tread_mm', '')::numeric;
  v_fluids boolean := (p ->> 'fluids_ok')::boolean;
  v_lights text := nullif(left(btrim(coalesce(p ->> 'warning_lights', '')), 300), '');
  v_notes text := nullif(left(btrim(coalesce(p ->> 'notes', '')), 2000), '');
  v_missing text[];
  v_next jsonb;
  v_issues text[] := '{}';
  v_task uuid;
  v_di uuid;
  v_prev integer;
begin
  select * into v from checkin_visits where id::text = p ->> 'id' for update;
  if v.id is null then raise exception 'Check-in visit not found' using errcode = 'P0002'; end if;
  if v.status not in ('due', 'booked') then raise exception 'This check-in visit is already %', v.status using errcode = '23514'; end if;
  select * into b from bookings where id = v.booking_id;
  select * into vh from vehicles where id = v.vehicle_id;
  select array_agg(a) into v_missing from unnest(array['front', 'rear', 'left', 'right', 'odometer']) a
   where not exists (select 1 from jsonb_array_elements(v_photos) x where x ->> 'angle' = a and coalesce(x ->> 'path', '') ~ ('^bookings/' || v.booking_id || '/checkin/[0-9a-f-]{36}\.(jpg|png)$'));
  if v_missing is not null then raise exception 'Add the photos still missing: %', array_to_string(v_missing, ', ') using errcode = '22023'; end if;
  if v_km is null then raise exception 'Enter the odometer reading' using errcode = '22023'; end if;
  v_prev := app.maint_current_km(v.vehicle_id);
  if v_prev is not null and v_km < v_prev then raise exception 'The odometer reads % km: the last reading was % km', v_km, v_prev using errcode = '22023'; end if;
  if v_damage is null then raise exception 'Say whether there is any new damage' using errcode = '22023'; end if;
  if v_damage and (v_dnote is null or length(v_dnote) < 3) then raise exception 'Describe the damage: where and what' using errcode = '22023'; end if;
  if v_fluids is null then raise exception 'Say whether the fluids look right' using errcode = '22023'; end if;
  if v_tread is not null and (v_tread < 0 or v_tread > 20) then raise exception 'Tire tread is in millimetres, 0 to 20' using errcode = '22023'; end if;

  -- the maintenance tracker: the reading and the tread of the tires on the car
  insert into vehicle_odometer_readings (vehicle_id, km, source, source_id, created_by) values (v.vehicle_id, v_km, 'checkin', v.id, p_by)
  on conflict do nothing;
  if v_tread is not null then
    update vehicle_tire_sets set tread_mm = v_tread, tread_measured_on = app.today() where vehicle_id = v.vehicle_id and on_car and retired_on is null;
  end if;
  v_next := app.maint_owner_history_pre4000(v.vehicle_id) -> 'next';

  if v_next is not null and v_next ->> 'status' in ('due_soon', 'overdue') then v_issues := v_issues || (format('%s %s', v_next ->> 'label', replace(v_next ->> 'status', '_', ' '))); end if;
  if v_tread is not null and v_tread < 3 then v_issues := v_issues || format('tire tread %s mm', v_tread); end if;
  if not v_fluids then v_issues := v_issues || 'fluids to top up or check'::text; end if;
  if v_lights is not null and lower(v_lights) not in ('none', 'no', 'n/a', '-') then v_issues := v_issues || ('warning light: ' || v_lights); end if;

  if cardinality(v_issues) > 0 then
    v_task := app.raise_task(p_type => 'checkin_maintenance', p_title => 'Maintenance from a check-in visit: ' || concat_ws(' ', vh.year, vh.make, vh.model),
      p_detail => format('Check-in visit on booking %s found: %s. Odometer %s km. Book it with the renter and record it on the car''s Maintenance tab.', b.booking_number, array_to_string(v_issues, '; '), v_km),
      p_booking => b.id, p_vehicle => v.vehicle_id, p_renter => b.renter_id, p_related_table => 'checkin_visits', p_related_id => v.id,
      p_priority => case when v_next ->> 'status' = 'overdue' or (v_tread is not null and v_tread < 2) then 'high' else 'normal' end,
      p_dedupe => 'checkin_maintenance:' || v.id, p_queue => 'fleet', p_created_by => p_by);
  end if;
  if v_damage then
    insert into damage_intakes (vehicle_id, found_at, window_from, window_to, location, description, photos, booking_id, matched_to, status, created_by)
    values (v.vehicle_id, now(),
            coalesce((select max(x.done_at) from checkin_visits x where x.booking_id = b.id and x.status = 'done'), b.pickup_at), now(),
            'Check-in visit, booking ' || b.booking_number, 'Found at a check-in visit: ' || v_dnote,
            (select coalesce(jsonb_agg(jsonb_build_object('bucket', coalesce(x ->> 'bucket', 'condition-photos'), 'path', x ->> 'path', 'angle', x ->> 'angle')), '[]'::jsonb) from jsonb_array_elements(v_photos) x),
            b.id, 'renter', 'logged', p_by)
    returning id into v_di;
    perform app.raise_task(p_type => 'checkin_damage', p_title => 'Damage found at a check-in visit: ' || b.booking_number,
      p_detail => format('%s. The damage intake is logged with the visit''s photos (Damage tab): check it against the pickup photos, then choose how it is billed.', v_dnote),
      p_booking => b.id, p_vehicle => v.vehicle_id, p_renter => b.renter_id, p_related_table => 'damage_intakes', p_related_id => v_di,
      p_priority => 'high', p_dedupe => 'checkin_damage:' || v.id, p_queue => 'admin', p_created_by => p_by);
  end if;

  update checkin_visits set status = 'done', done_at = now(), done_by = p_by, odometer_km = v_km, photos = v_photos, damage_found = v_damage, damage_note = v_dnote,
         tread_mm = v_tread, fluids_ok = v_fluids, warning_lights = v_lights, next_service = v_next, notes = v_notes, task_id = v_task, damage_intake_id = v_di,
         place = coalesce(place, 'office')
   where id = v.id returning * into v;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('Check-in visit done: %s km, %s%s%s', v_km, case when v_damage then 'damage found (' || v_dnote || ')' else 'no new damage' end,
           case when cardinality(v_issues) > 0 then '; to look after: ' || array_to_string(v_issues, '; ') else '' end,
           coalesce('. Next service: ' || (v_next ->> 'label'), '')),
    p_by, 'staff', jsonb_build_object('checkin_visit', v.id, 'odometer_km', v_km, 'damage', v_damage, 'task_id', v_task, 'damage_intake_id', v_di));
  return jsonb_build_object('ok', true, 'visit', app.checkin_json(v), 'issues', to_jsonb(v_issues), 'task_id', v_task, 'damage_intake_id', v_di,
    'next_on', app.checkin_next_due(b));
end $$;

-- p: {op: book | skip | switch | complete | start, ...}
create function app.checkin_do(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_op text := coalesce(p ->> 'op', '');
  v checkin_visits;
  b bookings;
  v_mode text;
  v_why text := nullif(left(btrim(coalesce(p ->> 'reason', '')), 300), '');
begin
  if not app.checkin_staff(p_by) then raise exception 'Staff only' using errcode = '42501'; end if;
  if v_op = 'complete' then return app.checkin_complete(p_by, p); end if;
  if v_op in ('book', 'skip') then
    select * into v from checkin_visits where id::text = p ->> 'id' for update;
    if v.id is null then raise exception 'Check-in visit not found' using errcode = 'P0002'; end if;
  end if;
  if v_op = 'book' then return app.checkin_book(p_by, v, p, true); end if;
  if v_op = 'skip' then
    if v.status not in ('due', 'booked') then raise exception 'This check-in visit is already %', v.status using errcode = '23514'; end if;
    if v_why is null then raise exception 'Say why (for example: the renter is away this month)' using errcode = '22023'; end if;
    update checkin_visits set status = 'skipped', closed_reason = v_why, done_by = p_by where id = v.id returning * into v;
    perform app.log_booking_event(v.booking_id, 'adjusted', null, null, null, 'Check-in visit skipped: ' || v_why, p_by, 'staff', jsonb_build_object('checkin_visit', v.id));
    return jsonb_build_object('ok', true, 'visit', app.checkin_json(v));
  end if;
  if v_op in ('switch', 'start') then
    select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
    if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    if v_op = 'start' then
      -- a visit now, without waiting for the schedule (the renter dropped by)
      if b.status <> 'on_rent' or app.checkin_why(b) is null then raise exception 'Booking % has no check-in visits: switch them on first', b.booking_number using errcode = '23514'; end if;
      insert into checkin_visits (booking_id, vehicle_id, due_on) values (b.id, b.vehicle_id, app.today()) on conflict do nothing;
      select * into v from checkin_visits where booking_id = b.id and status in ('due', 'booked');
      return jsonb_build_object('ok', true, 'visit', app.checkin_json(v));
    end if;
    if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then raise exception 'Admins, customer service and Fleet switch check-in visits' using errcode = '42501'; end if;
    v_mode := nullif(p ->> 'mode', '');
    if v_mode is not null and v_mode not in ('on', 'off') then raise exception 'Choose on, off or the default' using errcode = '22023'; end if;
    if v_mode is null then delete from checkin_booking_switch where booking_id = b.id;
    else insert into checkin_booking_switch (booking_id, mode, set_by) values (b.id, v_mode, p_by)
         on conflict (booking_id) do update set mode = excluded.mode, set_by = excluded.set_by, set_at = now();
    end if;
    if app.checkin_why(b) is null then
      update checkin_visits set status = 'cancelled', closed_reason = 'Check-in visits switched off for this booking' where booking_id = b.id and status in ('due', 'booked');
    end if;
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
      'Check-in visits: ' || coalesce(v_mode, 'the default (by the rental''s length)'), p_by, 'staff', jsonb_build_object('checkin_switch', v_mode));
    return jsonb_build_object('ok', true, 'on', app.checkin_why(b) is not null, 'switch', v_mode, 'next_on', app.checkin_next_due(b));
  end if;
  raise exception 'Unknown check-in operation' using errcode = '22023';
end $$;

-- ================================================================ 6. the owner sees each visit of their car (condition only)
alter function app.maint_owner_history(uuid) rename to maint_owner_history_pre4000;
create function app.maint_owner_history(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.maint_owner_history_pre4000(p_vehicle) || jsonb_build_object('checkins', coalesce((
    select jsonb_agg(jsonb_build_object('done_on', app.local_date(v.done_at), 'odometer_km', v.odometer_km, 'damage_found', v.damage_found,
             'tread_mm', v.tread_mm, 'fluids_ok', v.fluids_ok, 'next_service', v.next_service ->> 'label',
             'summary', case when v.damage_found then 'Damage noted; we are handling it' else 'No new damage' end) order by v.done_at desc)
      from (select * from checkin_visits x where x.vehicle_id = p_vehicle and x.status = 'done' order by x.done_at desc limit 12) v), '[]'::jsonb))
$$;
select pg_temp.copy_grants('app.maint_owner_history(uuid)'::regprocedure, 'app.maint_owner_history_pre4000(uuid)'::regprocedure);

-- ================================================================ 7. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre4000;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_name in ('checkin_queue', 'checkin_visit') and p_call in ('ops_read', 'admin_read', 'va_read', 'field_read') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'checkin_queue' then return app.checkin_queue(p_user, coalesce(p, '{}'::jsonb) - '_va'); end if;
    return app.checkin_visit_read(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_name = 'checkin_do' and p_call in ('ops_do', 'admin_do', 'va_do', 'field_do') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.checkin_do(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre4000(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre4000(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 8. the job (pg_cron, every 15 minutes, where available)
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: the check-in visits job is not scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): the check-in visits job is not scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-checkins', '*/15 * * * *', $q$select app.checkin_sweep()$q$);
end $$;

-- ================================================================ 9. privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('checkin_staff', 'checkin_why', 'checkin_next_due', 'checkin_place_words', 'checkin_time_words', 'checkin_slots',
                     'checkin_json', 'checkin_emit_payload', 'checkin_sweep', 'checkin_renter_booking', 'checkin_book', 'checkin_queue', 'checkin_visit_read',
                     'checkin_complete', 'checkin_do', 'maint_owner_history_pre4000', 'door_pre4000'))
               or (n.nspname = 'public' and p.proname in ('server_checkin_renter', 'server_checkin_book')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
