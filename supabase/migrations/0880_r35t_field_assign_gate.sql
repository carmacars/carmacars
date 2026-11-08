-- 0880: field jobs go only to field staff who passed the academy and are on a planned shift (Release 35, part T;
-- docs/changes/2026-11-08-r35-field-assign-gate.md). No applied migration is edited.
--
-- The owner's complaint: automatic assignment (field_auto_assignee, 0151, 0440) handed check-ins and handovers to field staff hired
-- the same day, who had not passed the academy and had no shifts. Now:
--   1. Shifts are taken, not handed out: Fleet and Admin publish open shift slots (a day, a start, an end, how many people; up to 14
--      days at once); a field person who passed the academy takes a slot on their portal ("Your shifts"); Fleet and Admin can also
--      put a person on a slot or take them off. The board shows the days of the next week with nobody on a shift.
--   2. The automatic assignment considers only a person who is not held by the academy gate and holds a taken shift covering the job's
--      time. Nobody qualifies: the job stays unassigned and the existing "nobody is assigned" alert handles it. Least busy order kept.
--   3. A manual assignment of a person the academy gate holds is refused ("<name> has not passed the academy yet"); a job can be
--      taken off (no person). Nobody is told that a job was taken off them unless Fleet or Admin ticks "tell them".
--   4. The Admin account is assignable (the picker always lists the Admins), does assigned jobs on the field portal, and opens the
--      field jobs board (Admin > Cars > Field jobs) with the same actions as Fleet.
--   5. The board shows each field person's academy state and next shift.
--   6. Work lands only on days that have shifts (a day has shifts when someone holds a taken shift that starts that day): work due on
--      a day without shifts, known the day before or earlier, moves to the nearest earlier day with shifts; work that comes in on
--      the day itself (or when no earlier day has shifts) goes to the next day with shifts. The job keeps its real time (work_day is
--      the planned work day); customer-facing times never change. The board warns about every handover and return on a day
--      without shifts (someone must cover it, or the booking time must move).
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

-- ================================================================ 1. slots and taken shifts
create table field_shift_slots (
  id           uuid primary key default gen_random_uuid(),
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  capacity     integer not null default 1 check (capacity between 1 and 50),
  note         text check (note is null or length(note) <= 300),
  created_by   uuid references users (id),
  cancelled_at timestamptz,
  cancelled_by uuid references users (id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (ends_at > starts_at),
  check (ends_at - starts_at <= interval '16 hours'),
  check ((cancelled_at is null) = (cancelled_by is null))
);
comment on table field_shift_slots is 'Open field shifts (0880): Fleet or an Admin publishes a day, a start, an end and how many people; field staff who passed the academy take them (field_shift_plans). A cancelled slot is kept.';
create index field_shift_slots_time_idx on field_shift_slots (starts_at) where cancelled_at is null;
create trigger field_shift_slots_updated before update on field_shift_slots for each row execute function app.set_updated_at();

create table field_shift_plans (
  id           uuid primary key default gen_random_uuid(),
  slot_id      uuid not null references field_shift_slots (id),
  staff_id     uuid not null references users (id),
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  note         text check (note is null or length(note) <= 300),
  created_by   uuid references users (id),
  cancelled_at timestamptz,
  cancelled_by uuid references users (id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (ends_at > starts_at),
  check (ends_at - starts_at <= interval '16 hours'),
  check ((cancelled_at is null) = (cancelled_by is null))
);
comment on table field_shift_plans is 'Taken field shifts (0880): a person on a slot, taken by themselves or put there by Fleet or an Admin. Only a person holding one (and past the academy) is given a job by the automatic assignment. Not the hours worked or paid (field_shifts); a cancelled one is kept.';
create unique index field_shift_plans_one on field_shift_plans (slot_id, staff_id) where cancelled_at is null;
create index field_shift_plans_staff_idx on field_shift_plans (staff_id, starts_at) where cancelled_at is null;
create trigger field_shift_plans_updated before update on field_shift_plans for each row execute function app.set_updated_at();
alter table field_shift_slots enable row level security;
alter table field_shift_plans enable row level security;
create policy admin_all on field_shift_slots for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on field_shift_plans for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy field_select on field_shift_slots for select to authenticated using (app.has_role('field'));
create policy own_select on field_shift_plans for select to authenticated using (staff_id = app.uid());
revoke all on field_shift_slots, field_shift_plans from anon, authenticated;
grant select on field_shift_slots, field_shift_plans to authenticated;
grant all on field_shift_slots, field_shift_plans to service_role;
create trigger audit_field_shift_slots after insert or update or delete on field_shift_slots for each row execute function app.audit_row();
create trigger audit_field_shift_plans after insert or update or delete on field_shift_plans for each row execute function app.audit_row();

-- an active field person (the field role and profile), not an Admin standing in
create function app.is_field_person(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from user_roles r join users u on u.id = r.user_id
      join staff_profiles sp on sp.user_id = r.user_id and 'field' = any (sp.functions) and sp.is_active
     where r.user_id = p_user and r.role = 'field' and u.status = 'active')
$$;

-- an Admin with a field job of their own (assigned, not cancelled, not finished more than a day ago): the field portal opens for them
create function app.admin_field_jobs(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and app.user_is_admin(p_user)
     and exists (select 1 from field_jobs j where j.assigned_to = p_user and j.status <> 'cancelled' and (j.completed_at is null or j.completed_at > now() - interval '24 hours'))
$$;

create or replace function app.user_is_field(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.is_field_person(p_user) or app.admin_field_jobs(p_user)
    or (p_user is not null and coalesce(current_setting('app.handover_as', true), '') = p_user::text)
$$;

alter function app.my_roles(uuid) rename to my_roles_pre0880;
create function app.my_roles(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.my_roles_pre0880(p_user) || case when app.admin_field_jobs(p_user) then jsonb_build_object('field', true) else '{}'::jsonb end
$$;
select pg_temp.copy_grants('app.my_roles(uuid)'::regprocedure, 'app.my_roles_pre0880(uuid)'::regprocedure);

-- Fleet or an Admin publishes open slots: the same hours on up to 14 days in a row (Toronto time).
create function app.field_slot_publish(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_start timestamptz := nullif(p ->> 'starts_at', '')::timestamptz;
  v_end timestamptz := nullif(p ->> 'ends_at', '')::timestamptz;
  v_cap integer := coalesce(nullif(p ->> 'capacity', '')::integer, 1);
  v_days integer := coalesce(nullif(p ->> 'repeat_days', '')::integer, 1);
  v_n integer := 0;
  i integer;
  s timestamptz;
  e timestamptz;
begin
  if not app.user_runs_fleet(p_by) then raise exception 'Only Fleet or an Admin publishes field shifts' using errcode = '42501'; end if;
  if v_start is null or v_end is null then raise exception 'Choose the day, the start and the end' using errcode = '22023'; end if;
  if v_end <= v_start then raise exception 'The shift must end after it starts' using errcode = '23514'; end if;
  if v_end - v_start > interval '16 hours' then raise exception 'A shift is at most 16 hours' using errcode = '23514'; end if;
  if v_cap not between 1 and 50 then raise exception 'How many people: 1 to 50' using errcode = '23514'; end if;
  if v_days not between 1 and 14 then raise exception 'Repeat for 1 to 14 days' using errcode = '23514'; end if;
  for i in 0 .. v_days - 1 loop
    s := ((v_start at time zone 'America/Toronto') + make_interval(days => i)) at time zone 'America/Toronto';
    e := s + (v_end - v_start);
    if e > now() then
      insert into field_shift_slots (starts_at, ends_at, capacity, note, created_by) values (s, e, v_cap, nullif(btrim(p ->> 'note'), ''), p_by);
      v_n := v_n + 1;
    end if;
  end loop;
  if v_n = 0 then raise exception 'Those shifts are already over' using errcode = '23514'; end if;
  return jsonb_build_object('slots', v_n);
end $$;

create function app.field_slot_cancel(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.user_runs_fleet(p_by) then raise exception 'Only Fleet or an Admin cancels field shifts' using errcode = '42501'; end if;
  update field_shift_slots set cancelled_at = now(), cancelled_by = p_by where id = (p ->> 'id')::uuid and cancelled_at is null;
  if not found then raise exception 'That shift is not there any more' using errcode = 'P0002'; end if;
  update field_shift_plans set cancelled_at = now(), cancelled_by = p_by where slot_id = (p ->> 'id')::uuid and cancelled_at is null;
  return jsonb_build_object('id', p ->> 'id');
end $$;

-- A person takes a slot (themselves, or Fleet or an Admin puts them on it). Held by the academy: refused.
create function app.field_shift_book(p_staff uuid, p_slot uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s field_shift_slots;
  v_id uuid;
begin
  if not app.is_field_person(p_staff) then raise exception 'A shift is taken by active field staff' using errcode = '23514'; end if;
  if app.academy_locked(p_staff) then
    raise exception '% has not passed the academy yet, so cannot take shifts', coalesce((select u.full_name from users u where u.id = p_staff), 'This person') using errcode = '23514';
  end if;
  select * into s from field_shift_slots where id = p_slot for update;
  if s.id is null or s.cancelled_at is not null then raise exception 'That shift is not there any more' using errcode = 'P0002'; end if;
  if s.ends_at <= now() then raise exception 'That shift is already over' using errcode = '23514'; end if;
  if exists (select 1 from field_shift_plans x where x.slot_id = s.id and x.staff_id = p_staff and x.cancelled_at is null) then
    raise exception 'Already on this shift' using errcode = '23505';
  end if;
  if (select count(*) from field_shift_plans x where x.slot_id = s.id and x.cancelled_at is null) >= s.capacity then
    raise exception 'This shift is full' using errcode = '23514';
  end if;
  if exists (select 1 from field_shift_plans x where x.staff_id = p_staff and x.cancelled_at is null and x.starts_at < s.ends_at and s.starts_at < x.ends_at) then
    raise exception 'That overlaps another shift' using errcode = '23514';
  end if;
  insert into field_shift_plans (slot_id, staff_id, starts_at, ends_at, note, created_by) values (s.id, p_staff, s.starts_at, s.ends_at, s.note, p_by) returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

create function app.field_shift_plan_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.user_runs_fleet(p_by) then raise exception 'Only Fleet or an Admin puts a person on a shift' using errcode = '42501'; end if;
  return app.field_shift_book((p ->> 'staff')::uuid, (p ->> 'slot')::uuid, p_by);
end $$;

-- Fleet or an Admin takes a person off a shift, or the person drops their own.
create function app.field_shift_plan_cancel(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x field_shift_plans;
begin
  select * into x from field_shift_plans where id = (p ->> 'id')::uuid and cancelled_at is null for update;
  if x.id is null then raise exception 'That shift is not there any more' using errcode = 'P0002'; end if;
  if x.staff_id <> p_by and not app.user_runs_fleet(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if x.starts_at <= now() and x.staff_id = p_by and not app.user_runs_fleet(p_by) then raise exception 'This shift has started: ask Fleet' using errcode = '23514'; end if;
  update field_shift_plans set cancelled_at = now(), cancelled_by = p_by where id = x.id;
  return jsonb_build_object('id', x.id);
end $$;

-- What a field person sees: their upcoming shifts and the open slots of the next three weeks.
create function app.field_my_shifts(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'locked', app.academy_locked(p_user),
    'mine', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'starts_at', s.starts_at, 'ends_at', s.ends_at, 'note', s.note) order by s.starts_at)
                        from (select * from field_shift_plans x where x.staff_id = p_user and x.cancelled_at is null and x.ends_at > now() order by x.starts_at limit 30) s), '[]'::jsonb),
    'open', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'starts_at', o.starts_at, 'ends_at', o.ends_at, 'note', o.note, 'capacity', o.capacity, 'taken', o.taken,
                                         'mine', o.mine) order by o.starts_at)
                        from (select s.*, (select count(*) from field_shift_plans x where x.slot_id = s.id and x.cancelled_at is null) as taken,
                                     exists (select 1 from field_shift_plans x where x.slot_id = s.id and x.staff_id = p_user and x.cancelled_at is null) as mine
                                from field_shift_slots s where s.cancelled_at is null and s.ends_at > now() and s.starts_at < now() + interval '21 days' order by s.starts_at limit 100) o), '[]'::jsonb))
$$;

-- ================================================================ 2. the automatic assignment
alter table field_jobs add column if not exists work_day date;
comment on column field_jobs.work_day is 'The day an automatic job is planned to be worked (0880), when it is not the booking''s own day: the nearest day with shifts. The job keeps its real time.';

-- The day work due at p_at is done: its own day when someone holds a shift that day. Else, when it is known in advance, the nearest
-- earlier day (from today) with shifts, and failing that the next day with shifts; when it comes in on the day, the next day with shifts.
create function app.field_work_day(p_at timestamptz, p_advance boolean) returns date
language sql stable security definer set search_path = public, app as $$
  with d as (select app.local_date(p_at) as day),
       days as (select distinct app.local_date(s.starts_at) as day from field_shift_plans s where s.cancelled_at is null)
  select case
    when exists (select 1 from days, d where days.day = d.day) then (select day from d)
    when p_advance and exists (select 1 from days, d where days.day < d.day and days.day >= app.today()) then (select max(days.day) from days, d where days.day < d.day and days.day >= app.today())
    else (select min(days.day) from days, d where days.day > d.day and days.day <= d.day + 14) end
$$;

create or replace function app.field_auto_assignee(p_at timestamptz) returns uuid
language sql stable security definer set search_path = public, app as $$
  with w as (select app.field_work_day(p_at, app.local_date(p_at) > app.today()) as day)
  select case when (app.settings()).field_jobs_auto_assign = 'least_busy' then (
    select u.id from w cross join users u
      join staff_profiles sp on sp.user_id = u.id and 'field' = any (sp.functions) and sp.is_active and sp.field_function in ('driver', 'driver_detailer')
      join user_roles r on r.user_id = u.id and r.role = 'field'
     where u.status = 'active' and not u.is_test and w.day is not null
       and not app.academy_locked(u.id)
       and exists (select 1 from field_shift_plans s where s.staff_id = u.id and s.cancelled_at is null and app.local_date(s.starts_at) = w.day)
     order by (select count(*) from field_jobs j where j.assigned_to = u.id and j.status <> 'cancelled' and coalesce(j.work_day, app.local_date(j.scheduled_at)) = w.day),
              (select count(*) from field_jobs j where j.assigned_to = u.id and j.status <> 'cancelled' and j.scheduled_at between p_at - interval '3 days' and p_at + interval '4 days'),
              u.full_name, u.id
     limit 1) end
$$;

-- The planned work day of an automatic job (the booking's own day leaves it empty).
create function app.field_jobs_work_day() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date;
begin
  if new.auto_created and new.assigned_to is not null and new.status not in ('done', 'cancelled')
     and (tg_op = 'INSERT' or old.assigned_to is null or new.scheduled_at is distinct from old.scheduled_at) then
    v_day := app.field_work_day(new.scheduled_at, app.local_date(new.scheduled_at) > app.today());
    new.work_day := case when v_day is distinct from app.local_date(new.scheduled_at) then v_day end;
  end if;
  return new;
end $$;
create trigger field_jobs_work_day before insert or update of assigned_to, scheduled_at on field_jobs for each row execute function app.field_jobs_work_day();

-- Handovers and returns of the next 14 days on a day without shifts (and the day they are worked, when work moved).
create function app.field_no_shift_days(p_booking uuid default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'leg', x.leg, 'at', x.at, 'day', app.local_date(x.at),
           'vehicle_name', app.vehicle_name(b.vehicle_id), 'work_day', app.field_work_day(x.at, app.local_date(x.at) > app.today())) order by x.at), '[]'::jsonb)
    from bookings b cross join lateral (values ('handover', b.pickup_at, b.status = 'confirmed' and b.handed_over_at is null),
                                               ('return_check_in', b.return_at, b.status in ('confirmed', 'on_rent') and b.checked_in_at is null)) x(leg, at, applies)
   where x.applies and x.at between now() - interval '1 day' and now() + interval '14 days' and (p_booking is null or b.id = p_booking)
     and not exists (select 1 from field_shift_plans s where s.cancelled_at is null and app.local_date(s.starts_at) = app.local_date(x.at))
$$;

-- ================================================================ 3. manual assignment
-- Fleet or an Admin gives a job to someone else, or takes it off (no person: "nobody"). A field person the academy gate holds is
-- refused. An Admin can be given a job. Taken off, nobody is told unless Fleet or Admin ticks "tell them" (app.field_unassign_quiet).
create or replace function app.assign_field_job(p_job uuid, p_assignee uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
begin
  if not app.user_runs_fleet(p_by) then
    raise exception 'Only Fleet or an Admin assigns a field job' using errcode = '42501';
  end if;
  select * into j from field_jobs where id = p_job for update;
  if j.id is null then raise exception 'Field job % not found', p_job; end if;
  if j.status in ('done', 'cancelled') then
    raise exception 'This job is % and cannot be reassigned', j.status using errcode = '23514';
  end if;
  if j.status = 'in_progress' and j.assigned_to is distinct from p_assignee then
    raise exception 'This job has started: cancel it and create a new one to change who does it' using errcode = '23514';
  end if;
  if p_assignee is not null and not (app.user_is_field(p_assignee) or app.user_is_admin(p_assignee)) then
    raise exception 'A field job is assigned to active field staff or an Admin' using errcode = '23514';
  end if;
  if j.assigned_to is not distinct from p_assignee then return; end if;
  if p_assignee is not null and app.academy_locked(p_assignee) then
    raise exception '% has not passed the academy yet', coalesce((select u.full_name from users u where u.id = p_assignee), 'This person') using errcode = '23514';
  end if;
  update field_jobs
     set assigned_to = p_assignee, dispatched_by = p_by, status = 'scheduled', acknowledged_at = null
   where id = p_job;
end $$;

-- the job-changed email to the person a job was taken off stays quiet when no one else gets it, unless asked
create function pg_temp.patch_trigger() returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef('app.field_job_after_write()'::regprocedure);
  o text := $o$if old.assigned_to is not null and old.status not in ('done', 'cancelled') then$o$;
  n text := $n$if old.assigned_to is not null and old.status not in ('done', 'cancelled')
         and not (new.assigned_to is null and coalesce(current_setting('app.field_unassign_quiet', true), '') = 'on') then$n$;
begin
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception '0880: the text to change was not found once in field_job_after_write'; end if;
  execute replace(d, o, n);
end $$;
select pg_temp.patch_trigger();


-- the same two rules when a job is made with a person already chosen (Schedule on the board)
create function pg_temp.patch_create() returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef('app.create_field_job(text, uuid, timestamptz, uuid, uuid, uuid, text, text)'::regprocedure);
  o text := $o$if p_assigned_to is not null and not app.user_is_field(p_assigned_to) then$o$;
  n text := $n$if p_assigned_to is not null and app.academy_locked(p_assigned_to) then
    raise exception '% has not passed the academy yet', coalesce((select u.full_name from users u where u.id = p_assigned_to), 'This person') using errcode = '23514';
  end if;
  if p_assigned_to is not null and not (app.user_is_field(p_assigned_to) or app.user_is_admin(p_assigned_to)) then$n$;
begin
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception '0880: the text to change was not found once in create_field_job'; end if;
  execute replace(d, o, n);
end $$;
select pg_temp.patch_create();

-- ================================================================ 4. 5. the board (Fleet and Admin)
-- Everyone a job can go to: each field person with the academy state and next shift, and the Admins (always listed).
create function app.field_staff_board() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x.o order by x.name), '[]'::jsonb) from (
    select u.full_name as name, jsonb_build_object('id', u.id, 'name', u.full_name, 'admin', false, 'locked', app.academy_locked(u.id), 'eligible', not app.academy_locked(u.id),
             'next_shift', (select jsonb_build_object('starts_at', s.starts_at, 'ends_at', s.ends_at, 'on_now', s.starts_at <= now())
                              from field_shift_plans s where s.staff_id = u.id and s.cancelled_at is null and s.ends_at > now() order by s.starts_at limit 1)) as o
      from users u where app.is_field_person(u.id)
    union all
    select u.full_name, jsonb_build_object('id', u.id, 'name', u.full_name, 'admin', true, 'locked', false, 'eligible', true, 'next_shift', null)
      from users u join user_roles r on r.user_id = u.id and r.role = 'admin'
     where u.status = 'active' and not u.is_test and not app.is_field_person(u.id)) x
