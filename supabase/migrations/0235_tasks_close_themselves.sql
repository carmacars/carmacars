-- 0235: the tasks a rental already underway raises close themselves when their condition is met
-- (docs/changes/2026-11-03-tasks-close-themselves.md). The owner: "<car> is out on rental ...: set its status to On rent"
-- stayed open after the car was set to On rent, until someone pressed Done. The tasks of 0072 (app.manual_rental_went_out)
-- were raised once and only the agreement (0185), the drivers (0072), the deposit (0148) and the insurance (0078) ones
-- were closed by what they asked for.
--
-- Now, closed as done with a note:
--   live_rental_car_status   the car is set to On rent; the booking moved to another car (Change car); the rental ended
--                            (returned or closed). Cancelled with the booking.
--   live_rental_condition    a pickup condition report is recorded for the booking.
--   live_rental_coverage     the booking's coverage is confirmed (coverage_confirmed_at) with a confirmed proof.
--   live_rental_insurance    the booking moved to another car (the new car raises its own when it needs one, 0078).
--   every live_rental_* task is cancelled when its booking is cancelled, declined or expired.
-- Tasks done or cancelled stay as they are. No applied migration is edited.

create or replace function app.tasks_close_vehicle_status() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'on_rent' and old.status is distinct from new.status then
    update tasks set status = 'done', completed_at = now(), completion_note = coalesce(completion_note, 'Closed by itself: the car was set to On rent')
     where vehicle_id = new.id and task_type = 'live_rental_car_status' and status in ('open', 'in_progress', 'waiting');
  end if;
  return null;
end $$;
drop trigger if exists vehicles_tasks_close_status on vehicles;
create trigger vehicles_tasks_close_status after update of status on vehicles for each row execute function app.tasks_close_vehicle_status();

create or replace function app.tasks_close_live_rental() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.vehicle_id is distinct from old.vehicle_id then
    update tasks set status = 'done', completed_at = now(), completion_note = coalesce(completion_note, 'Closed by itself: the booking moved to another car')
     where booking_id = new.id and vehicle_id = old.vehicle_id and task_type in ('live_rental_car_status', 'live_rental_insurance')
       and status in ('open', 'in_progress', 'waiting');
  end if;
  if new.status is distinct from old.status then
    if new.status::text in ('cancelled', 'declined', 'expired') then
      update tasks set status = 'cancelled', completed_at = now(), completion_note = coalesce(completion_note, 'Closed by itself: the booking was ' || new.status::text)
       where booking_id = new.id and task_type like 'live\_rental\_%' and status in ('open', 'in_progress', 'waiting');
    elsif new.status::text in ('returned', 'closed') then
      update tasks set status = 'done', completed_at = now(), completion_note = coalesce(completion_note, 'Closed by itself: the rental ended')
       where booking_id = new.id and task_type = 'live_rental_car_status' and status in ('open', 'in_progress', 'waiting');
    end if;
  end if;
  if new.coverage_confirmed_at is not null and old.coverage_confirmed_at is null
     and exists (select 1 from coverage_proofs c where c.booking_id = new.id and c.status = 'confirmed') then
    perform app.resolve_tasks(array['live_rental_coverage'], new.id, null, 'Closed by itself: the coverage was confirmed');
  end if;
  return null;
end $$;
drop trigger if exists bookings_tasks_close_live_rental on bookings;
create trigger bookings_tasks_close_live_rental after update of vehicle_id, status, coverage_confirmed_at on bookings
  for each row execute function app.tasks_close_live_rental();

create or replace function app.tasks_close_condition_report() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.kind = 'pickup' and new.booking_id is not null then
    perform app.resolve_tasks(array['live_rental_condition'], new.booking_id, null, 'Closed by itself: the pickup condition report was recorded');
  end if;
  return null;
end $$;
drop trigger if exists condition_reports_tasks_close on condition_reports;
create trigger condition_reports_tasks_close after insert on condition_reports for each row execute function app.tasks_close_condition_report();

revoke all on function app.tasks_close_vehicle_status() from public, anon, authenticated;
grant execute on function app.tasks_close_vehicle_status() to service_role;
revoke all on function app.tasks_close_live_rental() from public, anon, authenticated;
grant execute on function app.tasks_close_live_rental() to service_role;
revoke all on function app.tasks_close_condition_report() from public, anon, authenticated;
grant execute on function app.tasks_close_condition_report() to service_role;

-- the ones already met close now
update tasks t set status = 'done', completed_at = now(), completion_note = 'Closed by itself: the car is On rent'
  from vehicles v
 where v.id = t.vehicle_id and v.status = 'on_rent' and t.task_type = 'live_rental_car_status' and t.status in ('open', 'in_progress', 'waiting');
update tasks t set status = 'done', completed_at = now(), completion_note = 'Closed by itself: the booking moved to another car'
  from bookings b
 where b.id = t.booking_id and t.vehicle_id is distinct from b.vehicle_id and t.task_type = 'live_rental_car_status' and t.status in ('open', 'in_progress', 'waiting');
update tasks t set status = 'done', completed_at = now(), completion_note = 'Closed by itself: the pickup condition report was recorded'
 where t.task_type = 'live_rental_condition' and t.status in ('open', 'in_progress', 'waiting')
   and exists (select 1 from condition_reports c where c.booking_id = t.booking_id and c.kind = 'pickup');
