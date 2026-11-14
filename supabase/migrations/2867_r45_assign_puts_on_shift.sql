-- 2867 (release 45): Fleet or an Admin giving a field job to a person who holds no shift that day puts them on one.
--
-- 1051 refuses to give a job to a person with no shift on a day that has shifts ("not on a shift that day"). With shifts
-- now published by themselves every second day and around every handover and return (2864), almost every job day has
-- shifts, so Fleet's Assign would be refused unless they first put the person on a shift by hand. Now, when Fleet or an
-- Admin assigns, the person is put on the shift of that day that covers the job (its own covering shift first, then one
-- running at the job's time, then the earliest of the day) where a place is free, exactly as Put on a shift does, and the
-- job is then given to them. With no free place the refusal is unchanged.
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

alter function app.assign_field_job(uuid, uuid, uuid) rename to assign_field_job_pre2867;
create function app.assign_field_job(p_job uuid, p_assignee uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
  v_day date;
  v_slot uuid;
begin
  select * into j from field_jobs where id = p_job;
  if j.id is not null and p_assignee is not null and p_by is not null and app.user_runs_fleet(p_by)
     and j.status in ('scheduled', 'acknowledged') and not app.academy_locked(p_assignee) then
    v_day := app.fx_job_day(j);
    if app.fx_person_slot(p_assignee, j.scheduled_at, v_day) is null and app.fx_person_slot(p_assignee, j.scheduled_at, null) is null
       and exists (select 1 from field_shift_slots x where x.cancelled_at is null and app.local_date(x.starts_at) = v_day) then
      select s.id into v_slot from field_shift_slots s
       where s.cancelled_at is null and app.local_date(s.starts_at) = v_day
         and (select count(*) from field_shift_plans x where x.slot_id = s.id and x.cancelled_at is null) < s.capacity
       order by (s.cover_booking_id is not distinct from j.booking_id and j.booking_id is not null) desc,
                (s.starts_at <= j.scheduled_at and s.ends_at > j.scheduled_at) desc, s.starts_at
       limit 1;
      if v_slot is not null then
        begin
          perform app.field_shift_book(p_assignee, v_slot, p_by);
        exception when others then
          null; -- not someone who takes shifts, or the place went: the check below gives the reason
        end;
      end if;
    end if;
  end if;
  perform app.assign_field_job_pre2867(p_job, p_assignee, p_by);
end $$;
comment on function app.assign_field_job(uuid, uuid, uuid) is 'r45 (2867): Fleet or an Admin giving a job to a person with no shift that day first puts them on that day''s shift covering the job (a free place only), then 1051''s checks and assignment.';
select pg_temp.copy_grants('app.assign_field_job(uuid, uuid, uuid)'::regprocedure, 'app.assign_field_job_pre2867(uuid, uuid, uuid)'::regprocedure);
revoke all on function app.assign_field_job_pre2867(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function app.assign_field_job_pre2867(uuid, uuid, uuid) to service_role;
