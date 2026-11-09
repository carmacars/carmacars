-- 1051_r35s2_shift_jobs.sql
-- Release 35, part S2 (docs/changes/2026-11-08-r35-showroom-v2-shift-jobs.md): field jobs belong to shifts, not to people. The
-- owner: "field auto assign to shifts, not to people, right? and then when a person claims a shift, they can see the tasks, and
-- fleet can assign tasks to field". No applied migration is edited.
--   1. field_jobs.shift_slot_id: the shift a job is worked on. The automatic assignment puts each job on a shift: the published
--      shift covering its time, else that day's shift nearest its time. The day rules of 0880 stay, with a day "having shifts"
--      when a shift is published for it (taken or not): work due on a day without one moves to the nearest earlier day with one
--      when known in advance, else to the next day with one. The job keeps its real time.
--   2. A job on a shift goes to the people on it: one person has them all; several share them least busy first (and either can
--      take one of the other's with "Take it"). A shift nobody holds keeps its jobs (field staff see "3 pickups, 1 return" on it
--      when they look for shifts to claim); the person who claims it gets them on Today and My shifts. A shift given up, given
--      away or swapped takes its jobs along to whoever holds it next. A shift cancelled sends its jobs to another shift.
--   3. Fleet and Admin: a job to a person (on a day with published shifts a field person must hold one: the job goes on that
--      shift; an Admin needs none), or to a shift (field_job_shift), and between shifts. "Unassign" leaves a job on no shift and with nobody.
--   4. A shift with jobs starting within 24 hours that nobody holds alerts Fleet and Admin once (a To do and an alert).
--   5. Existing work: the unassigned jobs of the future and the automatic ones are put on shifts (a person given one is told as
--      usual; one it is taken off is not told).
-- SCHEMA_MARKER 1053 (with 1052 and 1053).
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

-- ================================================================ columns
alter table field_jobs
  add column if not exists shift_slot_id uuid references field_shift_slots (id) on delete set null,
  add column if not exists shift_pinned boolean not null default false;
comment on column field_jobs.shift_slot_id is 'The shift the job is worked on (1051): its people do it (several share them least busy first); nobody on it, the job waits on the shift for whoever claims it.';
comment on column field_jobs.shift_pinned is 'Fleet or an Admin chose the shift or the person (1051): a new shift does not take the job away.';
create index if not exists field_jobs_shift_slot on field_jobs (shift_slot_id) where shift_slot_id is not null;
alter table field_shift_slots add column if not exists jobs_alerted_at timestamptz;
comment on column field_shift_slots.jobs_alerted_at is 'When Fleet and Admin were told this shift has jobs within 24 hours and nobody on it (1051): once.';

-- ================================================================ 1. the shift of a job
-- a day has shifts when a shift is published for it (taken or not)
create or replace function app.field_work_day(p_at timestamptz, p_advance boolean) returns date
language sql stable security definer set search_path = public, app as $$
  with d as (select app.local_date(p_at) as day),
       days as (select distinct app.local_date(s.starts_at) as day from field_shift_slots s where s.cancelled_at is null)
  select case
    when exists (select 1 from days, d where days.day = d.day) then (select day from d)
    when p_advance and exists (select 1 from days, d where days.day < d.day and days.day >= app.today()) then (select max(days.day) from days, d where days.day < d.day and days.day >= app.today())
    else (select min(days.day) from days, d where days.day > d.day and days.day <= d.day + 14) end
$$;

-- the shift work due at p_at goes on: on its work day, the one covering its time (moved to that day), else the nearest
create function app.fx_slot_for(p_at timestamptz, p_advance boolean) returns uuid
language sql stable security definer set search_path = public, app as $$
  with w as (select app.field_work_day(p_at, p_advance) as day),
       t as (select w.day, ((w.day + (p_at at time zone 'America/Toronto')::time) at time zone 'America/Toronto') as at from w)
  select s.id from t join field_shift_slots s on s.cancelled_at is null and app.local_date(s.starts_at) = t.day
   where t.day is not null and s.ends_at > now()
   order by (s.starts_at <= t.at and s.ends_at > t.at) desc,
            least(abs(extract(epoch from (s.starts_at - t.at))), abs(extract(epoch from (s.ends_at - t.at)))), s.starts_at, s.id
   limit 1
