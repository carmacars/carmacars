-- 5173 (R50 hotfix 2, field routing; docs/changes/2026-11-27-r50-hotfix2-academy.md): shifts paused, the work still reaches
-- the people on shift. The owner (Nov 27): with shifts paused, "(a) work not done on a shift carries over to the next shift;
-- (b) a field staff member on shift sees every pickup and return that day and work up to the next shift (prep a car for
-- tomorrow or the day after); (c) days with pickups/returns and no shift are assigned to the shift before or after by timing,
-- even with slots paused." and "Pause shifts by migration (field_slots_auto false) keeping existing assigned shifts and routing
-- running."
-- Found in production (Nov 27, Admin connector): every open field job had nobody (assigned_to null) because Program settings
-- field_jobs_auto_assign was 'none', which switches off the routing of 1051 (app.field_jobs_shift puts a job on a shift only
-- when it is 'least_busy'). So the person on shift saw none of the day's pickups and returns.
--   1. Shifts paused: field_slots_auto false (no slot is published by itself any more, template or covering), and every open
--      slot still to come that nobody holds is cancelled (an open slot nobody claims would hold its jobs with nobody). Every
--      claimed shift stays, with its jobs. field_jobs_auto_assign 'least_busy' (the routing runs). Fleet and Admins can still
--      publish a slot by hand.
--   2. app.fx_route_slot(kind, at): the shift a job goes on, among the shifts that still end in the future. The day: the job's
--      own when it has a shift; else by timing, a pickup (handover, delivery) or any other prep the day before it with a shift
--      (else the next), a return (return_check_in, pickup_from_renter) the next day with a shift (else the one before). On that
--      day, the shift of the job's hour (the one covering it, else the nearest), as 1051 did. The automatic routing
--      (field_jobs_shift) uses it in place of fx_slot_for, which sent a return on a day without a shift to the day before.
--   3. app.field_route_run(now): every hour (job_field_shift_plan) and once now, each open job (scheduled or acknowledged) that
--      is on no shift and with nobody, or on a shift that ended or was cancelled (carried over: work not done goes to the next
--      shift), goes on the shift of 2 and to its person. A job on a live shift, a job given to a person by hand without a
--      shift and a started job are not moved.
--   4. Today (app.fx_today) for a person on shift: mates lists every pickup and return of the day that is not theirs (any
--      shift, or none), with on_my_shift for Take it; ahead lists the pickups and returns after the day up to the next held
--      shift's day (the day after when none is held), so cars are prepped. Take it (fx_job_take) also takes a job of the day
--      from another shift for a person who holds a shift that day.
-- No applied migration is edited: field_jobs_shift, job_field_shift_plan and fx_job_take are patched in place,
-- fx_today is wrapped.
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5173: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the switches
-- a database without its settings row (a fresh one) gets it, so the switches hold there too (0014's row, column defaults)
insert into program_settings (effective_from, field_slots_auto, field_jobs_auto_assign)
select date '2026-01-01', false, 'least_busy' where not exists (select 1 from program_settings);
update program_settings set field_slots_auto = false, field_jobs_auto_assign = 'least_busy'
 where field_slots_auto is distinct from false or field_jobs_auto_assign is distinct from 'least_busy';
-- the open slots still to come that nobody holds (their jobs are routed again by fx_slot_jobs_after, then field_route_run)
-- A cancel names who cancelled (field_shift_slots_check2): the slot's creator, else the first Admin. A database with no
-- Admin yet (a fresh build) deletes the slot instead when nothing but its jobs points at it (the jobs lose the slot).
do $$
declare n integer; d integer; v_admin uuid := (select r.user_id from user_roles r where r.role = 'admin' order by r.granted_at, r.user_id limit 1);
begin
  update field_shift_slots s set cancelled_at = now(), cancelled_by = coalesce(s.created_by, v_admin)
   where s.cancelled_at is null and s.starts_at > now() and coalesce(s.created_by, v_admin) is not null
     and not exists (select 1 from field_shift_plans x where x.slot_id = s.id and x.cancelled_at is null);
  get diagnostics n = row_count;
  delete from field_shift_slots s
   where s.cancelled_at is null and s.starts_at > now() and coalesce(s.created_by, v_admin) is null
     and not exists (select 1 from field_shift_plans x where x.slot_id = s.id)
     and not exists (select 1 from field_shift_offers o where o.slot_id = s.id);
  get diagnostics d = row_count;
  raise notice '5173: % open slot(s) nobody held cancelled, % deleted (shifts paused)', n, d;
end $$;

-- ================================================================ 2. where a job goes
create function app.fx_slot_live(p_slot uuid, p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from field_shift_slots s where s.id = p_slot and s.cancelled_at is null and s.ends_at > p_now)
$$;

create function app.fx_route_slot_among(p_kind text, p_at timestamptz, p_now timestamptz, p_worked boolean) returns uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  with s as (select x.id, x.starts_at, x.ends_at, app.local_date(x.starts_at) as day from field_shift_slots x
              where x.cancelled_at is null and x.ends_at > p_now
                and x.starts_at < p_at + interval '14 days' and x.ends_at > p_at - interval '14 days'
                and (not p_worked or exists (select 1 from app.fx_slot_people(x.id)))),
       j as (select app.local_date(p_at) as day, p_kind in ('return_check_in', 'pickup_from_renter') as after_leg),
       -- the day: its own; else a return the next day with a shift (else the one before), a pickup or prep the day before
       -- with a shift (else the next)
       d as (select coalesce((select j.day from j where exists (select 1 from s where s.day = j.day)),
                             case when (select after_leg from j)
                                  then coalesce((select min(s.day) from s, j where s.day > j.day), (select max(s.day) from s, j where s.day < j.day))
                                  else coalesce((select max(s.day) from s, j where s.day < j.day), (select min(s.day) from s, j where s.day > j.day)) end) as day),
       -- on that day, the shift of the job's hour: the one covering it, else the nearest
       t as (select ((d.day + (p_at at time zone 'America/Toronto')::time) at time zone 'America/Toronto') as at, d.day from d)
  select s.id from s, t where s.day = t.day
   order by (s.starts_at <= t.at and s.ends_at > t.at) desc,
            least(abs(extract(epoch from (s.starts_at - t.at))), abs(extract(epoch from (s.ends_at - t.at)))), s.starts_at, s.id
   limit 1
$$;
-- the shifts somebody works first (fx_slot_people: on the plan, field, not academy-locked); else an open shift (1051: its jobs
-- come with it when someone claims it); null when there is no live shift near
create function app.fx_route_slot(p_kind text, p_at timestamptz, p_now timestamptz default now()) returns uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(app.fx_route_slot_among(p_kind, p_at, p_now, true), app.fx_route_slot_among(p_kind, p_at, p_now, false))
$$;
comment on function app.fx_route_slot(text, timestamptz, timestamptz) is 'The shift a field job goes on (5173): a shift someone works first (fx_slot_people: held, field, not academy-locked), else an open shift; null when none is near. A live shift on its own day first, else by timing (a pickup the day before with a shift, a return the day after), the shift of its hour on that day.';

select pg_temp.patch_fn('app.field_jobs_shift()'::regprocedure,
  'app.fx_slot_for(new.scheduled_at, app.local_date(new.scheduled_at) > app.today())',
  'app.fx_route_slot(new.kind, new.scheduled_at)');

-- ================================================================ 3. carry over and route again
create function app.field_route_run(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  j record;
  v_slot uuid;
  n integer := 0;
  v_none integer := 0;
begin
  if (app.settings()).field_jobs_auto_assign <> 'least_busy' then return 'field routing off (field_jobs_auto_assign none)'; end if;
  -- open jobs with nobody: on no shift, on an ended or cancelled shift, or on a live shift nobody works that Fleet did not choose
  -- by hand (review: never left there)
  for j in select f.id, f.kind, f.scheduled_at, f.shift_slot_id from field_jobs f
            where f.status in ('scheduled', 'acknowledged')
              and f.scheduled_at > p_now - interval '7 days'
              and (f.booking_id is null or exists (select 1 from bookings b where b.id = f.booking_id and b.status in ('confirmed', 'on_rent', 'returned')))
              and ((f.shift_slot_id is null and f.assigned_to is null)
                   or (f.shift_slot_id is not null and not app.fx_slot_live(f.shift_slot_id, p_now))
                   or (f.shift_slot_id is not null and f.assigned_to is null and not coalesce(f.shift_pinned, false)
                       and not exists (select 1 from app.fx_slot_people(f.shift_slot_id))))
            order by f.scheduled_at, f.id loop
    v_slot := app.fx_route_slot(j.kind, j.scheduled_at, p_now);
    if v_slot is null then
      -- no shift anybody works: unassigned (off a dead or empty shift), counted for the one Fleet To do below
      if j.shift_slot_id is not null then update field_jobs set shift_slot_id = null, shift_pinned = false where id = j.id; end if;
      v_none := v_none + 1;
      continue;
    end if;
    if v_slot is not distinct from j.shift_slot_id then
      -- still on a shift nobody works (no worked shift near): counted for the Fleet To do
      if not exists (select 1 from app.fx_slot_people(v_slot)) then v_none := v_none + 1; end if;
      continue;
    end if;
    update field_jobs set shift_slot_id = v_slot, shift_pinned = false where id = j.id;
    n := n + 1;
    if not exists (select 1 from app.fx_slot_people(v_slot)) then v_none := v_none + 1; end if;
  end loop;
  if v_none > 0 then
    insert into tasks (queue, task_type, title, detail, priority, status, dedupe_key)
    values ('fleet', 'field_jobs_no_shift', left(format('%s field job(s) have no shift anybody works', v_none), 200),
            'Field shifts are paused and no held shift can take these pickups, returns or preps. Open Field jobs (Staff portal > Fleet, or Admin > Field jobs) and assign each job to a person, or add a shift and ask someone to take it.',
            'high', 'open', 'field_jobs_no_shift')
    on conflict do nothing;
  end if;
  return format('%s field job(s) routed to a shift, %s with no shift anybody works', n, v_none);
end $$;
comment on function app.field_route_run(timestamptz) is 'Every hour (5173): open field jobs with nobody on no shift, on an ended or cancelled shift, or on a live shift nobody works, go on the shift of fx_route_slot: work not done carries over. With no shift anybody works they stay unassigned and Fleet gets one To do.';

select pg_temp.patch_fn('app.job_field_shift_plan(timestamptz)'::regprocedure,
  '|| app.job_field_shift_plan_pre2864(p_now);',
  '|| app.job_field_shift_plan_pre2864(p_now) || ''; '' || app.field_route_run(p_now);');

-- Take it: a job of the day from another shift, for a person who holds a shift that day
select pg_temp.patch_fn('app.fx_job_take(uuid,jsonb)'::regprocedure,
  'if j.shift_slot_id is null or p_user not in (select app.fx_slot_people(j.shift_slot_id)) then',
  'if (j.shift_slot_id is null or p_user not in (select app.fx_slot_people(j.shift_slot_id)))
     and not exists (select 1 from field_shift_plans x where x.staff_id = p_user and x.cancelled_at is null and app.local_date(x.starts_at) = app.fx_job_day(j)) then');

-- ================================================================ 4. Today
alter function app.fx_today(uuid, date) rename to fx_today_pre5173;
create function app.fx_today(p_user uuid, p_day date default null) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with d as (select coalesce(p_day, app.today()) as day),
       me as (select x.slot_id from field_shift_plans x, d where x.staff_id = p_user and x.cancelled_at is null and app.local_date(x.starts_at) = d.day),
       nxt as (select coalesce((select min(app.local_date(x.starts_at)) from field_shift_plans x, d where x.cancelled_at is null and app.local_date(x.starts_at) > d.day),
                               (select day + 1 from d)) as day)
  select app.fx_today_pre5173(p_user, p_day) || case when not exists (select 1 from me) then '{}'::jsonb else jsonb_build_object(
    'mates', coalesce((select jsonb_agg(jsonb_build_object('id', j.id, 'kind', j.kind, 'leg', app.fx_leg(j.kind), 'at', j.scheduled_at, 'status', j.status, 'place', j.place,
               'vehicle', app.vehicle_name(j.vehicle_id), 'booking', (select b.booking_number from bookings b where b.id = j.booking_id),
               'who', (select split_part(u.full_name, ' ', 1) from users u where u.id = j.assigned_to),
               'on_my_shift', j.shift_slot_id in (select slot_id from me)) order by j.scheduled_at, j.id)
        from field_jobs j, d
       where app.fx_job_day(j) = d.day and j.assigned_to is distinct from p_user and j.status not in ('cancelled', 'done')
         and (j.kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter') or j.shift_slot_id in (select slot_id from me))), '[]'::jsonb),
    'ahead', coalesce((select jsonb_agg(jsonb_build_object('id', j.id, 'kind', j.kind, 'leg', app.fx_leg(j.kind), 'at', j.scheduled_at, 'status', j.status,
               'day', app.fx_job_day(j), 'vehicle', app.vehicle_name(j.vehicle_id), 'plate', (select v.plate from vehicles v where v.id = j.vehicle_id),
               'booking', (select b.booking_number from bookings b where b.id = j.booking_id),
               'who', (select split_part(u.full_name, ' ', 1) from users u where u.id = j.assigned_to)) order by j.scheduled_at, j.id)
        from field_jobs j, d, nxt
       where app.fx_job_day(j) > d.day and app.fx_job_day(j) <= nxt.day and j.status not in ('cancelled', 'done')
         and j.kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter')), '[]'::jsonb),
    'next_shift_day', (select day from nxt)) end
$$;
select pg_temp.copy_grants('app.fx_today(uuid,date)', 'app.fx_today_pre5173(uuid,date)');

-- ================================================================ now
do $$ begin raise notice '5173: %', app.field_route_run(now()); end $$;

revoke all on function app.fx_slot_live(uuid, timestamptz) from public, anon, authenticated;
grant execute on function app.fx_slot_live(uuid, timestamptz) to service_role;
revoke all on function app.fx_route_slot_among(text, timestamptz, timestamptz, boolean) from public, anon, authenticated;
grant execute on function app.fx_route_slot_among(text, timestamptz, timestamptz, boolean) to service_role;
revoke all on function app.fx_route_slot(text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function app.fx_route_slot(text, timestamptz, timestamptz) to service_role;
revoke all on function app.field_route_run(timestamptz) from public, anon, authenticated;
grant execute on function app.field_route_run(timestamptz) to service_role;
