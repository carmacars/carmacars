-- 0325_staff_queue_hygiene.sql
-- The staff To do, seen live in a Sales assistant's portal (docs/changes/2026-11-06-staff-queue-and-view-as.md): 11 tasks
-- overdue, among them the same follow-up twice ("Call or message Yunu: started a booking request for the 2021 Kia Forte
-- and stopped": one per visit), "Booking CC-10024: the offer expires soon" days after the renter had paid, and
-- "Licences to check" listing expired and cancelled bookings.
--
-- 1. One task for the same work: a task raised while an open task of the same kind for the same person, car and
--    booking, with the same title, waits in the same queue is closed at once as merged into it; the duplicates open now
--    are merged the same way (the oldest stays).
-- 2. A booking's own tasks close with it: "the offer expires soon" (chase_offer) as soon as the booking is no longer an
--    offer (accepted, paid, confirmed, expired, declined); the licence and coverage review tasks (verify_renter,
--    chase_verification, protection_plan_request, coverage_review) as soon as the booking is no longer live (requested,
--    offered, waiting for payment, confirmed, on rent). At once (a trigger on the booking's status) and every hour.
-- 3. Follow-ups of visitors (visitor_follow_up) close after the same window as the unfinished forms' (0320,
--    capture_followup_days, 7 days); the visitor stays on Live visitors and Leads.
-- 4. "Licences to check" (Sales, 0169) lists live bookings only.
-- No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

create or replace function app.booking_live(s booking_status) returns boolean
language sql immutable as $$ select s::text in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent') $$;

-- ================================================================ 1. one task for the same work
create or replace function app.task_merge_new() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_keep uuid;
begin
  if new.status not in ('open', 'in_progress', 'waiting') then return null; end if;
  select t.id into v_keep from tasks t
   where t.id <> new.id and t.status in ('open', 'in_progress', 'waiting') and t.task_type = new.task_type and t.queue = new.queue
     and t.booking_id is not distinct from new.booking_id and t.vehicle_id is not distinct from new.vehicle_id
     and t.renter_id is not distinct from new.renter_id and t.owner_id is not distinct from new.owner_id
     and lower(btrim(t.title)) = lower(btrim(new.title)) and t.created_at <= new.created_at
   order by t.created_at, t.id limit 1;
  if v_keep is not null then
    update tasks set status = 'cancelled', completion_note = 'Merged: the same task is already open' where id = new.id;
  end if;
  return null;
end $$;
drop trigger if exists z_task_merge_new on tasks;
create trigger z_task_merge_new after insert on tasks for each row execute function app.task_merge_new();

create or replace function app.tasks_merge_duplicates() returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  with ranked as (
    select t.id, row_number() over (partition by t.task_type, t.queue, t.booking_id, t.vehicle_id, t.renter_id, t.owner_id, lower(btrim(t.title))
                                    order by t.created_at, t.id) rn
      from tasks t where t.status in ('open', 'in_progress', 'waiting'))
  update tasks t set status = 'cancelled', completion_note = coalesce(t.completion_note, 'Merged: the same task is already open')
    from ranked r where r.id = t.id and r.rn > 1;
  get diagnostics n = row_count;
  return n;
end $$;

-- ================================================================ 2 and 3. tasks that close by themselves
create or replace function app.tasks_close_stale(p_now timestamptz default now(), p_booking uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare n_offer integer; n_licence integer; n_follow integer; n_merged integer := 0;
begin
  update tasks t set status = case when b.status::text in ('pending_payment', 'confirmed', 'on_rent', 'completed', 'closed') then 'done' else 'cancelled' end,
         completed_at = p_now,
         completion_note = coalesce(t.completion_note, 'Closed by itself: the offer is no longer waiting (the booking is ' || replace(b.status::text, '_', ' ') || ')')
    from bookings b
   where b.id = t.booking_id and t.task_type = 'chase_offer' and t.status in ('open', 'in_progress', 'waiting')
     and b.status::text <> 'offered' and (p_booking is null or b.id = p_booking);
  get diagnostics n_offer = row_count;
  update tasks t set status = 'cancelled', completed_at = p_now,
         completion_note = coalesce(t.completion_note, 'Closed by itself: the booking is ' || replace(b.status::text, '_', ' '))
    from bookings b
   where b.id = t.booking_id and t.task_type in ('verify_renter', 'chase_verification', 'protection_plan_request', 'coverage_review')
     and t.status in ('open', 'in_progress', 'waiting') and not app.booking_live(b.status) and (p_booking is null or b.id = p_booking);
  get diagnostics n_licence = row_count;
  if p_booking is null then
    update tasks set status = 'cancelled', completed_at = p_now,
           completion_note = format('Closed by itself after %s days: the visitor stays on Live visitors and Leads', (app.settings()).capture_followup_days)
     where task_type = 'visitor_follow_up' and status in ('open', 'in_progress', 'waiting')
       and created_at < p_now - make_interval(days => (app.settings()).capture_followup_days);
    get diagnostics n_follow = row_count;
    n_merged := app.tasks_merge_duplicates();
  else
    n_follow := 0;
  end if;
  return jsonb_build_object('offers', n_offer, 'licences', n_licence, 'follow_ups', n_follow, 'merged', n_merged);
end $$;

create or replace function app.booking_tasks_close() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status is distinct from old.status then perform app.tasks_close_stale(now(), new.id); end if;
  return null;
end $$;
drop trigger if exists z_booking_tasks_close on bookings;
create trigger z_booking_tasks_close after update of status on bookings for each row execute function app.booking_tasks_close();

alter function app.job_task_hygiene(timestamptz) rename to job_task_hygiene_pre0325;
create function app.job_task_hygiene(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.job_task_hygiene_pre0325(p_now) || app.tasks_close_stale(p_now);
end $$;
select pg_temp.copy_grants('app.job_task_hygiene(timestamptz)'::regprocedure, 'app.job_task_hygiene_pre0325(timestamptz)'::regprocedure);

-- ================================================================ 4. Licences to check: live bookings only
alter function app.sales_licences(uuid) rename to sales_licences_pre0325;
create function app.sales_licences(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x order by n), '[]'::jsonb)
    from jsonb_array_elements(app.sales_licences_pre0325(p_user)) with ordinality t(x, n)
   where x ->> 'status' in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent')
$$;
select pg_temp.copy_grants('app.sales_licences(uuid)'::regprocedure, 'app.sales_licences_pre0325(uuid)'::regprocedure);

-- ================================================================ now: the queues as they would have been
select app.tasks_close_stale();

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('booking_live', 'task_merge_new', 'tasks_merge_duplicates', 'tasks_close_stale', 'booking_tasks_close',
              'job_task_hygiene_pre0325', 'sales_licences_pre0325') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