$$;

-- the people on a shift who may be given work (active field staff past the academy)
create function app.fx_slot_people(p_slot uuid) returns setof uuid
language sql stable security definer set search_path = public, app as $$
  select x.staff_id from field_shift_plans x
   where x.slot_id = p_slot and x.cancelled_at is null and app.is_field_person(x.staff_id) and not app.academy_locked(x.staff_id)
$$;

-- the least busy person on a shift (the jobs of that shift; then the jobs of those days), or nobody
create function app.fx_slot_pick(p_slot uuid, p_job uuid default null) returns uuid
language sql stable security definer set search_path = public, app as $$
  select u.id from app.fx_slot_people(p_slot) p(id) join users u on u.id = p.id
   order by (select count(*) from field_jobs j where j.shift_slot_id = p_slot and j.assigned_to = u.id and j.status <> 'cancelled' and j.id is distinct from p_job),
            (select count(*) from field_jobs j where j.assigned_to = u.id and j.status not in ('cancelled', 'done') and j.id is distinct from p_job
               and j.scheduled_at between now() - interval '1 day' and now() + interval '7 days'),
            u.full_name, u.id
   limit 1
$$;

-- the person's shift for a job at p_at on day p_day: the one covering it, else their first that day
create function app.fx_person_slot(p_staff uuid, p_at timestamptz, p_day date) returns uuid
language sql stable security definer set search_path = public, app as $$
  select x.slot_id from field_shift_plans x
   where x.staff_id = p_staff and x.cancelled_at is null and app.local_date(x.starts_at) = coalesce(p_day, app.local_date(p_at))
   order by (x.starts_at <= p_at and x.ends_at > p_at) desc, x.starts_at limit 1
$$;

-- the automatic assignee is now the least busy person on the job's shift (0880's callers keep working)
create or replace function app.field_auto_assignee(p_at timestamptz) returns uuid
language sql stable security definer set search_path = public, app as $$
  select case when (app.settings()).field_jobs_auto_assign = 'least_busy' then
    app.fx_slot_pick(app.fx_slot_for(p_at, app.local_date(p_at) > app.today())) end
$$;

-- before a job is written: its shift and its person
create function app.field_jobs_shift() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_auto boolean := (app.settings()).field_jobs_auto_assign = 'least_busy';
  v_slot field_shift_slots;