$$;

-- Fleet's board without the assistant check of va_read (0031), for Fleet and for an Admin: the same jobs, handovers and returns without
-- a job (with the place, 0151), expiry watch and vehicle documents; the people with their state and shifts, the open and taken slots,
-- and the next seven days with how many people hold a shift each day.
create function app.field_board(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_runs_fleet(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object(
    'staff', app.field_staff_board(),
    'slots', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'starts_at', s.starts_at, 'ends_at', s.ends_at, 'capacity', s.capacity, 'note', s.note,
                         'people', coalesce((select jsonb_agg(jsonb_build_object('plan_id', x.id, 'staff_id', x.staff_id, 'name', u.full_name) order by u.full_name)
                                               from field_shift_plans x join users u on u.id = x.staff_id where x.slot_id = s.id and x.cancelled_at is null), '[]'::jsonb)) order by s.starts_at)
                         from (select * from field_shift_slots y where y.cancelled_at is null and y.ends_at > now() order by y.starts_at limit 200) s), '[]'::jsonb),
    'coverage', (select jsonb_agg(jsonb_build_object('day', d.day, 'slots', (select count(*) from field_shift_slots s where s.cancelled_at is null and app.local_date(s.starts_at) = d.day),
                         'people', (select count(distinct x.staff_id) from field_shift_plans x where x.cancelled_at is null and app.local_date(x.starts_at) = d.day)) order by d.day)
                   from (select app.today() + g as day from generate_series(0, 6) g) d),
    'no_shift_days', app.field_no_shift_days(null),
    'jobs', coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(j)) order by j.scheduled_at) from field_jobs j
                       where j.status <> 'cancelled' and (j.status <> 'done' or j.completed_at > now() - interval '1 day')
                         and j.scheduled_at < now() + interval '3 days'), '[]'::jsonb),
    'unscheduled', coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'vehicle_id', b.vehicle_id,
                                'vehicle_name', app.vehicle_name(b.vehicle_id), 'leg', x.leg, 'at', x.at,
                                'place', coalesce(nullif(x.place, ''), app.booking_leg_place(b.id, case when x.leg = 'handover' then 'pickup' else 'return' end))) order by x.at)
                             from bookings b cross join lateral (values ('handover', b.pickup_at, b.pickup_place, b.status = 'confirmed'),
                                                                       ('return_check_in', b.return_at, b.return_place, b.status in ('confirmed', 'on_rent'))) x(leg, at, place, applies)
                            where x.applies and x.at between now() - interval '1 day' and now() + interval '7 days'
                              and not exists (select 1 from field_jobs j where j.booking_id = b.id and j.status <> 'cancelled'
                                                and (case when x.leg = 'handover' then j.kind in ('handover', 'delivery') else j.kind in ('return_check_in', 'pickup_from_renter') end))), '[]'::jsonb),
    'expiry', coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(t)) order by t.due_at) from tasks t
                         where t.status in ('open', 'in_progress', 'waiting') and t.task_type in ('turo_expiry', 'safety_certificate_window', 'plate_renewal', 'arrears_removal')), '[]'::jsonb),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'created_at', d.created_at, 'vehicle_id', d.vehicle_id,
                              'vehicle_name', app.vehicle_name(d.vehicle_id)) order by d.created_at desc)
                           from (select * from documents d where d.vehicle_id is not null and d.purged_at is null and d.booking_id is null
                                   and d.kind::text not in ('id_front', 'id_back', 'selfie') order by d.created_at desc limit 50) d), '[]'::jsonb));
end $$;