begin
  if new.status in ('done', 'cancelled', 'in_progress') then return new; end if;
  -- taken off by Fleet ("Unassign"): no shift and nobody
  if coalesce(current_setting('app.fx_no_slot', true), '') = 'on' then return new; end if;
  -- its shift deleted (the foreign key sets it empty): left with no shift
  if tg_op = 'UPDATE' and new.shift_slot_id is null and old.shift_slot_id is not null
     and not exists (select 1 from field_shift_slots x where x.id = old.shift_slot_id) then return new; end if;
  if tg_op = 'INSERT' or new.assigned_to is distinct from old.assigned_to then
    if new.assigned_to is not null and app.is_field_person(new.assigned_to) then
      -- a person: their shift (kept when they are on the one given)
      if new.shift_slot_id is null or not exists (select 1 from field_shift_plans x where x.slot_id = new.shift_slot_id and x.staff_id = new.assigned_to and x.cancelled_at is null) then
        new.shift_slot_id := coalesce(app.fx_person_slot(new.assigned_to, new.scheduled_at, new.work_day), app.fx_person_slot(new.assigned_to, new.scheduled_at, null), new.shift_slot_id);
      end if;
    elsif new.assigned_to is not null then
      new.shift_slot_id := null;                                  -- an Admin: no shift
    end if;
  end if;
  if new.assigned_to is null and new.shift_slot_id is null and v_auto and new.scheduled_at > now() - interval '1 day'
     and (tg_op = 'INSERT' or not new.shift_pinned) then
    new.shift_slot_id := app.fx_slot_for(new.scheduled_at, app.local_date(new.scheduled_at) > app.today());
  elsif tg_op = 'UPDATE' and new.scheduled_at is distinct from old.scheduled_at and new.shift_slot_id is not null and v_auto
        and (not new.shift_pinned or app.local_date(new.scheduled_at) <> app.local_date(old.scheduled_at)) then
    -- moved: the shift of its new time (the person follows below)
    new.shift_slot_id := coalesce(app.fx_slot_for(new.scheduled_at, app.local_date(new.scheduled_at) > app.today()), new.shift_slot_id);
  end if;
  if new.shift_slot_id is not null then
    select * into v_slot from field_shift_slots where id = new.shift_slot_id;
    if new.assigned_to is null or not exists (select 1 from field_shift_plans x where x.slot_id = new.shift_slot_id and x.staff_id = new.assigned_to and x.cancelled_at is null) then
      if new.assigned_to is null or app.is_field_person(new.assigned_to) then
        new.assigned_to := app.fx_slot_pick(new.shift_slot_id, new.id);
        if tg_op = 'UPDATE' and new.assigned_to is distinct from old.assigned_to then new.acknowledged_at := null; new.status := 'scheduled'; end if;
      end if;
    end if;
    new.work_day := case when app.local_date(v_slot.starts_at) <> app.local_date(new.scheduled_at) then app.local_date(v_slot.starts_at) end;
  end if;
  return new;
end $$;
drop trigger if exists field_jobs_shift on field_jobs;
create trigger field_jobs_shift before insert or update of assigned_to, scheduled_at, shift_slot_id, status on field_jobs
  for each row execute function app.field_jobs_shift();

-- 0880's work day of an automatic job: a job on a shift has its day from the shift (above)
create or replace function app.field_jobs_work_day() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date;
begin
  if new.shift_slot_id is not null then return new; end if;
  if new.auto_created and new.assigned_to is not null and new.status not in ('done', 'cancelled')
     and (tg_op = 'INSERT' or old.assigned_to is null or new.scheduled_at is distinct from old.scheduled_at) then
    v_day := app.field_work_day(new.scheduled_at, app.local_date(new.scheduled_at) > app.today());
    new.work_day := case when v_day is distinct from app.local_date(new.scheduled_at) then v_day end;
  end if;
  return new;
end $$;