-- The actions of the board, for Fleet and for an Admin (the door's ops_do).
create function app.field_assign_do(p_user uuid, p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_to uuid;
begin
  case p_action
  when 'field_job_assign', 'field_job_unassign' then
    v_to := case when p_action = 'field_job_unassign' then null else nullif(btrim(coalesce(p ->> 'to', '')), '')::uuid end;
    perform set_config('app.field_unassign_quiet', case when coalesce((p ->> 'tell')::boolean, false) then 'off' else 'on' end, true);
    perform app.assign_field_job((p ->> 'id')::uuid, v_to, p_user);
    perform set_config('app.field_unassign_quiet', 'off', true);
    return jsonb_build_object('id', p ->> 'id');
  when 'field_job_reschedule' then
    perform app.reschedule_field_job((p ->> 'id')::uuid, p_user, (p ->> 'scheduled_at')::timestamptz, nullif(btrim(p ->> 'place'), ''));
    return jsonb_build_object('id', p ->> 'id');
  when 'field_job_cancel' then
    perform app.cancel_field_job((p ->> 'id')::uuid, p_user, p ->> 'reason');
    return jsonb_build_object('id', p ->> 'id');
  when 'field_slot_publish' then return app.field_slot_publish(p_user, p);
  when 'field_slot_cancel' then return app.field_slot_cancel(p_user, p);
  when 'field_shift_plan_add' then return app.field_shift_plan_add(p_user, p);
  when 'field_shift_plan_cancel' then
    if not app.user_runs_fleet(p_user) then raise exception 'Only Fleet or an Admin takes a person off a shift' using errcode = '42501'; end if;
    return app.field_shift_plan_cancel(p_user, p);
  else raise exception 'Unknown action %', p_action using errcode = '22023';
  end case;
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0880;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb;
begin
  if p_call = 'ops_read' and p_name = 'field_board' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.field_board(p_user);
  end if;
  if p_call = 'ops_read' and p_name = 'field_staff' then
    perform app.door_begin(p_user, p_aal);
    if not app.user_runs_fleet(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return jsonb_build_object('staff', app.field_staff_board());
  end if;
  if p_call = 'ops_read' and p_name = 'field_no_shift_days' then
    perform app.door_begin(p_user, p_aal);
    if not app.user_runs_fleet(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.field_no_shift_days(nullif(p ->> 'booking', '')::uuid);
  end if;
  if p_call = 'ops_do' and p_name in ('field_job_assign', 'field_job_unassign', 'field_job_reschedule', 'field_job_cancel', 'field_slot_publish', 'field_slot_cancel', 'field_shift_plan_add', 'field_shift_plan_cancel') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.field_assign_do(p_user, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  -- the field person's own shifts
  if p_call = 'field_read' and p_name = 'my_shifts' then
    perform app.door_begin(p_user, p_aal);
    if not app.is_field_person(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.field_my_shifts(p_user);
  end if;
  if p_call = 'field_do' and p_name in ('shift_take', 'shift_drop') then
    perform app.door_begin(p_user, p_aal);
    if not app.is_field_person(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    if p_name = 'shift_take' then return app.field_shift_book(p_user, (p ->> 'slot')::uuid, p_user); end if;
    return app.field_shift_plan_cancel(p_user, p);
  end if;
  -- the booking page's person picker (and Fleet's old board read): field people the academy gate does not hold, and the Admins
  if p_call = 'va_read' and p_name = 'fleet_board' then
    x := app.door_pre0880(p_user, p_aal, p_call, p_name, p);
    if jsonb_typeof(x -> 'staff') = 'array' then
      x := jsonb_set(x, '{staff}', coalesce((select jsonb_agg(jsonb_build_object('id', s ->> 'id', 'name', s ->> 'name')) from jsonb_array_elements(app.field_staff_board()) s
                                              where (s ->> 'eligible')::boolean), '[]'::jsonb));
    end if;
    return x;
  end if;
  return app.door_pre0880(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0880(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['is_field_person', 'admin_field_jobs', 'field_slot_publish', 'field_slot_cancel', 'field_shift_book', 'field_shift_plan_add',
              'field_shift_plan_cancel', 'field_my_shifts', 'field_staff_board', 'field_board', 'field_assign_do', 'field_work_day', 'field_jobs_work_day', 'field_no_shift_days', 'door_pre0880', 'my_roles_pre0880'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ the guides
-- GUIDES 0880 START (generated by supabase/seed/0880_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'fleet-and-listings', 'chapter', 'calendar-sync-with-turo-and-other-platforms', 'Vehicles is the fleet. Listings turns a car into a page on carmacars.ca in four steps: photos, covered plates, a review, and live on the site.

## Vehicles

**Cars** > **Vehicles**

1. Filter by status; More filters has who supplies the car, retired cars and the mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.
2. Search by plate, model or owner. **Cars** > **Rates for many cars** changes the rates of many cars at once.
3. Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker. The Tracker card links to Fleet tracking.

![](/guides/img/admin-08-vehicles-desktop-46461f49.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/vehicles; pins: 1 74.3 31.1, 2 37.5 24.3, 3 48.6 52.4")

## Set a car''s rates and kilometres

Open the car, then the **Rates** tab. Everything on it saves together, in one step.

1. Type the four rates. Only the daily rate is needed: an empty weekend rate is the daily rate, an empty weekly rate is 6 days at the daily rate, and an empty monthly rate is 22 days.
2. Kilometres: keep **Use the defaults** (the kilometres a day in Settings, Kilometre choices, and the extra kilometre rate in Fee defaults for the car''s class), or choose **Custom for this car** and type them.
3. Check the deposit (the class default is filled in), and the delivery and pickup fees: each is one way, an empty pickup fee is the delivery fee, and 0 means not offered.
4. Read What renters pay under the fields: real prices for a weekend, a few weekdays, a week and a month, worked out the way bookings are priced. Press **Save the rates**.

| Rate | What it means |
| --- | --- |
| Daily rate | A price per day, for each day that starts on a Sunday, Monday, Tuesday, Wednesday or Thursday |
| Weekend rate | A price per day, not for the whole weekend: each day that starts on a Friday or Saturday. Friday 10 am to Sunday 10 am is 2 days at this rate; Sunday to Monday is a daily day |
| Weekly rate | The price for 7 days. Rentals of 7 to 29 days cost this for each 7 days, counted by the day. A 1 to 6 day rental never costs more |
| Monthly rate | The price for 30 days. A 7 to 29 day rental never costs more |

5. Lead-time pricing for this car, below the rates: **Program settings** (the tiers there), **Off for this car**, or **Its own tiers** (a table like the one in Program settings). Press **Save**.

> Tip: A problem shows on its own field, in words, as you type. When similar cars have rates, a line suggests them with Use these; it is only a hint. The same fields are on **Add a car**, so a car can be added with its rates in one pass.

## Fleet tracking

**Cars** > **Vehicles**, the **Fleet tracking** tab. Fleet staff have the same map as **Fleet map** in their menu, and field staff see the cars of their own jobs under **Map**. Every car on the same map as the Live map, with who has it. Positions are seen by Admins and fleet staff only.

1. The four numbers: cars on rent, moving, parked, and open alerts.
2. The map shows each car as its photo in a ring: green moving (the arrow is its heading), yellow engine on, blue parked, orange not reporting. The list beside it has every car with its renter, booking, when it is due back (late in red) and its state.
3. Press a car on the map or in the list for its card: last report, odometer, fuel, tracker battery, whether the tracker has the car''s power, and the trip under way.
4. **Alerts**: speeding, left Ontario, left your zone, still driving after the return time, low tracker battery, unplugged and not reporting. Each also comes to the bell and, with phone alerts on, under Urgent alerts. Press **Show** to see where, **Seen** when it is handled, or **Mark all as seen**.
5. **Trips by booking**: each booking''s trips, kilometres and top speed (red at the speeding level). Press the last trip to draw its route on the map.

## Pair a tracker with a car

1. A new tracker that reports shows under **Trackers**, "Reporting, not on a car yet". Press **Pair**, choose the car and the install date.
2. Or press **Pair a tracker** and type its device ID (the IMEI or serial number on the tracker).
3. The install date starts the Tracker Fee on the owner''s invoice when the car has none yet. A replacement tracker keeps the car''s first date; the old tracker is taken off by itself.
4. **Remove** takes a tracker off a car (tick "faulty" for a broken one). The Tracker Fee is not changed.

## Tracking settings

Below the trackers: the speeding level (140 km/h), the minutes of grace after the return time (15), the low battery level (20%), the hours before "not reporting" (6), the Ontario alert, and one optional zone (a name, its centre and a radius in km). History keeps a moving car''s position once a minute for 90 days, trips and alerts for 365 days (at most 365: the privacy policy keeps tracker data 12 months).

1. Demo mode (off): simulated cars drive the GTA''s highways here and on the Live map, for a demonstration. Nothing is saved. Turn it off before the trackers go live.
2. **Make the ingest key**: the relay or tracker service signs every batch of positions with it. It is shown once; making a new one stops the old one at once.

> Tip: The Live map shows the same cars with its Fleet layer (tick Fleet).

## The listing pipeline

Open **Cars** > **Listings**. A draft waiting for review shows Needs review.

1. Each row shows the car, plate, state, photos and the work done on it so far.
2. Press **Start a listing** to begin one for a car that has none.
3. Open a car to review it.

![](/guides/img/admin-09-listings-desktop-970819b6.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/listings; pins: 1 53.5 37.0, 2 87.2 21.1, 3 32.6 37.0")

## Review a listing

1. Steps to go live shows four numbered steps: **1 Photos** (how many of the required photos are in, 14 for most cars, 13 for a two-seater with no rear seats), **2 Cover plates**, **3 Review** and **4 Live on the site**. Each says what it needs and has one button to where it is done; the step to do now is in red. A step that stopped (a photo edit or the copy) shows under them with **Retry**.
2. Similar cars on file lists possible duplicates. Press **Not a duplicate** or **Same car**. An open flag does not keep the car off the site; only Same car does.
3. The copy is written by itself from the car''s facts and published when it passes the checks: nothing to type. To change a line, press Change; that field is then locked and kept by every new version.
4. Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.

![](/guides/img/admin-10-listing-review-desktop-352745fd.jpg "desktop; size: 1440 1100; address: carmacars.ca/admin/listings/704abf3d-8905-443d-a157-d52769cf7449; pins: 1 20.6 16.6, 2 86.1 47.5, 3 19.9 106.8, 4 74.9 106.8")

## Cover the licence plate

On each public photo press **Cover the plate**. The editor opens.

1. The box over the plate is already suggested: as soon as the review opens, every outside photo (the More outside photos included) gets its suggestion, and those photos show Box suggested. Check it. **Suggest the plate** asks again.
2. Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.
3. Under Cover the plate with, choose **A CarmaCars plate**, **Pixelation** or **Blur**.
4. Press **Save the covered photo**. **Clear the boxes** starts over.
5. No plate in the shot? Press **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg "desktop; size: 690 703; address: carmacars.ca/admin/listings/704abf3d-8905-443d-a157-d52769cf7449; pins: 1 42.5 83.8, 2 49.6 29.9, 3 4.3 77.4, 4 15.5 83.8, 5 18.1 91.2")

> Tip: The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.

## Publish

1. A real car that is not on the site is a line on To do: press **Set rates and publish**. The daily rate is filled in (the car''s own, or the suggested rate from similar cars or the class); change it if you like and press **Publish now**.
2. On the car itself, the Listing tab has **Publish now**; each open item of its checklist has a button to where it is done.
3. From a listing review: press **Approve and publish**, **Approve, publish later**, or **Send back** with what to fix.

> Watch out: The plate check never holds a car back: a real photo whose plate is not checked stays private (the other photos, or the sample photos, show instead) and goes public by itself once its plate is covered or marked not visible. Listings already live show "Plate not checked" on such photos.

## Photos filed under the wrong shot, and interior windows

1. On the Photos card, each shot lists its photos. A photo filed under the wrong shot: press **Remove** under it, then **Remove it**. The shot is free again: take or pick the right photo. The removed photo is kept privately and the removal is in the history. A live listing''s photos change in the review instead (Reject).
2. Dashboard and seat photos: what shows through the windows is replaced by the studio background when the cut is clean (a quality check: some but not most of the frame seen through, high in the frame, a few clean regions, sharp edges). Otherwise the windows are blurred, and the photo is marked windows blurred. Nothing to do.
3. A car with 2 seats or fewer needs no Rear seats photo.

## A listing without photos yet: sample photos

A car can be listed before its photos are taken. Until then the site shows a sample photo.

1. Submit the listing without photos. The listing copy is still written for you from the car''s details.
2. The car page and the car''s card show a sample photo, captioned "Sample photo", so renters know it is not this car. Staff see "Using sample photos" on the car and in Listings.
3. Publishing does not wait for a plate check: a sample photo has no plate.
4. Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.

## Sample photos

**Settings** > **Sample photos**. The pictures a car shows until its real photos are in.

1. Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).
2. Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press **Add the photo**.
3. The most specific photo wins: make and model, then make and body type, then body type. **Turn off** or **Delete** a photo you no longer want.
4. Cars using sample photos lists the cars still waiting for real photos. Each real car showing sample photos is also a line on To do, with **Add photos**.

![](/guides/img/admin-36-sample-photos-desktop-55c64070.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/settings/sample-photos; pins: 4 26.8 28.9")

## Publish now, and new cars published by themselves

Nothing between a new car and the site has to be finished first: the car goes on the site, and what is still open shows on its checklist.

1. **Settings** > **Program**, **Publish new cars automatically** (on by default): a new real car goes on the site by itself as soon as it has its year, make and model and its rates, when it is added with rates, when its rates are saved, when it is added for an owner, or when an owner''s application is approved.
2. Otherwise open the car: its Listing tab says why it is not on the site and has **Publish now**. A car with no rates yet is published with the suggested rates (similar cars, else the class defaults in Program settings); change them later on the Rates tab.
3. Every real car has its listing from the moment it is added, as a draft. It shows in Listings and in Not on the site yet until it is published.
4. An owner''s own application waits for your decision before its car is published by itself; Publish now still works.
5. A car taken off the site by staff, or scheduled for a later date, is never published by itself: press **Publish now**.

## The checklist: what is still open on a listed car

Open items never stop publishing. They show as warnings on the car''s Listing tab and after Publish now.

| Item | What it means |
| --- | --- |
| Paperwork | Ownership permit, registry forms, agreements signed, Forms C and D, upfront payment, registry visit, tracker, safety certificate |
| Insurance | Not on the fleet insurance policy yet: the car can be booked, but not handed over |
| Details | Colour, body, seats, gearbox: the car page leaves out what is missing |
| Photos | No real photos: sample photos stand in. A photo whose plate is not checked stays private until it is |
| No VIN yet | A car added by its plate alone: add the VIN when you have it |
| Possible duplicate | An open flag in Similar cars. Only Same car keeps the car off the site |
| Owner terms | The management fee (Revenue Share) and fees not set: a request uses the owner''s terms or the standard grid |

## The fleet policy rule at handover

A program owner''s car is listed and can be requested, offered and paid for while its paperwork is open. It is never handed over until the insurer confirms in writing that it is on the fleet insurance policy.

- Staff see a warning on a request and an offer for a car not on the policy yet.
- The handover refuses the car until the insurer''s confirmation is recorded (Owners and onboarding). The field app says so on the job.
- Only real states keep a car off the site: retired, left the program, out of service, Turo only, bookings turned off, a self-managed owner in arrears, or a paused listing.

## Cars on sample photos

**Cars**, **Listings** ends with **Cars on sample photos**: each real car whose page still shows sample photos, with its newest handover photos (the check-in and check-out photos field staff take).

1. Where a handover photographed the car, press **Use the handover photos**. They go into the car''s listing as if taken on the capture screen.
2. When every required shot is there, the listing is submitted: the studio editor puts the car on the CarmaCars backdrop, then the listing waits for your review like any other.
3. A car with no handover photos yet gets them at its next handover, or press **Start a listing** and take them.

> Good to know: The studio editor uses Cloudflare image transformations (5,000 a month included). Settings > Usage counts them.

## A car''s registration and documents

Open the car, then **Owner & documents**. The **Registration** card:

1. Correct the **VIN** (it is checked: 17 characters, the check digit, not on another car; decoded again for the body style and trim), the **Year** and the **Body style**.
2. Type the **Ontario permit number** and the date the **Plate sticker expires**. Fleet gets a task 30 days and 7 days before; save the new date after the renewal and the task closes.
3. Under **Documents**, choose the kind (**Ownership permit**, Safety Standards Certificate, owner''s insurance, other), pick the photo or PDF and press **Upload**. The ownership permit clears that item of the owner''s checklist.
4. For the **Safety Standards Certificate**, also type its number, the date it was issued and the date it expires. Fleet gets a task 30 days and 7 days before it expires; upload the new certificate with its dates and the task closes. It is a document on the car, not a service record, and nothing is billed to the owner.
5. **Add a car** takes the ownership permit and the Safety Standards Certificate too, under **Documents (optional)**.

## A car added under the wrong owner

Open the car, Overview, **Who supplies the car**, **Move to another owner**. Choose the owner, or **CarmaCars (owner not known yet)**: the car becomes a company car, with no owner schedule or terms.

- The car''s unsigned owner application and vehicle schedule are withdrawn (kept in the history), and its draft owner invoices are deleted. Nobody is notified.
- It is refused once anything for the car is signed, issued, paid or on a statement.

### The VIN from the car, not typed

Every VIN field (Add a car, Add a car for an owner, the car''s **Registration**, **Start a listing**) has **Scan the barcode** and **Photo of the VIN**. Scan the barcode in the driver''s door frame or at the bottom of the windshield: the phone''s camera reads it by itself. Or take a photo of the VIN plate or sticker: the barcode in it is read first, else the photo is read for the printed VIN. The VIN is checked (17 characters, the check digit; I, O and Q become 1 and 0) and decoded as when you type it. Check it against the car before saving.

### Photos in any order

**Add photos** on the listing takes any number of photos at once from the camera roll. Each is sorted to its shot by itself (front three-quarter, sides, rear, dashboard, seats and the rest); a shot that already has its photo sends the new one to the extra photos, so nothing is replaced by accident. The shots are a guide, not a rule: a listing is complete with 10 photos that can go on the site and one outside photo for the cover. Outside photos get the studio background: the car is cropped to its edges and placed big in the frame with its wheels on the floor and a soft shadow under the tyres, and any corner watermark or caption beside the car is left out. Inside and detail photos are kept as taken; when one has a watermark, a logo or caption text on it, the edge with the mark is cut off by itself, and a photo whose mark cannot be cut off (one in the middle) stays off the site until you replace it. **Cover the plate** opens on every outside photo with the plate box suggested; check it and save.

Outside photos made before the newest framing (the car small in the frame, or without the model''s name behind it) are made again with **Frame the outside photos again** above the photos of the listing, then **Yes, frame again**. The cover and the main outside views get the model''s name lettered behind the car, as on the sample photos (for example CLA, C CLASS, AMG GT). The photos leave the site until their plates are checked again: the plate box is suggested on the new photos; check each and cover it. On a published listing each goes back on the site once its plate is checked.

## Extra photos

A photo that fits no shot is an extra photo. Under the shots, **Extra outside photos** (put on the studio background) and **Extra inside and detail photos** (touched up) each take any number at once. They count toward the 10 photos, get the same plate check, and come after the standard shots on the car''s page.

1. In the review, **Extra photos, in their order on the car page** lists them.
2. Drag a photo by its handle (⋮⋮), or press **Earlier** or **Later**.
3. Press **Save the order**.

## Fix a cut-out

When the background removal cuts badly (a mirror or a wheel missing, background left beside the car), press **Edit the cut-out** under the outside photo.

1. **Cut-out** shows the car over the photo as taken, shown faintly. Choose **Erase** and brush over what should go, or **Restore** and brush over what the cut-out took off. Set **Brush size** and **Zoom**; when zoomed, **Move the view** pans. **Undo** takes back the last stroke.
2. **On the studio** shows the car on the studio background. Drag the car to move it and use **Size** to make it larger or smaller. **Centre and full size** puts it back.
3. Press **Save as a new version**. The photo is made again in about a minute; the version before and the photo as taken are kept. **Reset to the automatic cut-out** starts again from the automatic one.

> Good to know: If the car did not move, the plate check carries over: a photo marked no plate visible stays so, and a covered plate is covered again on the new photo when the review is open. If the car moved, check the plate again. A photo made before cut-outs were kept shows **Make the cut-out** first; the editor opens by itself when it is ready.

Every photo also gets a light touch-up by itself (exposure, levels, a little contrast and colour, mild sharpening), never enough to change the paint colour or hide a scratch. Turn it off for one photo with **Use original colours** under it (the photo is made again; approve it again), or for every photo in Admin > Settings > **Program settings** (Listings) with **Auto-enhance listing photos**. The photo as uploaded is always kept.
## Import photos from a Google Drive link

The owner often hands over a car''s photos as a public Google Drive folder, or one big folder with a folder per make and then per car. You do not download them: paste the link.

**One car.** On the car''s listing, under the capture, **Import photos from a Google Drive link**. Paste the folder link (shared with Anyone with the link) and press **Import the photos**. Every photo in the folder, and in the folders inside it, is added to this car as if you had pressed Add photos: each is sorted to its shot (else filed as an extra photo, in file-name order), put on the studio background and checked for its plate. The box under the link, **Submit the listing for processing when its photos are in**, is on by default.

**Many cars.** **Cars** > **Import photos from Drive** (a button on Vehicles). Paste the top folder''s link and press **Read the folder**. The page walks every folder and proposes a car for each folder that holds photos, from the year, make, model, colour and plate in the folder names (the make folder above counts; 01 Motors partner cars come first). Check the table: tick or untick **Import**, change the car in the list (the likely cars come first), leave out a folder with **Do not import this folder**. A line marked **Check this one** matched two alike cars. Then press **Import N photos from M folders**.

1. The page follows the import by itself. You can leave it and come back: it runs in the background.
2. The end shows the summary: imported, skipped and failed, and why for each (a file over 15 MB, a file that is not a photo, the same photo already on the car, a folder not shared).
3. **Try the failed photos again** takes only the ones that failed. Pressing Import on the same link again never adds a photo twice: a Drive file already on the car is skipped, and so is the same picture under another name. A photo you took off the car can be imported again.

> Good to know: JPG, PNG, HEIC and WebP only (HEIC and WebP are made JPEG first). At most 15 MB a photo, 600 photos, 400 folders and 4 GB in one import. Drive is asked politely, one photo at a time; a big import takes a while.

> Good to know: Without a key, Drive shows only the first 50 files of a folder on its public page; a folder with more is read in full when Drive allows it. In **Settings**, the **Photo import from Google Drive** box takes a Google API key with the Drive API on (after it is saved only its last 4 characters are shown, and it is never written to the change log): with it, folders of any size are read and photos download without Drive''s warning pages.

## Pickup from owner and return to owner (release 28)

On a car''s page, **Pickup from owner and return to owner** records the car''s condition when CarmaCars picks it up from its owner or gives it back: the date and time, km, fuel, many photos at once with the suggested angles, and notes. **Add photos** adds more to a record later. The owner sees these records read only on the car''s page in their portal. They are the baseline condition for any dispute.

## Incident cards (release 34)
**Cars** > **Vehicles** > **Incident cards** prints the card for each car: what to do in an accident or a breakdown, the support number from Settings, a roadside number when there is one, a QR code to report it in the app, and the fleet insurance slip. Open a car and press **Incident card** to print only that car; on the list, **Print all cars** prints them all, two cards to a Letter page with crop marks, ready to laminate. Under Fleet insurance policy press **Add the policy** (the insurer, the policy number, the dates, the named insured, the roadside number on the slip) and choose the uploaded slip if you have one: it is printed as it is, otherwise the fields are. The card never shows a premium. Fleet staff print the same cards from their portal.', 'Fleet and listings', 'Vehicles, the listing pipeline, similar cars and covering licence plates.',
  'Vehicles is the fleet. Listings turns a car into a page on carmacars.ca in four steps: photos, covered plates, a review, and live on the site.

## Vehicles

**Cars** > **Vehicles**

1. Filter by status; More filters has who supplies the car, retired cars and the mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.
2. Search by plate, model or owner. **Cars** > **Rates for many cars** changes the rates of many cars at once.
3. Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker. The Tracker card links to Fleet tracking.

![](/guides/img/admin-08-vehicles-desktop-46461f49.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/vehicles; pins: 1 74.3 31.1, 2 37.5 24.3, 3 48.6 52.4")

## Set a car''s rates and kilometres

Open the car, then the **Rates** tab. Everything on it saves together, in one step.

1. Type the four rates. Only the daily rate is needed: an empty weekend rate is the daily rate, an empty weekly rate is 6 days at the daily rate, and an empty monthly rate is 22 days.
2. Kilometres: keep **Use the defaults** (the kilometres a day in Settings, Kilometre choices, and the extra kilometre rate in Fee defaults for the car''s class), or choose **Custom for this car** and type them.
3. Check the deposit (the class default is filled in), and the delivery and pickup fees: each is one way, an empty pickup fee is the delivery fee, and 0 means not offered.
4. Read What renters pay under the fields: real prices for a weekend, a few weekdays, a week and a month, worked out the way bookings are priced. Press **Save the rates**.

| Rate | What it means |
| --- | --- |
| Daily rate | A price per day, for each day that starts on a Sunday, Monday, Tuesday, Wednesday or Thursday |
| Weekend rate | A price per day, not for the whole weekend: each day that starts on a Friday or Saturday. Friday 10 am to Sunday 10 am is 2 days at this rate; Sunday to Monday is a daily day |
| Weekly rate | The price for 7 days. Rentals of 7 to 29 days cost this for each 7 days, counted by the day. A 1 to 6 day rental never costs more |
| Monthly rate | The price for 30 days. A 7 to 29 day rental never costs more |

5. Lead-time pricing for this car, below the rates: **Program settings** (the tiers there), **Off for this car**, or **Its own tiers** (a table like the one in Program settings). Press **Save**.

> Tip: A problem shows on its own field, in words, as you type. When similar cars have rates, a line suggests them with Use these; it is only a hint. The same fields are on **Add a car**, so a car can be added with its rates in one pass.

## Fleet tracking

**Cars** > **Vehicles**, the **Fleet tracking** tab. Fleet staff have the same map as **Fleet map** in their menu, and field staff see the cars of their own jobs under **Map**. Every car on the same map as the Live map, with who has it. Positions are seen by Admins and fleet staff only.

1. The four numbers: cars on rent, moving, parked, and open alerts.
2. The map shows each car as its photo in a ring: green moving (the arrow is its heading), yellow engine on, blue parked, orange not reporting. The list beside it has every car with its renter, booking, when it is due back (late in red) and its state.
3. Press a car on the map or in the list for its card: last report, odometer, fuel, tracker battery, whether the tracker has the car''s power, and the trip under way.
4. **Alerts**: speeding, left Ontario, left your zone, still driving after the return time, low tracker battery, unplugged and not reporting. Each also comes to the bell and, with phone alerts on, under Urgent alerts. Press **Show** to see where, **Seen** when it is handled, or **Mark all as seen**.
5. **Trips by booking**: each booking''s trips, kilometres and top speed (red at the speeding level). Press the last trip to draw its route on the map.

## Pair a tracker with a car

1. A new tracker that reports shows under **Trackers**, "Reporting, not on a car yet". Press **Pair**, choose the car and the install date.
2. Or press **Pair a tracker** and type its device ID (the IMEI or serial number on the tracker).
3. The install date starts the Tracker Fee on the owner''s invoice when the car has none yet. A replacement tracker keeps the car''s first date; the old tracker is taken off by itself.
4. **Remove** takes a tracker off a car (tick "faulty" for a broken one). The Tracker Fee is not changed.

## Tracking settings

Below the trackers: the speeding level (140 km/h), the minutes of grace after the return time (15), the low battery level (20%), the hours before "not reporting" (6), the Ontario alert, and one optional zone (a name, its centre and a radius in km). History keeps a moving car''s position once a minute for 90 days, trips and alerts for 365 days (at most 365: the privacy policy keeps tracker data 12 months).

1. Demo mode (off): simulated cars drive the GTA''s highways here and on the Live map, for a demonstration. Nothing is saved. Turn it off before the trackers go live.
2. **Make the ingest key**: the relay or tracker service signs every batch of positions with it. It is shown once; making a new one stops the old one at once.

> Tip: The Live map shows the same cars with its Fleet layer (tick Fleet).

## The listing pipeline

Open **Cars** > **Listings**. A draft waiting for review shows Needs review.

1. Each row shows the car, plate, state, photos and the work done on it so far.
2. Press **Start a listing** to begin one for a car that has none.
3. Open a car to review it.

![](/guides/img/admin-09-listings-desktop-970819b6.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/listings; pins: 1 53.5 37.0, 2 87.2 21.1, 3 32.6 37.0")

## Review a listing

1. Steps to go live shows four numbered steps: **1 Photos** (how many of the required photos are in, 14 for most cars, 13 for a two-seater with no rear seats), **2 Cover plates**, **3 Review** and **4 Live on the site**. Each says what it needs and has one button to where it is done; the step to do now is in red. A step that stopped (a photo edit or the copy) shows under them with **Retry**.
2. Similar cars on file lists possible duplicates. Press **Not a duplicate** or **Same car**. An open flag does not keep the car off the site; only Same car does.
3. The copy is written by itself from the car''s facts and published when it passes the checks: nothing to type. To change a line, press Change; that field is then locked and kept by every new version.
4. Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.

![](/guides/img/admin-10-listing-review-desktop-352745fd.jpg "desktop; size: 1440 1100; address: carmacars.ca/admin/listings/704abf3d-8905-443d-a157-d52769cf7449; pins: 1 20.6 16.6, 2 86.1 47.5, 3 19.9 106.8, 4 74.9 106.8")

## Cover the licence plate

On each public photo press **Cover the plate**. The editor opens.

1. The box over the plate is already suggested: as soon as the review opens, every outside photo (the More outside photos included) gets its suggestion, and those photos show Box suggested. Check it. **Suggest the plate** asks again.
2. Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.
3. Under Cover the plate with, choose **A CarmaCars plate**, **Pixelation** or **Blur**.
4. Press **Save the covered photo**. **Clear the boxes** starts over.
5. No plate in the shot? Press **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg "desktop; size: 690 703; address: carmacars.ca/admin/listings/704abf3d-8905-443d-a157-d52769cf7449; pins: 1 42.5 83.8, 2 49.6 29.9, 3 4.3 77.4, 4 15.5 83.8, 5 18.1 91.2")

> Tip: The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.

## Publish

1. A real car that is not on the site is a line on To do: press **Set rates and publish**. The daily rate is filled in (the car''s own, or the suggested rate from similar cars or the class); change it if you like and press **Publish now**.
2. On the car itself, the Listing tab has **Publish now**; each open item of its checklist has a button to where it is done.
3. From a listing review: press **Approve and publish**, **Approve, publish later**, or **Send back** with what to fix.

> Watch out: The plate check never holds a car back: a real photo whose plate is not checked stays private (the other photos, or the sample photos, show instead) and goes public by itself once its plate is covered or marked not visible. Listings already live show "Plate not checked" on such photos.

## Photos filed under the wrong shot, and interior windows

1. On the Photos card, each shot lists its photos. A photo filed under the wrong shot: press **Remove** under it, then **Remove it**. The shot is free again: take or pick the right photo. The removed photo is kept privately and the removal is in the history. A live listing''s photos change in the review instead (Reject).
2. Dashboard and seat photos: what shows through the windows is replaced by the studio background when the cut is clean (a quality check: some but not most of the frame seen through, high in the frame, a few clean regions, sharp edges). Otherwise the windows are blurred, and the photo is marked windows blurred. Nothing to do.
3. A car with 2 seats or fewer needs no Rear seats photo.

## A listing without photos yet: sample photos

A car can be listed before its photos are taken. Until then the site shows a sample photo.

1. Submit the listing without photos. The listing copy is still written for you from the car''s details.
2. The car page and the car''s card show a sample photo, captioned "Sample photo", so renters know it is not this car. Staff see "Using sample photos" on the car and in Listings.
3. Publishing does not wait for a plate check: a sample photo has no plate.
4. Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.

## Sample photos

**Settings** > **Sample photos**. The pictures a car shows until its real photos are in.

1. Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).
2. Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press **Add the photo**.
3. The most specific photo wins: make and model, then make and body type, then body type. **Turn off** or **Delete** a photo you no longer want.
4. Cars using sample photos lists the cars still waiting for real photos. Each real car showing sample photos is also a line on To do, with **Add photos**.

![](/guides/img/admin-36-sample-photos-desktop-55c64070.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/settings/sample-photos; pins: 4 26.8 28.9")

## Publish now, and new cars published by themselves

Nothing between a new car and the site has to be finished first: the car goes on the site, and what is still open shows on its checklist.

1. **Settings** > **Program**, **Publish new cars automatically** (on by default): a new real car goes on the site by itself as soon as it has its year, make and model and its rates, when it is added with rates, when its rates are saved, when it is added for an owner, or when an owner''s application is approved.
2. Otherwise open the car: its Listing tab says why it is not on the site and has **Publish now**. A car with no rates yet is published with the suggested rates (similar cars, else the class defaults in Program settings); change them later on the Rates tab.
3. Every real car has its listing from the moment it is added, as a draft. It shows in Listings and in Not on the site yet until it is published.
4. An owner''s own application waits for your decision before its car is published by itself; Publish now still works.
5. A car taken off the site by staff, or scheduled for a later date, is never published by itself: press **Publish now**.

## The checklist: what is still open on a listed car

Open items never stop publishing. They show as warnings on the car''s Listing tab and after Publish now.

| Item | What it means |
| --- | --- |
| Paperwork | Ownership permit, registry forms, agreements signed, Forms C and D, upfront payment, registry visit, tracker, safety certificate |
| Insurance | Not on the fleet insurance policy yet: the car can be booked, but not handed over |
| Details | Colour, body, seats, gearbox: the car page leaves out what is missing |
| Photos | No real photos: sample photos stand in. A photo whose plate is not checked stays private until it is |
| No VIN yet | A car added by its plate alone: add the VIN when you have it |
| Possible duplicate | An open flag in Similar cars. Only Same car keeps the car off the site |
| Owner terms | The management fee (Revenue Share) and fees not set: a request uses the owner''s terms or the standard grid |

## The fleet policy rule at handover

A program owner''s car is listed and can be requested, offered and paid for while its paperwork is open. It is never handed over until the insurer confirms in writing that it is on the fleet insurance policy.

- Staff see a warning on a request and an offer for a car not on the policy yet.
- The handover refuses the car until the insurer''s confirmation is recorded (Owners and onboarding). The field app says so on the job.
- Only real states keep a car off the site: retired, left the program, out of service, Turo only, bookings turned off, a self-managed owner in arrears, or a paused listing.

## Cars on sample photos

**Cars**, **Listings** ends with **Cars on sample photos**: each real car whose page still shows sample photos, with its newest handover photos (the check-in and check-out photos field staff take).

1. Where a handover photographed the car, press **Use the handover photos**. They go into the car''s listing as if taken on the capture screen.
2. When every required shot is there, the listing is submitted: the studio editor puts the car on the CarmaCars backdrop, then the listing waits for your review like any other.
3. A car with no handover photos yet gets them at its next handover, or press **Start a listing** and take them.

> Good to know: The studio editor uses Cloudflare image transformations (5,000 a month included). Settings > Usage counts them.

## A car''s registration and documents

Open the car, then **Owner & documents**. The **Registration** card:

1. Correct the **VIN** (it is checked: 17 characters, the check digit, not on another car; decoded again for the body style and trim), the **Year** and the **Body style**.
2. Type the **Ontario permit number** and the date the **Plate sticker expires**. Fleet gets a task 30 days and 7 days before; save the new date after the renewal and the task closes.
3. Under **Documents**, choose the kind (**Ownership permit**, Safety Standards Certificate, owner''s insurance, other), pick the photo or PDF and press **Upload**. The ownership permit clears that item of the owner''s checklist.
4. For the **Safety Standards Certificate**, also type its number, the date it was issued and the date it expires. Fleet gets a task 30 days and 7 days before it expires; upload the new certificate with its dates and the task closes. It is a document on the car, not a service record, and nothing is billed to the owner.
5. **Add a car** takes the ownership permit and the Safety Standards Certificate too, under **Documents (optional)**.

## A car added under the wrong owner

Open the car, Overview, **Who supplies the car**, **Move to another owner**. Choose the owner, or **CarmaCars (owner not known yet)**: the car becomes a company car, with no owner schedule or terms.

- The car''s unsigned owner application and vehicle schedule are withdrawn (kept in the history), and its draft owner invoices are deleted. Nobody is notified.
- It is refused once anything for the car is signed, issued, paid or on a statement.

### The VIN from the car, not typed

Every VIN field (Add a car, Add a car for an owner, the car''s **Registration**, **Start a listing**) has **Scan the barcode** and **Photo of the VIN**. Scan the barcode in the driver''s door frame or at the bottom of the windshield: the phone''s camera reads it by itself. Or take a photo of the VIN plate or sticker: the barcode in it is read first, else the photo is read for the printed VIN. The VIN is checked (17 characters, the check digit; I, O and Q become 1 and 0) and decoded as when you type it. Check it against the car before saving.

### Photos in any order

**Add photos** on the listing takes any number of photos at once from the camera roll. Each is sorted to its shot by itself (front three-quarter, sides, rear, dashboard, seats and the rest); a shot that already has its photo sends the new one to the extra photos, so nothing is replaced by accident. The shots are a guide, not a rule: a listing is complete with 10 photos that can go on the site and one outside photo for the cover. Outside photos get the studio background: the car is cropped to its edges and placed big in the frame with its wheels on the floor and a soft shadow under the tyres, and any corner watermark or caption beside the car is left out. Inside and detail photos are kept as taken; when one has a watermark, a logo or caption text on it, the edge with the mark is cut off by itself, and a photo whose mark cannot be cut off (one in the middle) stays off the site until you replace it. **Cover the plate** opens on every outside photo with the plate box suggested; check it and save.

Outside photos made before the newest framing (the car small in the frame, or without the model''s name behind it) are made again with **Frame the outside photos again** above the photos of the listing, then **Yes, frame again**. The cover and the main outside views get the model''s name lettered behind the car, as on the sample photos (for example CLA, C CLASS, AMG GT). The photos leave the site until their plates are checked again: the plate box is suggested on the new photos; check each and cover it. On a published listing each goes back on the site once its plate is checked.

## Extra photos

A photo that fits no shot is an extra photo. Under the shots, **Extra outside photos** (put on the studio background) and **Extra inside and detail photos** (touched up) each take any number at once. They count toward the 10 photos, get the same plate check, and come after the standard shots on the car''s page.

1. In the review, **Extra photos, in their order on the car page** lists them.
2. Drag a photo by its handle (⋮⋮), or press **Earlier** or **Later**.
3. Press **Save the order**.

## Fix a cut-out

When the background removal cuts badly (a mirror or a wheel missing, background left beside the car), press **Edit the cut-out** under the outside photo.

1. **Cut-out** shows the car over the photo as taken, shown faintly. Choose **Erase** and brush over what should go, or **Restore** and brush over what the cut-out took off. Set **Brush size** and **Zoom**; when zoomed, **Move the view** pans. **Undo** takes back the last stroke.
2. **On the studio** shows the car on the studio background. Drag the car to move it and use **Size** to make it larger or smaller. **Centre and full size** puts it back.
3. Press **Save as a new version**. The photo is made again in about a minute; the version before and the photo as taken are kept. **Reset to the automatic cut-out** starts again from the automatic one.

> Good to know: If the car did not move, the plate check carries over: a photo marked no plate visible stays so, and a covered plate is covered again on the new photo when the review is open. If the car moved, check the plate again. A photo made before cut-outs were kept shows **Make the cut-out** first; the editor opens by itself when it is ready.

Every photo also gets a light touch-up by itself (exposure, levels, a little contrast and colour, mild sharpening), never enough to change the paint colour or hide a scratch. Turn it off for one photo with **Use original colours** under it (the photo is made again; approve it again), or for every photo in Admin > Settings > **Program settings** (Listings) with **Auto-enhance listing photos**. The photo as uploaded is always kept.
## Import photos from a Google Drive link

The owner often hands over a car''s photos as a public Google Drive folder, or one big folder with a folder per make and then per car. You do not download them: paste the link.

**One car.** On the car''s listing, under the capture, **Import photos from a Google Drive link**. Paste the folder link (shared with Anyone with the link) and press **Import the photos**. Every photo in the folder, and in the folders inside it, is added to this car as if you had pressed Add photos: each is sorted to its shot (else filed as an extra photo, in file-name order), put on the studio background and checked for its plate. The box under the link, **Submit the listing for processing when its photos are in**, is on by default.

**Many cars.** **Cars** > **Import photos from Drive** (a button on Vehicles). Paste the top folder''s link and press **Read the folder**. The page walks every folder and proposes a car for each folder that holds photos, from the year, make, model, colour and plate in the folder names (the make folder above counts; 01 Motors partner cars come first). Check the table: tick or untick **Import**, change the car in the list (the likely cars come first), leave out a folder with **Do not import this folder**. A line marked **Check this one** matched two alike cars. Then press **Import N photos from M folders**.

1. The page follows the import by itself. You can leave it and come back: it runs in the background.
2. The end shows the summary: imported, skipped and failed, and why for each (a file over 15 MB, a file that is not a photo, the same photo already on the car, a folder not shared).
3. **Try the failed photos again** takes only the ones that failed. Pressing Import on the same link again never adds a photo twice: a Drive file already on the car is skipped, and so is the same picture under another name. A photo you took off the car can be imported again.

> Good to know: JPG, PNG, HEIC and WebP only (HEIC and WebP are made JPEG first). At most 15 MB a photo, 600 photos, 400 folders and 4 GB in one import. Drive is asked politely, one photo at a time; a big import takes a while.

> Good to know: Without a key, Drive shows only the first 50 files of a folder on its public page; a folder with more is read in full when Drive allows it. In **Settings**, the **Photo import from Google Drive** box takes a Google API key with the Drive API on (after it is saved only its last 4 characters are shown, and it is never written to the change log): with it, folders of any size are read and photos download without Drive''s warning pages.

## Pickup from owner and return to owner (release 28)

On a car''s page, **Pickup from owner and return to owner** records the car''s condition when CarmaCars picks it up from its owner or gives it back: the date and time, km, fuel, many photos at once with the suggested angles, and notes. **Add photos** adds more to a record later. The owner sees these records read only on the car''s page in their portal. They are the baseline condition for any dispute.

## Incident cards (release 34)
**Cars** > **Vehicles** > **Incident cards** prints the card for each car: what to do in an accident or a breakdown, the support number from Settings, a roadside number when there is one, a QR code to report it in the app, and the fleet insurance slip. Open a car and press **Incident card** to print only that car; on the list, **Print all cars** prints them all, two cards to a Letter page with crop marks, ready to laminate. Under Fleet insurance policy press **Add the policy** (the insurer, the policy number, the dates, the named insured, the roadside number on the slip) and choose the uploaded slip if you have one: it is printed as it is, otherwise the fields are. The card never shows a premium. Fleet staff print the same cards from their portal.

## Field jobs, shifts and who gets a job

**Cars**, then **Field jobs**, is the board Fleet uses, with every action Fleet has. Field staff take shifts you publish with **Publish shifts**; jobs are given by themselves only to a field person who passed the academy and holds a shift that day, and work lands only on days with shifts (work due on a day without shifts moves to the day before, or to the next day with shifts when it comes in on the day; the booking''s own times never change). A booking whose handover or return falls on a day with no shifts shows a warning on the board and on the booking. You can give a job to a field person or to an Admin, take it off with **Unassign** (tick **Tell them** to let them know), and an Admin who holds a job opens it on the field portal. A person who has not passed the academy cannot be given a job or take a shift.',
  '<p class="gd-p">Vehicles is the fleet. Listings turns a car into a page on carmacars.ca in four steps: photos, covered plates, a review, and live on the site.</p><section class="gd-task" id="fleet-and-listings-vehicles" data-gd-task><h2 class="gd-h2">Vehicles</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by status; More filters has who supplies the car, retired cars and the mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Search by plate, model or owner. <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Rates for many cars</b> changes the rates of many cars at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker. The Tracker card links to Fleet tracking.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/vehicles</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-08-vehicles-desktop-46461f49.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:74.3%;top:31.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:37.5%;top:24.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:48.6%;top:52.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-set-a-car-s-rates-and-kilometres" data-gd-task><h2 class="gd-h2">Set a car&#39;s rates and kilometres</h2><p class="gd-p">Open the car, then the <b class="gd-ui">Rates</b> tab. Everything on it saves together, in one step.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the four rates. Only the daily rate is needed: an empty weekend rate is the daily rate, an empty weekly rate is 6 days at the daily rate, and an empty monthly rate is 22 days.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Kilometres: keep <b class="gd-ui">Use the defaults</b> (the kilometres a day in Settings, Kilometre choices, and the extra kilometre rate in Fee defaults for the car&#39;s class), or choose <b class="gd-ui">Custom for this car</b> and type them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the deposit (the class default is filled in), and the delivery and pickup fees: each is one way, an empty pickup fee is the delivery fee, and 0 means not offered.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Read What renters pay under the fields: real prices for a weekend, a few weekdays, a week and a month, worked out the way bookings are priced. Press <b class="gd-ui">Save the rates</b>.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Rate</th><th scope="col">What it means</th></tr></thead><tbody><tr><td>Daily rate</td><td>A price per day, for each day that starts on a Sunday, Monday, Tuesday, Wednesday or Thursday</td></tr><tr><td>Weekend rate</td><td>A price per day, not for the whole weekend: each day that starts on a Friday or Saturday. Friday 10 am to Sunday 10 am is 2 days at this rate; Sunday to Monday is a daily day</td></tr><tr><td>Weekly rate</td><td>The price for 7 days. Rentals of 7 to 29 days cost this for each 7 days, counted by the day. A 1 to 6 day rental never costs more</td></tr><tr><td>Monthly rate</td><td>The price for 30 days. A 7 to 29 day rental never costs more</td></tr></tbody></table></div><div class="gd-stepblock"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Lead-time pricing for this car, below the rates: <b class="gd-ui">Program settings</b> (the tiers there), <b class="gd-ui">Off for this car</b>, or <b class="gd-ui">Its own tiers</b> (a table like the one in Program settings). Press <b class="gd-ui">Save</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A problem shows on its own field, in words, as you type. When similar cars have rates, a line suggests them with Use these; it is only a hint. The same fields are on <b class="gd-ui">Add a car</b>, so a car can be added with its rates in one pass.</div></aside></section><section class="gd-task" id="fleet-and-listings-fleet-tracking" data-gd-task><h2 class="gd-h2">Fleet tracking</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, the <b class="gd-ui">Fleet tracking</b> tab. Fleet staff have the same map as <b class="gd-ui">Fleet map</b> in their menu, and field staff see the cars of their own jobs under <b class="gd-ui">Map</b>. Every car on the same map as the Live map, with who has it. Positions are seen by Admins and fleet staff only.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The four numbers: cars on rent, moving, parked, and open alerts.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The map shows each car as its photo in a ring: green moving (the arrow is its heading), yellow engine on, blue parked, orange not reporting. The list beside it has every car with its renter, booking, when it is due back (late in red) and its state.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press a car on the map or in the list for its card: last report, odometer, fuel, tracker battery, whether the tracker has the car&#39;s power, and the trip under way.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Alerts</b>: speeding, left Ontario, left your zone, still driving after the return time, low tracker battery, unplugged and not reporting. Each also comes to the bell and, with phone alerts on, under Urgent alerts. Press <b class="gd-ui">Show</b> to see where, <b class="gd-ui">Seen</b> when it is handled, or <b class="gd-ui">Mark all as seen</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Trips by booking</b>: each booking&#39;s trips, kilometres and top speed (red at the speeding level). Press the last trip to draw its route on the map.</div></li></ol></div></section><section class="gd-task" id="fleet-and-listings-pair-a-tracker-with-a-car" data-gd-task><h2 class="gd-h2">Pair a tracker with a car</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A new tracker that reports shows under <b class="gd-ui">Trackers</b>, &quot;Reporting, not on a car yet&quot;. Press <b class="gd-ui">Pair</b>, choose the car and the install date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Or press <b class="gd-ui">Pair a tracker</b> and type its device ID (the IMEI or serial number on the tracker).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The install date starts the Tracker Fee on the owner&#39;s invoice when the car has none yet. A replacement tracker keeps the car&#39;s first date; the old tracker is taken off by itself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Remove</b> takes a tracker off a car (tick &quot;faulty&quot; for a broken one). The Tracker Fee is not changed.</div></li></ol></div></section><section class="gd-task" id="fleet-and-listings-tracking-settings" data-gd-task><h2 class="gd-h2">Tracking settings</h2><p class="gd-p">Below the trackers: the speeding level (140 km/h), the minutes of grace after the return time (15), the low battery level (20%), the hours before &quot;not reporting&quot; (6), the Ontario alert, and one optional zone (a name, its centre and a radius in km). History keeps a moving car&#39;s position once a minute for 90 days, trips and alerts for 365 days (at most 365: the privacy policy keeps tracker data 12 months).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Demo mode (off): simulated cars drive the GTA&#39;s highways here and on the Live map, for a demonstration. Nothing is saved. Turn it off before the trackers go live.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Make the ingest key</b>: the relay or tracker service signs every batch of positions with it. It is shown once; making a new one stops the old one at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The Live map shows the same cars with its Fleet layer (tick Fleet).</div></aside></section><section class="gd-task" id="fleet-and-listings-the-listing-pipeline" data-gd-task><h2 class="gd-h2">The listing pipeline</h2><p class="gd-p">Open <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Listings</b>. A draft waiting for review shows Needs review.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the car, plate, state, photos and the work done on it so far.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Start a listing</b> to begin one for a car that has none.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open a car to review it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-09-listings-desktop-970819b6.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:53.5%;top:37%" aria-hidden="true">1</span><span class="gd-pin" style="left:87.2%;top:21.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:32.6%;top:37%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-review-a-listing" data-gd-task><h2 class="gd-h2">Review a listing</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Steps to go live shows four numbered steps: <b class="gd-ui">1 Photos</b> (how many of the required photos are in, 14 for most cars, 13 for a two-seater with no rear seats), <b class="gd-ui">2 Cover plates</b>, <b class="gd-ui">3 Review</b> and <b class="gd-ui">4 Live on the site</b>. Each says what it needs and has one button to where it is done; the step to do now is in red. A step that stopped (a photo edit or the copy) shows under them with <b class="gd-ui">Retry</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Similar cars on file lists possible duplicates. Press <b class="gd-ui">Not a duplicate</b> or <b class="gd-ui">Same car</b>. An open flag does not keep the car off the site; only Same car does.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The copy is written by itself from the car&#39;s facts and published when it passes the checks: nothing to type. To change a line, press Change; that field is then locked and kept by every new version.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings/704abf3d-8905-443d-a157-d52769cf7449</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1100"><img src="/guides/img/admin-10-listing-review-desktop-352745fd.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1100"><span class="gd-pin" style="left:20.6%;top:16.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:86.1%;top:47.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:19.9%;top:100%" aria-hidden="true">3</span><span class="gd-pin" style="left:74.9%;top:100%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-cover-the-licence-plate" data-gd-task><h2 class="gd-h2">Cover the licence plate</h2><p class="gd-p">On each public photo press <b class="gd-ui">Cover the plate</b>. The editor opens.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The box over the plate is already suggested: as soon as the review opens, every outside photo (the More outside photos included) gets its suggestion, and those photos show Box suggested. Check it. <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under Cover the plate with, choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save the covered photo</b>. <b class="gd-ui">Clear the boxes</b> starts over.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">No plate in the shot? Press <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings/704abf3d-8905-443d-a157-d52769cf7449</span></div><div class="gd-imgwrap" style="aspect-ratio:690/703"><img src="/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg" alt="" loading="lazy" decoding="async" width="690" height="703"><span class="gd-pin" style="left:42.5%;top:83.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:49.6%;top:29.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:4.3%;top:77.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:15.5%;top:83.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:18.1%;top:91.2%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.</div></aside></section><section class="gd-task" id="fleet-and-listings-publish" data-gd-task><h2 class="gd-h2">Publish</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A real car that is not on the site is a line on To do: press <b class="gd-ui">Set rates and publish</b>. The daily rate is filled in (the car&#39;s own, or the suggested rate from similar cars or the class); change it if you like and press <b class="gd-ui">Publish now</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On the car itself, the Listing tab has <b class="gd-ui">Publish now</b>; each open item of its checklist has a button to where it is done.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">From a listing review: press <b class="gd-ui">Approve and publish</b>, <b class="gd-ui">Approve, publish later</b>, or <b class="gd-ui">Send back</b> with what to fix.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>The plate check never holds a car back: a real photo whose plate is not checked stays private (the other photos, or the sample photos, show instead) and goes public by itself once its plate is covered or marked not visible. Listings already live show &quot;Plate not checked&quot; on such photos.</div></aside></section><section class="gd-task" id="fleet-and-listings-photos-filed-under-the-wrong-shot-and-interior-windows" data-gd-task><h2 class="gd-h2">Photos filed under the wrong shot, and interior windows</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the Photos card, each shot lists its photos. A photo filed under the wrong shot: press <b class="gd-ui">Remove</b> under it, then <b class="gd-ui">Remove it</b>. The shot is free again: take or pick the right photo. The removed photo is kept privately and the removal is in the history. A live listing&#39;s photos change in the review instead (Reject).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Dashboard and seat photos: what shows through the windows is replaced by the studio background when the cut is clean (a quality check: some but not most of the frame seen through, high in the frame, a few clean regions, sharp edges). Otherwise the windows are blurred, and the photo is marked windows blurred. Nothing to do.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car with 2 seats or fewer needs no Rear seats photo.</div></li></ol></div></section><section class="gd-task" id="fleet-and-listings-a-listing-without-photos-yet-sample-photos" data-gd-task><h2 class="gd-h2">A listing without photos yet: sample photos</h2><p class="gd-p">A car can be listed before its photos are taken. Until then the site shows a sample photo.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Submit the listing without photos. The listing copy is still written for you from the car&#39;s details.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car page and the car&#39;s card show a sample photo, captioned &quot;Sample photo&quot;, so renters know it is not this car. Staff see &quot;Using sample photos&quot; on the car and in Listings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Publishing does not wait for a plate check: a sample photo has no plate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.</div></li></ol></div></section><section class="gd-task" id="fleet-and-listings-sample-photos" data-gd-task><h2 class="gd-h2">Sample photos</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sample photos</b>. The pictures a car shows until its real photos are in.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press <b class="gd-ui">Add the photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The most specific photo wins: make and model, then make and body type, then body type. <b class="gd-ui">Turn off</b> or <b class="gd-ui">Delete</b> a photo you no longer want.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Cars using sample photos lists the cars still waiting for real photos. Each real car showing sample photos is also a line on To do, with <b class="gd-ui">Add photos</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/sample-photos</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/812"><img src="/guides/img/admin-36-sample-photos-desktop-55c64070.jpg" alt="" loading="lazy" decoding="async" width="1440" height="812"><span class="gd-pin" style="left:26.8%;top:28.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-publish-now-and-new-cars-published-by-themselves" data-gd-task><h2 class="gd-h2">Publish now, and new cars published by themselves</h2><p class="gd-p">Nothing between a new car and the site has to be finished first: the car goes on the site, and what is still open shows on its checklist.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, <b class="gd-ui">Publish new cars automatically</b> (on by default): a new real car goes on the site by itself as soon as it has its year, make and model and its rates, when it is added with rates, when its rates are saved, when it is added for an owner, or when an owner&#39;s application is approved.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Otherwise open the car: its Listing tab says why it is not on the site and has <b class="gd-ui">Publish now</b>. A car with no rates yet is published with the suggested rates (similar cars, else the class defaults in Program settings); change them later on the Rates tab.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Every real car has its listing from the moment it is added, as a draft. It shows in Listings and in Not on the site yet until it is published.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An owner&#39;s own application waits for your decision before its car is published by itself; Publish now still works.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A car taken off the site by staff, or scheduled for a later date, is never published by itself: press <b class="gd-ui">Publish now</b>.</div></li></ol></div></section><section class="gd-task" id="fleet-and-listings-the-checklist-what-is-still-open-on-a-listed-car" data-gd-task><h2 class="gd-h2">The checklist: what is still open on a listed car</h2><p class="gd-p">Open items never stop publishing. They show as warnings on the car&#39;s Listing tab and after Publish now.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it means</th></tr></thead><tbody><tr><td>Paperwork</td><td>Ownership permit, registry forms, agreements signed, Forms C and D, upfront payment, registry visit, tracker, safety certificate</td></tr><tr><td>Insurance</td><td>Not on the fleet insurance policy yet: the car can be booked, but not handed over</td></tr><tr><td>Details</td><td>Colour, body, seats, gearbox: the car page leaves out what is missing</td></tr><tr><td>Photos</td><td>No real photos: sample photos stand in. A photo whose plate is not checked stays private until it is</td></tr><tr><td>No VIN yet</td><td>A car added by its plate alone: add the VIN when you have it</td></tr><tr><td>Possible duplicate</td><td>An open flag in Similar cars. Only Same car keeps the car off the site</td></tr><tr><td>Owner terms</td><td>The management fee (Revenue Share) and fees not set: a request uses the owner&#39;s terms or the standard grid</td></tr></tbody></table></div></section><section class="gd-task" id="fleet-and-listings-the-fleet-policy-rule-at-handover" data-gd-task><h2 class="gd-h2">The fleet policy rule at handover</h2><p class="gd-p">A program owner&#39;s car is listed and can be requested, offered and paid for while its paperwork is open. It is never handed over until the insurer confirms in writing that it is on the fleet insurance policy.</p><ul class="gd-ul"><li>Staff see a warning on a request and an offer for a car not on the policy yet.</li><li>The handover refuses the car until the insurer&#39;s confirmation is recorded (Owners and onboarding). The field app says so on the job.</li><li>Only real states keep a car off the site: retired, left the program, out of service, Turo only, bookings turned off, a self-managed owner in arrears, or a paused listing.</li></ul></section><section class="gd-task" id="fleet-and-listings-cars-on-sample-photos" data-gd-task><h2 class="gd-h2">Cars on sample photos</h2><p class="gd-p"><b class="gd-ui">Cars</b>, <b class="gd-ui">Listings</b> ends with <b class="gd-ui">Cars on sample photos</b>: each real car whose page still shows sample photos, with its newest handover photos (the check-in and check-out photos field staff take).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Where a handover photographed the car, press <b class="gd-ui">Use the handover photos</b>. They go into the car&#39;s listing as if taken on the capture screen.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When every required shot is there, the listing is submitted: the studio editor puts the car on the CarmaCars backdrop, then the listing waits for your review like any other.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car with no handover photos yet gets them at its next handover, or press <b class="gd-ui">Start a listing</b> and take them.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The studio editor uses Cloudflare image transformations (5,000 a month included). Settings &gt; Usage counts them.</div></aside></section><section class="gd-task" id="fleet-and-listings-a-car-s-registration-and-documents" data-gd-task><h2 class="gd-h2">A car&#39;s registration and documents</h2><p class="gd-p">Open the car, then <b class="gd-ui">Owner &amp; documents</b>. The <b class="gd-ui">Registration</b> card:</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Correct the <b class="gd-ui">VIN</b> (it is checked: 17 characters, the check digit, not on another car; decoded again for the body style and trim), the <b class="gd-ui">Year</b> and the <b class="gd-ui">Body style</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type the <b class="gd-ui">Ontario permit number</b> and the date the <b class="gd-ui">Plate sticker expires</b>. Fleet gets a task 30 days and 7 days before; save the new date after the renewal and the task closes.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under <b class="gd-ui">Documents</b>, choose the kind (<b class="gd-ui">Ownership permit</b>, Safety Standards Certificate, owner&#39;s insurance, other), pick the photo or PDF and press <b class="gd-ui">Upload</b>. The ownership permit clears that item of the owner&#39;s checklist.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">For the <b class="gd-ui">Safety Standards Certificate</b>, also type its number, the date it was issued and the date it expires. Fleet gets a task 30 days and 7 days before it expires; upload the new certificate with its dates and the task closes. It is a document on the car, not a service record, and nothing is billed to the owner.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Add a car</b> takes the ownership permit and the Safety Standards Certificate too, under <b class="gd-ui">Documents (optional)</b>.</div></li></ol></div></section><section class="gd-task" id="fleet-and-listings-a-car-added-under-the-wrong-owner" data-gd-task><h2 class="gd-h2">A car added under the wrong owner</h2><p class="gd-p">Open the car, Overview, <b class="gd-ui">Who supplies the car</b>, <b class="gd-ui">Move to another owner</b>. Choose the owner, or <b class="gd-ui">CarmaCars (owner not known yet)</b>: the car becomes a company car, with no owner schedule or terms.</p><ul class="gd-ul"><li>The car&#39;s unsigned owner application and vehicle schedule are withdrawn (kept in the history), and its draft owner invoices are deleted. Nobody is notified.</li><li>It is refused once anything for the car is signed, issued, paid or on a statement.</li></ul><h3 class="gd-h3">The VIN from the car, not typed</h3><p class="gd-p">Every VIN field (Add a car, Add a car for an owner, the car&#39;s <b class="gd-ui">Registration</b>, <b class="gd-ui">Start a listing</b>) has <b class="gd-ui">Scan the barcode</b> and <b class="gd-ui">Photo of the VIN</b>. Scan the barcode in the driver&#39;s door frame or at the bottom of the windshield: the phone&#39;s camera reads it by itself. Or take a photo of the VIN plate or sticker: the barcode in it is read first, else the photo is read for the printed VIN. The VIN is checked (17 characters, the check digit; I, O and Q become 1 and 0) and decoded as when you type it. Check it against the car before saving.</p><h3 class="gd-h3">Photos in any order</h3><p class="gd-p"><b class="gd-ui">Add photos</b> on the listing takes any number of photos at once from the camera roll. Each is sorted to its shot by itself (front three-quarter, sides, rear, dashboard, seats and the rest); a shot that already has its photo sends the new one to the extra photos, so nothing is replaced by accident. The shots are a guide, not a rule: a listing is complete with 10 photos that can go on the site and one outside photo for the cover. Outside photos get the studio background: the car is cropped to its edges and placed big in the frame with its wheels on the floor and a soft shadow under the tyres, and any corner watermark or caption beside the car is left out. Inside and detail photos are kept as taken; when one has a watermark, a logo or caption text on it, the edge with the mark is cut off by itself, and a photo whose mark cannot be cut off (one in the middle) stays off the site until you replace it. <b class="gd-ui">Cover the plate</b> opens on every outside photo with the plate box suggested; check it and save.</p><p class="gd-p">Outside photos made before the newest framing (the car small in the frame, or without the model&#39;s name behind it) are made again with <b class="gd-ui">Frame the outside photos again</b> above the photos of the listing, then <b class="gd-ui">Yes, frame again</b>. The cover and the main outside views get the model&#39;s name lettered behind the car, as on the sample photos (for example CLA, C CLASS, AMG GT). The photos leave the site until their plates are checked again: the plate box is suggested on the new photos; check each and cover it. On a published listing each goes back on the site once its plate is checked.</p></section><section class="gd-task" id="fleet-and-listings-extra-photos" data-gd-task><h2 class="gd-h2">Extra photos</h2><p class="gd-p">A photo that fits no shot is an extra photo. Under the shots, <b class="gd-ui">Extra outside photos</b> (put on the studio background) and <b class="gd-ui">Extra inside and detail photos</b> (touched up) each take any number at once. They count toward the 10 photos, get the same plate check, and come after the standard shots on the car&#39;s page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">In the review, <b class="gd-ui">Extra photos, in their order on the car page</b> lists them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Drag a photo by its handle (⋮⋮), or press <b class="gd-ui">Earlier</b> or <b class="gd-ui">Later</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the order</b>.</div></li></ol></div></section><section class="gd-task" id="fleet-and-listings-fix-a-cut-out" data-gd-task><h2 class="gd-h2">Fix a cut-out</h2><p class="gd-p">When the background removal cuts badly (a mirror or a wheel missing, background left beside the car), press <b class="gd-ui">Edit the cut-out</b> under the outside photo.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Cut-out</b> shows the car over the photo as taken, shown faintly. Choose <b class="gd-ui">Erase</b> and brush over what should go, or <b class="gd-ui">Restore</b> and brush over what the cut-out took off. Set <b class="gd-ui">Brush size</b> and <b class="gd-ui">Zoom</b>; when zoomed, <b class="gd-ui">Move the view</b> pans. <b class="gd-ui">Undo</b> takes back the last stroke.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">On the studio</b> shows the car on the studio background. Drag the car to move it and use <b class="gd-ui">Size</b> to make it larger or smaller. <b class="gd-ui">Centre and full size</b> puts it back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save as a new version</b>. The photo is made again in about a minute; the version before and the photo as taken are kept. <b class="gd-ui">Reset to the automatic cut-out</b> starts again from the automatic one.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>If the car did not move, the plate check carries over: a photo marked no plate visible stays so, and a covered plate is covered again on the new photo when the review is open. If the car moved, check the plate again. A photo made before cut-outs were kept shows <b class="gd-ui">Make the cut-out</b> first; the editor opens by itself when it is ready.</div></aside><p class="gd-p">Every photo also gets a light touch-up by itself (exposure, levels, a little contrast and colour, mild sharpening), never enough to change the paint colour or hide a scratch. Turn it off for one photo with <b class="gd-ui">Use original colours</b> under it (the photo is made again; approve it again), or for every photo in Admin &gt; Settings &gt; <b class="gd-ui">Program settings</b> (Listings) with <b class="gd-ui">Auto-enhance listing photos</b>. The photo as uploaded is always kept.</p></section><section class="gd-task" id="fleet-and-listings-import-photos-from-a-google-drive-link" data-gd-task><h2 class="gd-h2">Import photos from a Google Drive link</h2><p class="gd-p">The owner often hands over a car&#39;s photos as a public Google Drive folder, or one big folder with a folder per make and then per car. You do not download them: paste the link.</p><p class="gd-p"><b class="gd-ui">One car.</b> On the car&#39;s listing, under the capture, <b class="gd-ui">Import photos from a Google Drive link</b>. Paste the folder link (shared with Anyone with the link) and press <b class="gd-ui">Import the photos</b>. Every photo in the folder, and in the folders inside it, is added to this car as if you had pressed Add photos: each is sorted to its shot (else filed as an extra photo, in file-name order), put on the studio background and checked for its plate. The box under the link, <b class="gd-ui">Submit the listing for processing when its photos are in</b>, is on by default.</p><p class="gd-p"><b class="gd-ui">Many cars.</b> <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Import photos from Drive</b> (a button on Vehicles). Paste the top folder&#39;s link and press <b class="gd-ui">Read the folder</b>. The page walks every folder and proposes a car for each folder that holds photos, from the year, make, model, colour and plate in the folder names (the make folder above counts; 01 Motors partner cars come first). Check the table: tick or untick <b class="gd-ui">Import</b>, change the car in the list (the likely cars come first), leave out a folder with <b class="gd-ui">Do not import this folder</b>. A line marked <b class="gd-ui">Check this one</b> matched two alike cars. Then press <b class="gd-ui">Import N photos from M folders</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The page follows the import by itself. You can leave it and come back: it runs in the background.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The end shows the summary: imported, skipped and failed, and why for each (a file over 15 MB, a file that is not a photo, the same photo already on the car, a folder not shared).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Try the failed photos again</b> takes only the ones that failed. Pressing Import on the same link again never adds a photo twice: a Drive file already on the car is skipped, and so is the same picture under another name. A photo you took off the car can be imported again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>JPG, PNG, HEIC and WebP only (HEIC and WebP are made JPEG first). At most 15 MB a photo, 600 photos, 400 folders and 4 GB in one import. Drive is asked politely, one photo at a time; a big import takes a while.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Without a key, Drive shows only the first 50 files of a folder on its public page; a folder with more is read in full when Drive allows it. In <b class="gd-ui">Settings</b>, the <b class="gd-ui">Photo import from Google Drive</b> box takes a Google API key with the Drive API on (after it is saved only its last 4 characters are shown, and it is never written to the change log): with it, folders of any size are read and photos download without Drive&#39;s warning pages.</div></aside></section><section class="gd-task" id="fleet-and-listings-pickup-from-owner-and-return-to-owner-release-28" data-gd-task><h2 class="gd-h2">Pickup from owner and return to owner (release 28)</h2><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Pickup from owner and return to owner</b> records the car&#39;s condition when CarmaCars picks it up from its owner or gives it back: the date and time, km, fuel, many photos at once with the suggested angles, and notes. <b class="gd-ui">Add photos</b> adds more to a record later. The owner sees these records read only on the car&#39;s page in their portal. They are the baseline condition for any dispute.</p></section><section class="gd-task" id="fleet-and-listings-incident-cards-release-34" data-gd-task><h2 class="gd-h2">Incident cards (release 34)</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b> &gt; <b class="gd-ui">Incident cards</b> prints the card for each car: what to do in an accident or a breakdown, the support number from Settings, a roadside number when there is one, a QR code to report it in the app, and the fleet insurance slip. Open a car and press <b class="gd-ui">Incident card</b> to print only that car; on the list, <b class="gd-ui">Print all cars</b> prints them all, two cards to a Letter page with crop marks, ready to laminate. Under Fleet insurance policy press <b class="gd-ui">Add the policy</b> (the insurer, the policy number, the dates, the named insured, the roadside number on the slip) and choose the uploaded slip if you have one: it is printed as it is, otherwise the fields are. The card never shows a premium. Fleet staff print the same cards from their portal.</p></section><section class="gd-task" id="fleet-and-listings-field-jobs-shifts-and-who-gets-a-job" data-gd-task><h2 class="gd-h2">Field jobs, shifts and who gets a job</h2><p class="gd-p"><b class="gd-ui">Cars</b>, then <b class="gd-ui">Field jobs</b>, is the board Fleet uses, with every action Fleet has. Field staff take shifts you publish with <b class="gd-ui">Publish shifts</b>; jobs are given by themselves only to a field person who passed the academy and holds a shift that day, and work lands only on days with shifts (work due on a day without shifts moves to the day before, or to the next day with shifts when it comes in on the day; the booking&#39;s own times never change). A booking whose handover or return falls on a day with no shifts shows a warning on the board and on the booking. You can give a job to a field person or to an Admin, take it off with <b class="gd-ui">Unassign</b> (tick <b class="gd-ui">Tell them</b> to let them know), and an Admin who holds a job opens it on the field portal. A person who has not passed the academy cannot be given a job or take a shift.</p></section>');
select app.guide_release_section('va', 'fleet', 'chapter', 'finance', 'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listings with their duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking''s times and place, given to the field staff member with the fewest jobs that day. You check and change them.

1. Jobs, next three days: each with its place, its field staff and whether they acknowledged it. "Made from the booking" marks the ones made by themselves; when the booking moves, they move too, unless you changed them.
2. Change a job with **Assign**, **Reassign**, **Move** (time and place) or **Cancel**.
3. Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press **Schedule**, the place filled in from the booking.
4. An Admin turns the automatic jobs or the assignment off in Settings > Program.

![](/guides/img/va-fleet-02-field-jobs-desktop-8e721230.jpg "desktop; size: 1230 565; address: carmacars.ca/va/fleet; pins: 1 17.9 51.3")

## Fleet map

At the top of **Field jobs**: every car on the map with its renter, booking, due-back time and state, the alerts, and the trips by booking, the same as the Admin''s. Only Admins and fleet staff see positions.

1. Press a car for its card: last report, odometer, fuel, tracker battery and the trip under way.
2. An alert (speeding, left Ontario or the zone, still driving after the return time, low or unplugged tracker, not reporting) also comes to your bell and as an urgent phone alert. Call the renter, then press **Seen**.
3. A car still driving after its return time: call, send the late notice and offer a paid extension, as for any late return.

## Field hours

Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.

1. Open **Field hours**. **Clocked in now** lists who is on, since when. **Earlier period** and **Later period** move between pay periods.
2. Someone forgot to clock out: press **Clock out for them**, set the time they finished and write the reason.
3. Someone forgot to clock in, or a time is wrong: **Add hours** enters a shift, **Change** fixes one and **Remove** takes one out. Each needs a reason; the change is kept in a log with what it was before.
4. Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Check a car out or in

Fleet, Sales and Customer service check cars out and in from the booking.

1. On a confirmed booking press **Check in (pickup)**; on a booking on rent, **Check out (return)**. Today lists the ones due, each with its button.
2. The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.
3. Afterwards press **Photo report**: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with **Waive** and a reason.

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs and its **Rates & fees** tab.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. The listing''s Steps to go live says what is next: 1 Photos, 2 Cover plates, 3 Review, 4 Live on the site, each with its button. The plate box is suggested by itself on every outside photo as the listing opens (Box suggested). Press **Cover the plate** and check it; **Suggest the plate** asks again. A photo filed under the wrong shot: **Remove** under it on the Photos card, then take the right one.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.

### Add the photos and readings
A pickup or return recorded with the details later gives Fleet the task **Add the photos and readings for CC-...**. Open the booking and press **Add the check-in (or check-out) photos and readings**: the usual checklist opens without the ready check or the renter''s signature. Take the photos, the odometer, fuel, keys (and cleanliness at a return), sign and save. The task closes by itself; it cannot be closed by hand before.

## Bookings now

**Rentals** > **Bookings** opens on Now for fleet and customer service: the cars out with their renter and due-back countdown, coming back today and tomorrow (overdue first, in red), going out in the next 72 hours with what is ready, the money due in 7 days and the free cars. It refreshes by itself every 30 seconds. A booking listed as **Out (pickup not recorded)** left without a check-in: press **Mark picked up**, then add the photos, km and fuel from the task. A car overdue or due back today has **Returned** (here, on Today and at the top of the booking): give the return time (now, or earlier; the late charges follow it) and the km and fuel if known. The overdue messages stop and the task for the photos is yours. The search above it finds any booking.

### The renter says the car is back

An urgent To do "The renter says the car is back" means the renter pressed **I''ve returned the car** on an overdue booking. Their overdue notices are paused. Open the booking, check the car (place, tracker, the renter''s photos), then press **Confirm** (correct the odometer, fuel or time first if needed; the trip is completed) or **Deny** with the reason (the renter is told and the notices start again).

**Start a listing** takes the VIN from the car: **Scan the barcode** in the door frame or under the windshield, or **Photo of the VIN**.

**Add photos** on a listing takes any number of photos at once, in any order: each is sorted to its shot. A photo that fits no shot goes in with **Extra outside photos** or **Extra inside and detail photos**; drag the extras into their order in the review and press **Save the order**. 10 photos and one outside photo complete the listing. Outside photos are framed big on the studio floor with a shadow under the tyres; a watermark or caption at a photo''s edge is cut off by itself. **Cover the plate** opens with the plate box suggested: check it and save. A car small in the frame, or no model name behind it: press **Frame the outside photos again** (then check the plates again). A bad cut-out (a mirror missing, background left): press **Edit the cut-out**, erase or restore with the brush, move or size the car on the studio, then **Save as a new version**. The version before is kept; if the car did not move, the plate check carries over. Every photo gets a light touch-up by itself; tick **Use original colours** under a photo to make it again without it.
## One screen, many photos (release 28)

**Import photos from a Google Drive link** on a listing adds the photos of a public Drive folder to the car, sorted and processed like Add photos. **Listings** > **Import photos from Drive** reads a whole folder of folders (one per make, then per car), proposes the car for each folder, and imports once you confirm the table. The page follows the import and ends with what was imported, skipped and failed, and why. The same Drive file is never added twice. Customer service can import into a car whose listing is already started; Fleet and Admin can start one.

Check-in and check-out are one screen on the booking page: the time, km, fuel, many photos at once (tag angles if you like) and a note. The renter''s own photos join the same report; each photo shows who took it. On a car''s page, record **Pickup from owner** and **Return to owner** with photos: the owner sees them.

## Repair costs on a car

On a car''s page, **Kickbacks and repairs** lists its repair costs and the kickbacks partners paid on it. **Add a repair cost**: the date, the shop or another vendor, what was done, the amount and tax, who paid (CarmaCars, the owner or the insurer), the claim and a photo or PDF of the receipt.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Incident cards (release 34)
**Cars**, then **Incident cards**, prints the card for the visor or the glovebox: what to do in an accident or a breakdown, our support and roadside numbers, a QR code to report it in the app, and the fleet insurance slip. On a car''s page, **Incident card** prints that car; on the list, **Print all cars** prints every car, two cards to a Letter page with crop marks. Laminate it and put one in each car. The insurance policy on the card is set by an Admin; until it is, the card tells the renter to ask for the slip. No price is ever printed on it.

## Government forms (release 35)
The official ServiceOntario forms of each owner''s car are on the owner''s page and the car''s page, under **Government forms**. Open a form, press **Change a value**, choose the box, type the value and the reason, and **Save**: the form is made again as a new version, and the earlier versions stay under **Versions** with their downloads. **Back to the records** undoes a change. A form signed in ink or filed is never changed. **Make again** keeps the values changed by hand unless you tick **Discard the values changed by hand**. **Owners**, then **Government forms**, opens the forms'' mapping (which value goes in which box): preview it on a sample car, write what you changed and save; every save is kept under **Earlier mappings**. Only the boxes are filled: the form''s own text and layout never change.', 'Fleet', 'Field jobs, daily checks, photo reviews, similar cars and listings.',
  'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listings with their duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking''s times and place, given to the field staff member with the fewest jobs that day who is on a shift (see Shifts and who gets a job). You check and change them.

1. Jobs, next three days: each with its place, its field staff and whether they acknowledged it. "Made from the booking" marks the ones made by themselves; when the booking moves, they move too, unless you changed them.
2. Change a job with **Assign**, **Reassign**, **Move** (time and place) or **Cancel**.
3. Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press **Schedule**, the place filled in from the booking.
4. An Admin turns the automatic jobs or the assignment off in Settings > Program.

![](/guides/img/va-fleet-02-field-jobs-desktop-8e721230.jpg "desktop; size: 1230 565; address: carmacars.ca/va/fleet; pins: 1 17.9 51.3")

## Shifts and who gets a job

Field staff take their shifts from a schedule you publish, ideally a week ahead. A job is given by itself only to a field person who passed the academy and holds a shift that day, and work lands only on days with shifts.

1. On **Field jobs**, **Shifts, next seven days** shows each day and how many people are on a shift. A day marked **Nobody on a shift** needs shifts, or someone to cover it.
2. Press **Publish shifts**: the first day''s start and end, how many people, and for how many days the same hours repeat. Field staff take them on their phones.
3. **Add a person** puts someone on a shift and **Remove** takes them off. A person who has not passed the academy cannot take shifts or be given a job.
4. Work due on a day with no shifts moves to the day before when it is known in advance, or to the next day with shifts when it comes in on the day. The job shows its planned day and keeps the booking''s real time; the renter''s times never change. A booking whose handover or return falls on a day with no shifts shows a warning: cover it, or move the booking time.
5. **Unassign** takes a job off a person; tick **Tell them** only if they should know. The Admins can be given a job too.

## Fleet map

At the top of **Field jobs**: every car on the map with its renter, booking, due-back time and state, the alerts, and the trips by booking, the same as the Admin''s. Only Admins and fleet staff see positions.

1. Press a car for its card: last report, odometer, fuel, tracker battery and the trip under way.
2. An alert (speeding, left Ontario or the zone, still driving after the return time, low or unplugged tracker, not reporting) also comes to your bell and as an urgent phone alert. Call the renter, then press **Seen**.
3. A car still driving after its return time: call, send the late notice and offer a paid extension, as for any late return.

## Field hours

Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.

1. Open **Field hours**. **Clocked in now** lists who is on, since when. **Earlier period** and **Later period** move between pay periods.
2. Someone forgot to clock out: press **Clock out for them**, set the time they finished and write the reason.
3. Someone forgot to clock in, or a time is wrong: **Add hours** enters a shift, **Change** fixes one and **Remove** takes one out. Each needs a reason; the change is kept in a log with what it was before.
4. Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Check a car out or in

Fleet, Sales and Customer service check cars out and in from the booking.

1. On a confirmed booking press **Check in (pickup)**; on a booking on rent, **Check out (return)**. Today lists the ones due, each with its button.
2. The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.
3. Afterwards press **Photo report**: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with **Waive** and a reason.

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs and its **Rates & fees** tab.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. The listing''s Steps to go live says what is next: 1 Photos, 2 Cover plates, 3 Review, 4 Live on the site, each with its button. The plate box is suggested by itself on every outside photo as the listing opens (Box suggested). Press **Cover the plate** and check it; **Suggest the plate** asks again. A photo filed under the wrong shot: **Remove** under it on the Photos card, then take the right one.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.

### Add the photos and readings
A pickup or return recorded with the details later gives Fleet the task **Add the photos and readings for CC-...**. Open the booking and press **Add the check-in (or check-out) photos and readings**: the usual checklist opens without the ready check or the renter''s signature. Take the photos, the odometer, fuel, keys (and cleanliness at a return), sign and save. The task closes by itself; it cannot be closed by hand before.

## Bookings now

**Rentals** > **Bookings** opens on Now for fleet and customer service: the cars out with their renter and due-back countdown, coming back today and tomorrow (overdue first, in red), going out in the next 72 hours with what is ready, the money due in 7 days and the free cars. It refreshes by itself every 30 seconds. A booking listed as **Out (pickup not recorded)** left without a check-in: press **Mark picked up**, then add the photos, km and fuel from the task. A car overdue or due back today has **Returned** (here, on Today and at the top of the booking): give the return time (now, or earlier; the late charges follow it) and the km and fuel if known. The overdue messages stop and the task for the photos is yours. The search above it finds any booking.

### The renter says the car is back

An urgent To do "The renter says the car is back" means the renter pressed **I''ve returned the car** on an overdue booking. Their overdue notices are paused. Open the booking, check the car (place, tracker, the renter''s photos), then press **Confirm** (correct the odometer, fuel or time first if needed; the trip is completed) or **Deny** with the reason (the renter is told and the notices start again).

**Start a listing** takes the VIN from the car: **Scan the barcode** in the door frame or under the windshield, or **Photo of the VIN**.

**Add photos** on a listing takes any number of photos at once, in any order: each is sorted to its shot. A photo that fits no shot goes in with **Extra outside photos** or **Extra inside and detail photos**; drag the extras into their order in the review and press **Save the order**. 10 photos and one outside photo complete the listing. Outside photos are framed big on the studio floor with a shadow under the tyres; a watermark or caption at a photo''s edge is cut off by itself. **Cover the plate** opens with the plate box suggested: check it and save. A car small in the frame, or no model name behind it: press **Frame the outside photos again** (then check the plates again). A bad cut-out (a mirror missing, background left): press **Edit the cut-out**, erase or restore with the brush, move or size the car on the studio, then **Save as a new version**. The version before is kept; if the car did not move, the plate check carries over. Every photo gets a light touch-up by itself; tick **Use original colours** under a photo to make it again without it.
## One screen, many photos (release 28)

**Import photos from a Google Drive link** on a listing adds the photos of a public Drive folder to the car, sorted and processed like Add photos. **Listings** > **Import photos from Drive** reads a whole folder of folders (one per make, then per car), proposes the car for each folder, and imports once you confirm the table. The page follows the import and ends with what was imported, skipped and failed, and why. The same Drive file is never added twice. Customer service can import into a car whose listing is already started; Fleet and Admin can start one.

Check-in and check-out are one screen on the booking page: the time, km, fuel, many photos at once (tag angles if you like) and a note. The renter''s own photos join the same report; each photo shows who took it. On a car''s page, record **Pickup from owner** and **Return to owner** with photos: the owner sees them.

## Repair costs on a car

On a car''s page, **Kickbacks and repairs** lists its repair costs and the kickbacks partners paid on it. **Add a repair cost**: the date, the shop or another vendor, what was done, the amount and tax, who paid (CarmaCars, the owner or the insurer), the claim and a photo or PDF of the receipt.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Incident cards (release 34)
**Cars**, then **Incident cards**, prints the card for the visor or the glovebox: what to do in an accident or a breakdown, our support and roadside numbers, a QR code to report it in the app, and the fleet insurance slip. On a car''s page, **Incident card** prints that car; on the list, **Print all cars** prints every car, two cards to a Letter page with crop marks. Laminate it and put one in each car. The insurance policy on the card is set by an Admin; until it is, the card tells the renter to ask for the slip. No price is ever printed on it.

## Government forms (release 35)
The official ServiceOntario forms of each owner''s car are on the owner''s page and the car''s page, under **Government forms**. Open a form, press **Change a value**, choose the box, type the value and the reason, and **Save**: the form is made again as a new version, and the earlier versions stay under **Versions** with their downloads. **Back to the records** undoes a change. A form signed in ink or filed is never changed. **Make again** keeps the values changed by hand unless you tick **Discard the values changed by hand**. **Owners**, then **Government forms**, opens the forms'' mapping (which value goes in which box): preview it on a sample car, write what you changed and save; every save is kept under **Earlier mappings**. Only the boxes are filled: the form''s own text and layout never change.',
  '<p class="gd-p">You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listings with their duplicate check and plate covering.</p><p class="gd-p">Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.</p><section class="gd-task" id="fleet-schedule-field-jobs" data-gd-task><h2 class="gd-h2">Schedule field jobs</h2><p class="gd-p">Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking&#39;s times and place, given to the field staff member with the fewest jobs that day who is on a shift (see Shifts and who gets a job). You check and change them.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Jobs, next three days: each with its place, its field staff and whether they acknowledged it. &quot;Made from the booking&quot; marks the ones made by themselves; when the booking moves, they move too, unless you changed them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Change a job with <b class="gd-ui">Assign</b>, <b class="gd-ui">Reassign</b>, <b class="gd-ui">Move</b> (time and place) or <b class="gd-ui">Cancel</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press <b class="gd-ui">Schedule</b>, the place filled in from the booking.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An Admin turns the automatic jobs or the assignment off in Settings &gt; Program.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/fleet</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/565"><img src="/guides/img/va-fleet-02-field-jobs-desktop-8e721230.jpg" alt="" loading="lazy" decoding="async" width="1230" height="565"><span class="gd-pin" style="left:17.9%;top:51.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="fleet-shifts-and-who-gets-a-job" data-gd-task><h2 class="gd-h2">Shifts and who gets a job</h2><p class="gd-p">Field staff take their shifts from a schedule you publish, ideally a week ahead. A job is given by itself only to a field person who passed the academy and holds a shift that day, and work lands only on days with shifts.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <b class="gd-ui">Field jobs</b>, <b class="gd-ui">Shifts, next seven days</b> shows each day and how many people are on a shift. A day marked <b class="gd-ui">Nobody on a shift</b> needs shifts, or someone to cover it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Publish shifts</b>: the first day&#39;s start and end, how many people, and for how many days the same hours repeat. Field staff take them on their phones.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Add a person</b> puts someone on a shift and <b class="gd-ui">Remove</b> takes them off. A person who has not passed the academy cannot take shifts or be given a job.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Work due on a day with no shifts moves to the day before when it is known in advance, or to the next day with shifts when it comes in on the day. The job shows its planned day and keeps the booking&#39;s real time; the renter&#39;s times never change. A booking whose handover or return falls on a day with no shifts shows a warning: cover it, or move the booking time.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Unassign</b> takes a job off a person; tick <b class="gd-ui">Tell them</b> only if they should know. The Admins can be given a job too.</div></li></ol></div></section><section class="gd-task" id="fleet-fleet-map" data-gd-task><h2 class="gd-h2">Fleet map</h2><p class="gd-p">At the top of <b class="gd-ui">Field jobs</b>: every car on the map with its renter, booking, due-back time and state, the alerts, and the trips by booking, the same as the Admin&#39;s. Only Admins and fleet staff see positions.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press a car for its card: last report, odometer, fuel, tracker battery and the trip under way.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An alert (speeding, left Ontario or the zone, still driving after the return time, low or unplugged tracker, not reporting) also comes to your bell and as an urgent phone alert. Call the renter, then press <b class="gd-ui">Seen</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car still driving after its return time: call, send the late notice and offer a paid extension, as for any late return.</div></li></ol></div></section><section class="gd-task" id="fleet-field-hours" data-gd-task><h2 class="gd-h2">Field hours</h2><p class="gd-p">Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Field hours</b>. <b class="gd-ui">Clocked in now</b> lists who is on, since when. <b class="gd-ui">Earlier period</b> and <b class="gd-ui">Later period</b> move between pay periods.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Someone forgot to clock out: press <b class="gd-ui">Clock out for them</b>, set the time they finished and write the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Someone forgot to clock in, or a time is wrong: <b class="gd-ui">Add hours</b> enters a shift, <b class="gd-ui">Change</b> fixes one and <b class="gd-ui">Remove</b> takes one out. Each needs a reason; the change is kept in a log with what it was before.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.</div></li></ol></div></section><section class="gd-task" id="fleet-daily-checks" data-gd-task><h2 class="gd-h2">Daily checks</h2><p class="gd-p">Twice a day: the opening check by 9:00 and the closing check by 18:00.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Daily checks</b> and choose <b class="gd-ui">Opening check</b> or <b class="gd-ui">Closing check</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows what was found. Tick OK, or Problem with a note.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the opening check</b> (or <b class="gd-ui">Save the closing check</b>). You can save it again.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/checks</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/820"><img src="/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg" alt="" loading="lazy" decoding="async" width="1230" height="820"><span class="gd-pin" style="left:6.5%;top:15.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:44.7%;top:42%" aria-hidden="true">2</span><span class="gd-pin" style="left:64.2%;top:94%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">Fleet, Sales and Customer service check cars out and in from the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a confirmed booking press <b class="gd-ui">Check in (pickup)</b>; on a booking on rent, <b class="gd-ui">Check out (return)</b>. Today lists the ones due, each with its button.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Afterwards press <b class="gd-ui">Photo report</b>: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with <b class="gd-ui">Waive</b> and a reason.</div></li></ol></div></section><section class="gd-task" id="fleet-photo-reviews-after-a-return" data-gd-task><h2 class="gd-h2">Photo reviews after a return</h2><p class="gd-p">After each return, the field photo set waits under <b class="gd-ui">Photo reviews</b>. Compare it with the pickup set. Press <b class="gd-ui">Review done</b>, or <b class="gd-ui">Ask for a re-shoot</b> if a photo is missing or unclear.</p></section><section class="gd-task" id="fleet-similar-cars" data-gd-task><h2 class="gd-h2">Similar cars</h2><p class="gd-p">A possible duplicate never keeps a car off the site: it shows on the car&#39;s checklist until you decide. Only Same car takes it off.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Compare the permit, the plate and the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Not a duplicate</b> with a note when they are different cars, or <b class="gd-ui">Same car</b> when they are.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/similar-cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/460"><img src="/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg" alt="" loading="lazy" decoding="async" width="1230" height="460"><span class="gd-pin" style="left:23.6%;top:30.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:30.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-rates-and-kilometres" data-gd-task><h2 class="gd-h2">Rates and kilometres</h2><p class="gd-p">From a listing, press <b class="gd-ui">The car and its rates</b>, or open the car from Field jobs and its <b class="gd-ui">Rates &amp; fees</b> tab.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Keep <b class="gd-ui">Use the defaults</b> for the kilometres, or choose <b class="gd-ui">Custom for this car</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check What renters pay under the fields, then press <b class="gd-ui">Save the rates</b>. Rates, kilometres and deposit save together.</div></li></ol></div></section><section class="gd-task" id="fleet-listings-and-covering-plates" data-gd-task><h2 class="gd-h2">Listings and covering plates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Listings</b>. A draft waiting shows Needs review. Open it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/340"><img src="/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="340"><span class="gd-pin" style="left:54.5%;top:49.1%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The listing&#39;s Steps to go live says what is next: 1 Photos, 2 Cover plates, 3 Review, 4 Live on the site, each with its button. The plate box is suggested by itself on every outside photo as the listing opens (Box suggested). Press <b class="gd-ui">Cover the plate</b> and check it; <b class="gd-ui">Suggest the plate</b> asks again. A photo filed under the wrong shot: <b class="gd-ui">Remove</b> under it on the Photos card, then take the right one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Drag over a plate to draw a box; drag a box to move it, its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>, then <b class="gd-ui">Save the covered photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">No plate in the shot? <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/776"><img src="/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg" alt="" loading="lazy" decoding="async" width="390" height="776"><span class="gd-pin" style="left:52.6%;top:78.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:50%;top:43.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.5%;top:62.1%" aria-hidden="true">5</span><span class="gd-pin" style="left:43.1%;top:92.3%" aria-hidden="true">6</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.</div></aside></section><section class="gd-task" id="fleet-publish-now" data-gd-task><h2 class="gd-h2">Publish now</h2><p class="gd-p">Customer service and fleet publish a car themselves; nothing has to be finished first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press <b class="gd-ui">Publish now</b>. With no rates yet it uses the suggested rates (similar cars, else the class defaults).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.</div></aside></section><section class="gd-task" id="fleet-calendar-sync-with-turo-and-other-platforms" data-gd-task><h2 class="gd-h2">Calendar sync with Turo and other platforms</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: a car listed on Turo or Getaround must never be booked twice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turo has no calendar link: Turo&#39;s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An email the reader cannot place waits as &quot;Which car is this?&quot;: press <b class="gd-ui">Which car is this?</b> and press the right car (best guesses first). It is remembered for that car&#39;s next emails. If the dates or trip number are missing: <b class="gd-ui">Add as a Turo trip</b> (choose the car, check the dates) or <b class="gd-ui">Dismiss</b>. A trip whose email did not come: <b class="gd-ui">Add a Turo trip</b> on the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each Turo trip shows the guest&#39;s name and phone when Turo&#39;s email includes them. Contact a Turo guest only about their trip, never with promotions.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Turo cannot read our calendar: under &quot;Block on Turo&quot;, block each CarmaCars booking on the car&#39;s Turo calendar, then press <b class="gd-ui">Done on Turo</b>. Dates that changed or a booking cancelled here show the dates to free on Turo.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Getaround, Google Calendar or another platform with a calendar (iCal) link: open <b class="gd-ui">Add a calendar link</b>, choose the platform, paste it and press <b class="gd-ui">Add the link</b>. Copy the car&#39;s CarmaCars link for that platform with <b class="gd-ui">Copy</b> and paste it into the platform&#39;s calendar import.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.</div></li></ol></div><h3 class="gd-h3">Add the photos and readings</h3><p class="gd-p">A pickup or return recorded with the details later gives Fleet the task <b class="gd-ui">Add the photos and readings for CC-...</b>. Open the booking and press <b class="gd-ui">Add the check-in (or check-out) photos and readings</b>: the usual checklist opens without the ready check or the renter&#39;s signature. Take the photos, the odometer, fuel, keys (and cleanliness at a return), sign and save. The task closes by itself; it cannot be closed by hand before.</p></section><section class="gd-task" id="fleet-bookings-now" data-gd-task><h2 class="gd-h2">Bookings now</h2><p class="gd-p"><b class="gd-ui">Rentals</b> &gt; <b class="gd-ui">Bookings</b> opens on Now for fleet and customer service: the cars out with their renter and due-back countdown, coming back today and tomorrow (overdue first, in red), going out in the next 72 hours with what is ready, the money due in 7 days and the free cars. It refreshes by itself every 30 seconds. A booking listed as <b class="gd-ui">Out (pickup not recorded)</b> left without a check-in: press <b class="gd-ui">Mark picked up</b>, then add the photos, km and fuel from the task. A car overdue or due back today has <b class="gd-ui">Returned</b> (here, on Today and at the top of the booking): give the return time (now, or earlier; the late charges follow it) and the km and fuel if known. The overdue messages stop and the task for the photos is yours. The search above it finds any booking.</p><h3 class="gd-h3">The renter says the car is back</h3><p class="gd-p">An urgent To do &quot;The renter says the car is back&quot; means the renter pressed <b class="gd-ui">I&#39;ve returned the car</b> on an overdue booking. Their overdue notices are paused. Open the booking, check the car (place, tracker, the renter&#39;s photos), then press <b class="gd-ui">Confirm</b> (correct the odometer, fuel or time first if needed; the trip is completed) or <b class="gd-ui">Deny</b> with the reason (the renter is told and the notices start again).</p><p class="gd-p"><b class="gd-ui">Start a listing</b> takes the VIN from the car: <b class="gd-ui">Scan the barcode</b> in the door frame or under the windshield, or <b class="gd-ui">Photo of the VIN</b>.</p><p class="gd-p"><b class="gd-ui">Add photos</b> on a listing takes any number of photos at once, in any order: each is sorted to its shot. A photo that fits no shot goes in with <b class="gd-ui">Extra outside photos</b> or <b class="gd-ui">Extra inside and detail photos</b>; drag the extras into their order in the review and press <b class="gd-ui">Save the order</b>. 10 photos and one outside photo complete the listing. Outside photos are framed big on the studio floor with a shadow under the tyres; a watermark or caption at a photo&#39;s edge is cut off by itself. <b class="gd-ui">Cover the plate</b> opens with the plate box suggested: check it and save. A car small in the frame, or no model name behind it: press <b class="gd-ui">Frame the outside photos again</b> (then check the plates again). A bad cut-out (a mirror missing, background left): press <b class="gd-ui">Edit the cut-out</b>, erase or restore with the brush, move or size the car on the studio, then <b class="gd-ui">Save as a new version</b>. The version before is kept; if the car did not move, the plate check carries over. Every photo gets a light touch-up by itself; tick <b class="gd-ui">Use original colours</b> under a photo to make it again without it.</p></section><section class="gd-task" id="fleet-one-screen-many-photos-release-28" data-gd-task><h2 class="gd-h2">One screen, many photos (release 28)</h2><p class="gd-p"><b class="gd-ui">Import photos from a Google Drive link</b> on a listing adds the photos of a public Drive folder to the car, sorted and processed like Add photos. <b class="gd-ui">Listings</b> &gt; <b class="gd-ui">Import photos from Drive</b> reads a whole folder of folders (one per make, then per car), proposes the car for each folder, and imports once you confirm the table. The page follows the import and ends with what was imported, skipped and failed, and why. The same Drive file is never added twice. Customer service can import into a car whose listing is already started; Fleet and Admin can start one.</p><p class="gd-p">Check-in and check-out are one screen on the booking page: the time, km, fuel, many photos at once (tag angles if you like) and a note. The renter&#39;s own photos join the same report; each photo shows who took it. On a car&#39;s page, record <b class="gd-ui">Pickup from owner</b> and <b class="gd-ui">Return to owner</b> with photos: the owner sees them.</p></section><section class="gd-task" id="fleet-repair-costs-on-a-car" data-gd-task><h2 class="gd-h2">Repair costs on a car</h2><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Kickbacks and repairs</b> lists its repair costs and the kickbacks partners paid on it. <b class="gd-ui">Add a repair cost</b>: the date, the shop or another vendor, what was done, the amount and tax, who paid (CarmaCars, the owner or the insurer), the claim and a photo or PDF of the receipt.</p></section><section class="gd-task" id="fleet-when-a-check-stops-the-pickup-or-the-return-release-33" data-gd-task><h2 class="gd-h2">When a check stops the pickup or the return (release 33)</h2><p class="gd-p">On the booking page, <b class="gd-ui">What stops the pickup now</b> (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press <b class="gd-ui">Ask an Admin to override the pickup</b> (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking&#39;s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: <b class="gd-ui">Ask to record a past trip</b> with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.</p></section><section class="gd-task" id="fleet-incident-cards-release-34" data-gd-task><h2 class="gd-h2">Incident cards (release 34)</h2><p class="gd-p"><b class="gd-ui">Cars</b>, then <b class="gd-ui">Incident cards</b>, prints the card for the visor or the glovebox: what to do in an accident or a breakdown, our support and roadside numbers, a QR code to report it in the app, and the fleet insurance slip. On a car&#39;s page, <b class="gd-ui">Incident card</b> prints that car; on the list, <b class="gd-ui">Print all cars</b> prints every car, two cards to a Letter page with crop marks. Laminate it and put one in each car. The insurance policy on the card is set by an Admin; until it is, the card tells the renter to ask for the slip. No price is ever printed on it.</p></section><section class="gd-task" id="fleet-government-forms-release-35" data-gd-task><h2 class="gd-h2">Government forms (release 35)</h2><p class="gd-p">The official ServiceOntario forms of each owner&#39;s car are on the owner&#39;s page and the car&#39;s page, under <b class="gd-ui">Government forms</b>. Open a form, press <b class="gd-ui">Change a value</b>, choose the box, type the value and the reason, and <b class="gd-ui">Save</b>: the form is made again as a new version, and the earlier versions stay under <b class="gd-ui">Versions</b> with their downloads. <b class="gd-ui">Back to the records</b> undoes a change. A form signed in ink or filed is never changed. <b class="gd-ui">Make again</b> keeps the values changed by hand unless you tick <b class="gd-ui">Discard the values changed by hand</b>. <b class="gd-ui">Owners</b>, then <b class="gd-ui">Government forms</b>, opens the forms&#39; mapping (which value goes in which box): preview it on a sample car, write what you changed and save; every save is kept under <b class="gd-ui">Earlier mappings</b>. Only the boxes are filled: the form&#39;s own text and layout never change.</p></section>');
select app.guide_release_section('field', 'my-jobs', 'chapter', 'start-here', 'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Cars now**, **Map** (where the cars of your jobs are now, with their trips and alerts), **My hours** and **Me** (My sales, Referrals, Profile and Academy, as a row on top). **Add a rental** and **Report a problem** are buttons at the top of My jobs. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. The next job is the big card at the top: its time and how long until it, the car and its plate, the place with **Open in maps** and a button to call the renter, and what to put in the car. The rest of the day follows in time order.
4. A handover or a return has its own button: **Check in (pickup)** or **Check out (return)**. One tap acknowledges and starts the job and opens its photo checklist. Other jobs: press **Open the job**.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-b31e25fb.jpg "phone; size: 390 1530; pins: 1 91.0 15.0, 2 89.7 53.3, 3 89.7 61.4, 4 89.7 88.2")

> Tip: Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions, and a button to call the renter.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-c6780f54.jpg "phone; size: 390 1530; pins: 1 94.9 34.0, 2 94.9 44.1, 3 94.9 52.6, 4 94.9 95.8")

## Check the renter''s licence

The renter''s licence photos and selfie are checked before the handover. You can check them yourself, for a booking on one of your own jobs today or in the next 7 days. Everything you do is recorded with your name and "field staff".

1. My jobs shows **Licences to check** when the licence front, back or selfie of a renter on one of your jobs waits for a decision. The same check is on the job itself, under **Check the licence**.
2. Press **Review the licence**. The images open with the name, date of birth and licence details on the booking.
3. Look at each image and the licence reader''s lines under each driver (Pass or Flag: valid to the return, class, age, name and date of birth, the Ontario number, front and back): no sign of alteration, and the selfie matches the licence photo. A photo you take that is blurry or cut off says so at once: take it again.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told why and sends a new one.
5. Then press **Approve all**: everything still waiting is approved at once.

> Tip: The renter''s proof of coverage stays with the office. Meeting the renter at the handover? You can still check the original licence in person from the ready check (see A handover).

## Move a car

1. Under Vehicle moves, press **Start a move**. Choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km), then press **Start the move now**.
3. When you arrive, press **End the move**, fill in Now at and the odometer, then press **End the move now**.

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Sign in a few steps: press **Send the code** and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the key terms (confidentiality, the rules on money, keys and cars, ending the agreement), tick the two consents and draw your signature.
4. Press **Sign**. The signed copy, with its certificate of completion, stays on the same page.

## Cars now

**Field work** > **Cars now** shows which cars are out, coming back today and tomorrow, going out in the next 72 hours and free, with no money. The renter''s phone shows only on your own jobs.


## Call and text the renter

**Call** on a job opens the Quo app with the renter''s number, so the call comes from the CarmaCars number; **Text** opens a small window that sends from the CarmaCars number and keeps the text with the booking. Without the Quo app, use **Use this phone** in the window that opens.

**Search:** the **Search** button at the top finds your jobs by booking number, plate or car.', 'My jobs', 'Your job list, a job card, maps and car moves.',
  'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Cars now**, **Map** (where the cars of your jobs are now, with their trips and alerts), **My hours** and **Me** (My sales, Referrals, Profile and Academy, as a row on top). **Add a rental** and **Report a problem** are buttons at the top of My jobs. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. The next job is the big card at the top: its time and how long until it, the car and its plate, the place with **Open in maps** and a button to call the renter, and what to put in the car. The rest of the day follows in time order.
4. A handover or a return has its own button: **Check in (pickup)** or **Check out (return)**. One tap acknowledges and starts the job and opens its photo checklist. Other jobs: press **Open the job**.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-b31e25fb.jpg "phone; size: 390 1530; pins: 1 91.0 15.0, 2 89.7 53.3, 3 89.7 61.4, 4 89.7 88.2")

> Tip: Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions, and a button to call the renter.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-c6780f54.jpg "phone; size: 390 1530; pins: 1 94.9 34.0, 2 94.9 44.1, 3 94.9 52.6, 4 94.9 95.8")

## Check the renter''s licence

The renter''s licence photos and selfie are checked before the handover. You can check them yourself, for a booking on one of your own jobs today or in the next 7 days. Everything you do is recorded with your name and "field staff".

1. My jobs shows **Licences to check** when the licence front, back or selfie of a renter on one of your jobs waits for a decision. The same check is on the job itself, under **Check the licence**.
2. Press **Review the licence**. The images open with the name, date of birth and licence details on the booking.
3. Look at each image and the licence reader''s lines under each driver (Pass or Flag: valid to the return, class, age, name and date of birth, the Ontario number, front and back): no sign of alteration, and the selfie matches the licence photo. A photo you take that is blurry or cut off says so at once: take it again.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told why and sends a new one.
5. Then press **Approve all**: everything still waiting is approved at once.

> Tip: The renter''s proof of coverage stays with the office. Meeting the renter at the handover? You can still check the original licence in person from the ready check (see A handover).

## Move a car

1. Under Vehicle moves, press **Start a move**. Choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km), then press **Start the move now**.
3. When you arrive, press **End the move**, fill in Now at and the odometer, then press **End the move now**.

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Sign in a few steps: press **Send the code** and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the key terms (confidentiality, the rules on money, keys and cars, ending the agreement), tick the two consents and draw your signature.
4. Press **Sign**. The signed copy, with its certificate of completion, stays on the same page.

## Cars now

**Field work** > **Cars now** shows which cars are out, coming back today and tomorrow, going out in the next 72 hours and free, with no money. The renter''s phone shows only on your own jobs.


## Call and text the renter

**Call** on a job opens the Quo app with the renter''s number, so the call comes from the CarmaCars number; **Text** opens a small window that sends from the CarmaCars number and keeps the text with the booking. Without the Quo app, use **Use this phone** in the window that opens.

**Search:** the **Search** button at the top finds your jobs by booking number, plate or car.

## Your shifts

Jobs are given only to people on a shift that day. On **My jobs**, **Your shifts** lists the shifts you hold and the open ones: press **Take this shift** on the days you can work, or **Give this shift up** if you cannot. You can take shifts once you have passed the academy. If a day has no shifts, work due that day is done the day before or the day after; the job shows the planned day and the real time.',
  '<p class="gd-p">Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.</p><section class="gd-task" id="my-jobs-your-job-list" data-gd-task><h2 class="gd-h2">Your job list</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The menu: <b class="gd-ui">My jobs</b>, <b class="gd-ui">Cars now</b>, <b class="gd-ui">Map</b> (where the cars of your jobs are now, with their trips and alerts), <b class="gd-ui">My hours</b> and <b class="gd-ui">Me</b> (My sales, Referrals, Profile and Academy, as a row on top). <b class="gd-ui">Add a rental</b> and <b class="gd-ui">Report a problem</b> are buttons at the top of My jobs. <b class="gd-ui">Sign out</b> is top right.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between <b class="gd-ui">Today</b> and <b class="gd-ui">Tomorrow</b>. Jobs are in time order.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The next job is the big card at the top: its time and how long until it, the car and its plate, the place with <b class="gd-ui">Open in maps</b> and a button to call the renter, and what to put in the car. The rest of the day follows in time order.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A handover or a return has its own button: <b class="gd-ui">Check in (pickup)</b> or <b class="gd-ui">Check out (return)</b>. One tap acknowledges and starts the job and opens its photo checklist. Other jobs: press <b class="gd-ui">Open the job</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Moving a car that has no job? Use Vehicle moves (see below).</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/1530"><img src="/guides/img/field-01-today-phone-b31e25fb.jpg" alt="" loading="lazy" decoding="async" width="390" height="1530"><span class="gd-pin" style="left:91%;top:15%" aria-hidden="true">1</span><span class="gd-pin" style="left:89.7%;top:53.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.7%;top:61.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:89.7%;top:88.2%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.</div></aside></section><section class="gd-task" id="my-jobs-open-a-job" data-gd-task><h2 class="gd-h2">Open a job</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card shows the kind, the time, the car, the plate and colour.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The address, with <b class="gd-ui">Open in maps</b> for directions, and a button to call the renter.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For a handover: the booking, the renter&#39;s name and phone, the Card on File and the licence on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Acknowledge</b> so the office knows you have it. Then press <b class="gd-ui">Start</b> when you are with the car.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/1530"><img src="/guides/img/field-02-job-phone-c6780f54.jpg" alt="" loading="lazy" decoding="async" width="390" height="1530"><span class="gd-pin" style="left:94.9%;top:34%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.9%;top:44.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:94.9%;top:52.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.9%;top:95.8%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="my-jobs-check-the-renter-s-licence" data-gd-task><h2 class="gd-h2">Check the renter&#39;s licence</h2><p class="gd-p">The renter&#39;s licence photos and selfie are checked before the handover. You can check them yourself, for a booking on one of your own jobs today or in the next 7 days. Everything you do is recorded with your name and &quot;field staff&quot;.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">My jobs shows <b class="gd-ui">Licences to check</b> when the licence front, back or selfie of a renter on one of your jobs waits for a decision. The same check is on the job itself, under <b class="gd-ui">Check the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Review the licence</b>. The images open with the name, date of birth and licence details on the booking.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Look at each image and the licence reader&#39;s lines under each driver (Pass or Flag: valid to the return, class, age, name and date of birth, the Ontario number, front and back): no sign of alteration, and the selfie matches the licence photo. A photo you take that is blurry or cut off says so at once: take it again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">One is wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>. The renter is told why and sends a new one.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: everything still waiting is approved at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter&#39;s proof of coverage stays with the office. Meeting the renter at the handover? You can still check the original licence in person from the ready check (see A handover).</div></aside></section><section class="gd-task" id="my-jobs-move-a-car" data-gd-task><h2 class="gd-h2">Move a car</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Vehicle moves, press <b class="gd-ui">Start a move</b>. Choose the Car and Why (for example Reposition).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in From and the Odometer (km), then press <b class="gd-ui">Start the move now</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">When you arrive, press <b class="gd-ui">End the move</b>, fill in Now at and the odometer, then press <b class="gd-ui">End the move now</b>.</div></li></ol></div></section><section class="gd-task" id="my-jobs-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">My jobs shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, wage and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sign in a few steps: press <b class="gd-ui">Send the code</b> and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the key terms (confidentiality, the rules on money, keys and cars, ending the agreement), tick the two consents and draw your signature.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. The signed copy, with its certificate of completion, stays on the same page.</div></li></ol></div></section><section class="gd-task" id="my-jobs-cars-now" data-gd-task><h2 class="gd-h2">Cars now</h2><p class="gd-p"><b class="gd-ui">Field work</b> &gt; <b class="gd-ui">Cars now</b> shows which cars are out, coming back today and tomorrow, going out in the next 72 hours and free, with no money. The renter&#39;s phone shows only on your own jobs.</p></section><section class="gd-task" id="my-jobs-call-and-text-the-renter" data-gd-task><h2 class="gd-h2">Call and text the renter</h2><p class="gd-p"><b class="gd-ui">Call</b> on a job opens the Quo app with the renter&#39;s number, so the call comes from the CarmaCars number; <b class="gd-ui">Text</b> opens a small window that sends from the CarmaCars number and keeps the text with the booking. Without the Quo app, use <b class="gd-ui">Use this phone</b> in the window that opens.</p><p class="gd-p"><b class="gd-ui">Search:</b> the <b class="gd-ui">Search</b> button at the top finds your jobs by booking number, plate or car.</p></section><section class="gd-task" id="my-jobs-your-shifts" data-gd-task><h2 class="gd-h2">Your shifts</h2><p class="gd-p">Jobs are given only to people on a shift that day. On <b class="gd-ui">My jobs</b>, <b class="gd-ui">Your shifts</b> lists the shifts you hold and the open ones: press <b class="gd-ui">Take this shift</b> on the days you can work, or <b class="gd-ui">Give this shift up</b> if you cannot. You can take shifts once you have passed the academy. If a day has no shifts, work due that day is done the day before or the day after; the job shows the planned day and the real time.</p></section>');
-- GUIDES 0880 END