-- ================================================================ 2. the people of a shift change: its jobs follow
create function app.fx_slot_rebalance(p_slot uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  j record;
  n integer := 0;
  v_hi uuid;
  v_lo uuid;
  v_hi_n integer;
  v_lo_n integer;
  v_move uuid;
  i integer;
begin
  if p_slot is null then return 0; end if;
  -- jobs of people no longer on it (or of nobody): to the least busy on it, or to nobody
  for j in select x.id from field_jobs x where x.shift_slot_id = p_slot and x.status in ('scheduled', 'acknowledged')
              and (x.assigned_to is null or (x.assigned_to not in (select app.fx_slot_people(p_slot)) and app.is_field_person(x.assigned_to)))
            order by x.scheduled_at, x.id loop
    update field_jobs set assigned_to = app.fx_slot_pick(p_slot, j.id), acknowledged_at = null, status = 'scheduled' where id = j.id;
    n := n + 1;
  end loop;
  -- several people: shared least busy first (a job nobody acknowledged and nobody chose by hand moves)
  for i in 1 .. 40 loop
    select p.id, (select count(*) from field_jobs x where x.shift_slot_id = p_slot and x.assigned_to = p.id and x.status <> 'cancelled') into v_hi, v_hi_n
      from app.fx_slot_people(p_slot) p(id) order by 2 desc, p.id limit 1;
    select p.id, (select count(*) from field_jobs x where x.shift_slot_id = p_slot and x.assigned_to = p.id and x.status <> 'cancelled') into v_lo, v_lo_n
      from app.fx_slot_people(p_slot) p(id) order by 2, p.id limit 1;
    exit when v_hi is null or v_hi = v_lo or v_hi_n - v_lo_n < 2;
    select x.id into v_move from field_jobs x where x.shift_slot_id = p_slot and x.assigned_to = v_hi and x.status = 'scheduled' and x.acknowledged_at is null and not x.shift_pinned
     order by x.scheduled_at desc, x.id limit 1;
    exit when v_move is null;
    update field_jobs set assigned_to = v_lo where id = v_move;
    n := n + 1;
  end loop;
  return n;
end $$;

create function app.fx_plan_jobs_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'INSERT' or new.cancelled_at is distinct from old.cancelled_at then perform app.fx_slot_rebalance(new.slot_id); end if;
  return null;
end $$;
drop trigger if exists field_shift_plans_jobs on field_shift_plans;
create trigger field_shift_plans_jobs after insert or update of cancelled_at on field_shift_plans for each row execute function app.fx_plan_jobs_after();

-- a new shift takes the waiting work of its day (nobody on it, not chosen by hand); a cancelled one sends its jobs to another
create function app.fx_slot_jobs_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'INSERT' and new.cancelled_at is null then
    -- work of that day planned on another day (no shift was there then): back to its own day
    update field_jobs j set shift_slot_id = null, assigned_to = null
     where j.status = 'scheduled' and j.acknowledged_at is null and not j.shift_pinned and j.shift_slot_id is not null and j.work_day is not null
       and app.local_date(j.scheduled_at) = app.local_date(new.starts_at) and j.scheduled_at > now();
    -- work with no shift and nobody (no shift was near it): on a shift now
    update field_jobs j set shift_slot_id = null
     where j.status = 'scheduled' and j.assigned_to is null and j.shift_slot_id is null and not j.shift_pinned and j.scheduled_at > now() - interval '1 day'
       and app.local_date(j.scheduled_at) between app.local_date(new.starts_at) - 14 and app.local_date(new.starts_at) + 14;
  elsif tg_op = 'UPDATE' and new.cancelled_at is not null and old.cancelled_at is null then
    update field_jobs j set shift_slot_id = null, assigned_to = null, shift_pinned = false
     where j.shift_slot_id = new.id and j.status in ('scheduled', 'acknowledged');
  end if;
  return null;
end $$;
drop trigger if exists field_shift_slots_jobs on field_shift_slots;
create trigger field_shift_slots_jobs after insert or update of cancelled_at on field_shift_slots for each row execute function app.fx_slot_jobs_after();

-- ================================================================ 3. Fleet and Admin: a person or a shift
create or replace function app.assign_field_job(p_job uuid, p_assignee uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
  v_slot uuid;
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
  if j.assigned_to is not distinct from p_assignee and p_assignee is not null then
    update field_jobs set shift_pinned = true where id = p_job;
    return;
  end if;
  if p_assignee is not null and app.academy_locked(p_assignee) then
    raise exception '% has not passed the academy yet', coalesce((select u.full_name from users u where u.id = p_assignee), 'This person') using errcode = '23514';
  end if;
  if p_assignee is null then
    -- taken off: on no shift, with nobody (a later change of its time puts it on a shift again)
    perform set_config('app.fx_no_slot', 'on', true);
    update field_jobs set assigned_to = null, shift_slot_id = null, shift_pinned = true, dispatched_by = p_by, status = 'scheduled', acknowledged_at = null where id = p_job;
    perform set_config('app.fx_no_slot', 'off', true);
    return;
  end if;
  if app.is_field_person(p_assignee) then
    v_slot := coalesce(app.fx_person_slot(p_assignee, j.scheduled_at, app.fx_job_day(j)), app.fx_person_slot(p_assignee, j.scheduled_at, null));
    -- a day with published shifts: the person must hold one of them (a day with none: as before 1051, no shift needed)
    if v_slot is null and exists (select 1 from field_shift_slots x where x.cancelled_at is null and app.local_date(x.starts_at) = app.fx_job_day(j)) then
      raise exception '% is not on a shift that day: put them on one first, or give the job to a shift', coalesce((select u.full_name from users u where u.id = p_assignee), 'This person')
        using errcode = '23514';
    end if;
  end if;
  update field_jobs
     set assigned_to = p_assignee, shift_slot_id = v_slot, shift_pinned = true, dispatched_by = p_by, status = 'scheduled', acknowledged_at = null
   where id = p_job;
end $$;

-- p: id (the job), slot (the shift)
create function app.field_job_to_shift(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
  s field_shift_slots;
begin
  if not app.user_runs_fleet(p_by) then raise exception 'Only Fleet or an Admin moves a field job' using errcode = '42501'; end if;
  select * into j from field_jobs where id = nullif(p ->> 'id', '')::uuid for update;
  if j.id is null then raise exception 'Field job not found' using errcode = 'P0002'; end if;
  if j.status not in ('scheduled', 'acknowledged') then raise exception 'This job is % and stays where it is', replace(j.status, '_', ' ') using errcode = '23514'; end if;
  select * into s from field_shift_slots where id = nullif(p ->> 'slot', '')::uuid;
  if s.id is null or s.cancelled_at is not null then raise exception 'That shift is not there any more' using errcode = 'P0002'; end if;
  if s.ends_at <= now() then raise exception 'That shift is already over' using errcode = '23514'; end if;
  if j.shift_slot_id = s.id then return jsonb_build_object('id', j.id, 'slot', s.id, 'assigned_to', j.assigned_to); end if;
  update field_jobs set shift_slot_id = s.id, assigned_to = null, shift_pinned = true, dispatched_by = p_by, status = 'scheduled', acknowledged_at = null where id = j.id;
  return jsonb_build_object('id', j.id, 'slot', s.id, 'assigned_to', (select assigned_to from field_jobs where id = j.id));
end $$;

-- a person on the shift takes a job of the other person on it (p: job)
create function app.fx_job_take(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
begin
  select * into j from field_jobs where id = nullif(p ->> 'job', '')::uuid for update;
  if j.id is null then raise exception 'Field job not found' using errcode = 'P0002'; end if;
  if j.assigned_to = p_user then return jsonb_build_object('id', j.id); end if;
  if j.shift_slot_id is null or p_user not in (select app.fx_slot_people(j.shift_slot_id)) then
    raise exception 'Only someone on this job''s shift takes it' using errcode = '42501';
  end if;
  if j.status not in ('scheduled', 'acknowledged') then raise exception 'This job has started' using errcode = '23514'; end if;
  update field_jobs set assigned_to = p_user, status = 'scheduled', acknowledged_at = null where id = j.id;
  return jsonb_build_object('id', j.id);
end $$;

-- ================================================================ what each person sees
-- "3 pickups, 1 return, 2 cleans": the jobs of a shift by kind
create function app.fx_slot_jobs(p_slot uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'pickups', count(*) filter (where j.kind in ('handover', 'delivery')),
    'returns', count(*) filter (where j.kind in ('return_check_in', 'pickup_from_renter')),
    'cleans', count(*) filter (where j.kind = 'detail'),
    'other', count(*) filter (where j.kind not in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter', 'detail')),
    'total', count(*))
    from field_jobs j where j.shift_slot_id = p_slot and j.status not in ('cancelled', 'done')
$$;

alter function app.field_my_shifts(uuid) rename to field_my_shifts_pre1051;
create function app.field_my_shifts(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select app.field_my_shifts_pre1051(p_user) as x)
  select s.x || jsonb_build_object(
    'open', coalesce((select jsonb_agg(o || jsonb_build_object('jobs', app.fx_slot_jobs((o ->> 'id')::uuid))) from jsonb_array_elements(s.x -> 'open') o), '[]'::jsonb),
    'offers', coalesce((select jsonb_agg(o || jsonb_build_object('jobs', app.fx_slot_jobs((o ->> 'slot_id')::uuid))) from jsonb_array_elements(s.x -> 'offers') o), '[]'::jsonb),
    'mine', coalesce((select jsonb_agg(m || jsonb_build_object('jobs', app.fx_slot_jobs(x.slot_id), 'slot_id', x.slot_id,
                        'people', (select count(*) from field_shift_plans y where y.slot_id = x.slot_id and y.cancelled_at is null)))
                      from jsonb_array_elements(s.x -> 'mine') m join field_shift_plans x on x.id = (m ->> 'id')::uuid), '[]'::jsonb))
    from s
$$;
select pg_temp.copy_grants('app.field_my_shifts(uuid)'::regprocedure, 'app.field_my_shifts_pre1051(uuid)'::regprocedure);

-- Today: the jobs on the person's shifts that day held by someone else on it (with Take it)
alter function app.fx_today(uuid, date) rename to fx_today_pre1051;
create function app.fx_today(p_user uuid, p_day date default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.fx_today_pre1051(p_user, p_day) || jsonb_build_object('mates', coalesce((
    select jsonb_agg(jsonb_build_object('id', j.id, 'kind', j.kind, 'leg', app.fx_leg(j.kind), 'at', j.scheduled_at, 'status', j.status, 'place', j.place,
             'vehicle', app.vehicle_name(j.vehicle_id), 'booking', (select b.booking_number from bookings b where b.id = j.booking_id),
             'who', (select split_part(u.full_name, ' ', 1) from users u where u.id = j.assigned_to)) order by j.scheduled_at, j.id)
      from field_jobs j
     where j.shift_slot_id in (select x.slot_id from field_shift_plans x where x.staff_id = p_user and x.cancelled_at is null
                                  and app.local_date(x.starts_at) = coalesce(p_day, app.today()))
       and j.assigned_to is distinct from p_user and j.status not in ('cancelled', 'done')), '[]'::jsonb))
$$;
select pg_temp.copy_grants('app.fx_today(uuid, date)'::regprocedure, 'app.fx_today_pre1051(uuid, date)'::regprocedure);

-- the board: each shift's jobs, who is on it, and the shift of each job
alter function app.field_board(uuid) rename to field_board_pre1051;
create function app.field_board(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with b as (select app.field_board_pre1051(p_user) as x)
  select b.x || jsonb_build_object('slots', coalesce((select jsonb_agg(s || jsonb_build_object('jobs', app.fx_slot_jobs((s ->> 'id')::uuid))) from jsonb_array_elements(b.x -> 'slots') s), '[]'::jsonb))
    from b
$$;
select pg_temp.copy_grants('app.field_board(uuid)'::regprocedure, 'app.field_board_pre1051(uuid)'::regprocedure);

-- ================================================================ 4. a shift with jobs and nobody on it, within 24 hours
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('field_shift_no_one', 'fleet', 'A field shift with jobs has nobody', 'high', 'none', null, 'A shift starting within 24 hours has jobs and nobody on it. Put someone on it, or move its jobs on the field jobs board.')
on conflict (task_type) do nothing;
insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('field_shift_no_one', 'A field shift with jobs has nobody', 'Field work', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, false, 'A shift within 24 hours has jobs and nobody claimed it (1051).', 158)
on conflict (rule) do nothing;

create function app.job_field_shift_jobs(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s field_shift_slots;
  v jsonb;
  n integer := 0;
  v_words text;
begin
  for s in select * from field_shift_slots x where x.cancelled_at is null and x.jobs_alerted_at is null
             and x.starts_at > p_now and x.starts_at <= p_now + interval '24 hours'
             and not exists (select 1 from field_shift_plans y where y.slot_id = x.id and y.cancelled_at is null)
             and exists (select 1 from field_jobs j where j.shift_slot_id = x.id and j.status in ('scheduled', 'acknowledged')) loop
    v := app.fx_slot_jobs(s.id);
    v_words := app.fx_shift_words(s.starts_at, s.ends_at);
    perform app.raise_task(p_type => 'field_shift_no_one', p_title => 'Nobody is on the field shift of ' || v_words,
      p_detail => format('%s job(s) on it: %s pickup(s), %s return(s), %s clean(s).', v ->> 'total', v ->> 'pickups', v ->> 'returns', v ->> 'cleans'),
      p_related_table => 'field_shift_slots', p_related_id => s.id, p_queue => 'fleet', p_dedupe => 'field_shift_no_one:' || s.id, p_due_at => s.starts_at, p_priority => 'high');
    perform app.staff_alert('field_shift_no_one', 'field_shift_slot', s.id, 'no_one', 'Nobody is on the shift of ' || v_words,
      format('%s job(s) wait on it. Put someone on it or move the jobs on the field jobs board.', v ->> 'total'),
      jsonb_build_object('path_admin', '/admin/field-jobs', 'path_staff', '/staff/fleet'));
    update field_shift_slots set jobs_alerted_at = p_now where id = s.id;
    n := n + 1;
  end loop;
  return format('%s shift(s) with jobs and nobody alerted', n);
end $$;
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-field-shift-jobs', '*/15 * * * *', 'select app.job_field_shift_jobs()');
  end if;
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1051;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_do' and p_name = 'field_job_shift' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.field_job_to_shift(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'field_do' and p_name = 'job_take' then
    perform app.door_begin(p_user, p_aal);
    if not app.is_field_person(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.fx_job_take(p_user, p);
  end if;
  return app.door_pre1051(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1051(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['fx_slot_for', 'fx_slot_people', 'fx_slot_pick', 'fx_person_slot', 'field_jobs_shift', 'fx_slot_rebalance',
              'fx_plan_jobs_after', 'fx_slot_jobs_after', 'field_job_to_shift', 'fx_job_take', 'fx_slot_jobs', 'job_field_shift_jobs', 'door_pre1051',
              'field_my_shifts_pre1051', 'fx_today_pre1051', 'field_board_pre1051'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 5. the work there is now goes on shifts (quietly)
select set_config('app.field_unassign_quiet', 'on', true);
-- an automatic job whose person holds a shift that day: on that shift
update field_jobs j set shift_slot_id = app.fx_person_slot(j.assigned_to, j.scheduled_at, coalesce(j.work_day, app.local_date(j.scheduled_at)))
 where j.status in ('scheduled', 'acknowledged') and j.scheduled_at > now() and j.assigned_to is not null and j.shift_slot_id is null
   and j.auto_created and j.dispatched_by is null
   and app.fx_person_slot(j.assigned_to, j.scheduled_at, coalesce(j.work_day, app.local_date(j.scheduled_at))) is not null;
-- an automatic job not yet acknowledged whose person holds no shift that day: to the job's shift
update field_jobs j set assigned_to = null
 where j.status = 'scheduled' and j.acknowledged_at is null and j.scheduled_at > now() and j.assigned_to is not null and j.shift_slot_id is null
   and j.auto_created and j.dispatched_by is null and app.is_field_person(j.assigned_to);
-- every job with nobody: on its shift
update field_jobs j set shift_slot_id = null
 where j.status = 'scheduled' and j.scheduled_at > now() and j.assigned_to is null and j.shift_slot_id is null;
select set_config('app.field_unassign_quiet', 'off', true);
