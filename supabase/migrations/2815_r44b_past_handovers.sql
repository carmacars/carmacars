-- 2815 (release 44, part B): photos and readings for past check-ins and check-outs (the owner, November 13).
-- A pickup or return recorded with "details later" (0195) could be completed, but a rental recorded after the fact
-- (Record a past trip, Override and record the pickup, a closed booking) with no check-in or check-out report at all had
-- no way to get one, and nobody saw which bookings lacked theirs. Now:
--   * app.handover_missing: the bookings out, returned or closed (the last 400 days, Program settings
--     manual_rental_past_max_days) whose check-in (pickup) or check-out (return) report is missing or waits for its
--     details, with who it is given to. An Admin, Fleet and customer service see all; field staff see the bookings they
--     handled (a job of theirs on the booking, or a report they made) and those an Admin gave them.
--   * Opening one ("Add the photos and readings", app.handover_open): a booking past that stage with no report gets one
--     made "details later" (who, when, "Added after the trip"), then the usual checklist completes it without moving the
--     booking (0195). Field staff open only bookings they handled or were given.
--   * A closed booking is not charged again by itself when its check-out photos and readings are added afterwards.
--   * handover_missing_assign {booking, kind, staff}: an Admin or Fleet gives one to a field staff member (the job of
--     that check-in or check-out, assigned to them).
-- No applied migration is edited: handover_open is wrapped (_pre2815).

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- the booking is one this field staff member handled or was given
create function app.field_handled(p_user uuid, p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from field_jobs j where j.booking_id = p_booking and j.assigned_to = p_user and j.status <> 'cancelled')
      or exists (select 1 from condition_reports c where c.booking_id = p_booking and (c.performed_by = p_user or c.completed_by = p_user))
$$;

-- the stage a booking is past: its check-in (pickup) once it is out, its check-out (return) once it is back
create function app.handover_past_stage(b bookings, p_kind text) returns boolean
language sql stable as $$
  select b.booking_type <> 'owner' and case p_kind when 'pickup' then b.status::text in ('on_rent', 'returned', 'closed')
                                                   when 'return' then b.status::text in ('returned', 'closed') else false end
$$;

create function app.handover_missing(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_all boolean := app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs');
  v_since timestamptz := now() - make_interval(days => coalesce((app.settings()).manual_rental_past_max_days, 400));
begin
  if not (v_all or coalesce(app.user_is_field(p_by), false)) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('booking_id', x.id, 'booking_number', x.booking_number, 'kind', x.kind, 'status', x.status,
           'at', x.at, 'car', app.vehicle_name(x.vehicle_id), 'renter', (select r.legal_name from renters r where r.id = x.renter_id),
           'state', case when x.pending then 'details_pending' else 'missing' end,
           'assigned_to', (select u.full_name from field_jobs j join users u on u.id = j.assigned_to
                            where j.booking_id = x.id and j.status not in ('done', 'cancelled')
                              and j.kind = any (case x.kind when 'pickup' then array['handover', 'delivery'] else array['return_check_in', 'pickup_from_renter'] end)
                            order by j.scheduled_at desc limit 1),
           'mine', app.field_handled(p_by, x.id)) order by x.at desc)
    from (select b.*, k.kind, case k.kind when 'pickup' then coalesce(b.handed_over_at, b.pickup_at) else coalesce(b.checked_in_at, b.return_at) end as at,
                 exists (select 1 from condition_reports c where c.booking_id = b.id and c.kind = k.kind and c.details_pending) as pending
            from bookings b cross join (values ('pickup'), ('return')) k(kind)
           where app.handover_past_stage(b, k.kind) and b.pickup_at > v_since
             and not exists (select 1 from condition_reports c where c.booking_id = b.id and c.kind = k.kind and c.completed_at is not null)
             and (v_all or app.field_handled(p_by, b.id))) x), '[]'::jsonb);
end $$;

-- opening one: a report made "details later" when there is none, then the 0195 path
alter function app.handover_open(uuid, uuid, text) rename to handover_open_pre2815;
create function app.handover_open(p_user uuid, p_booking uuid, p_kind text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c condition_reports;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or p_kind not in ('pickup', 'return') or not app.handover_past_stage(b, p_kind) then
    return app.handover_open_pre2815(p_user, p_booking, p_kind);
  end if;
  if not app.user_may_handover(p_user) then
    raise exception 'Only an Admin, Fleet, Sales, Customer service or field staff add a check-in or check-out' using errcode = '42501';
  end if;
  if coalesce(app.user_is_field(p_user), false) and not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet', 'sales', 'cs'))
     and not app.field_handled(p_user, b.id) then
    raise exception 'Booking % is not one of your jobs: ask Fleet to give it to you', b.booking_number using errcode = '42501';
  end if;
  select * into c from condition_reports where booking_id = b.id and kind = p_kind for update;
  if c.completed_at is not null then
    raise exception 'The % of booking % is already recorded with its report', case p_kind when 'pickup' then 'check-in' else 'check-out' end, b.booking_number using errcode = '23514';
  end if;
  if c.id is null then
    insert into condition_reports (vehicle_id, booking_id, kind, performed_by, performed_by_role, performed_at, details_pending, recorded_now, renter_present)
    values (b.vehicle_id, b.id, p_kind, p_user, 'staff', case p_kind when 'pickup' then coalesce(b.handed_over_at, b.pickup_at) else coalesce(b.checked_in_at, b.return_at) end,
            true, jsonb_build_object('by', p_user, 'at', now(), 'reason', 'Added after the trip'), false);
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
      format('The %s photos and readings are added after the trip', case p_kind when 'pickup' then 'check-in' else 'check-out' end), p_user, 'staff',
      jsonb_build_object('kind', p_kind, 'after_trip', true));
  elsif not c.details_pending then
    update condition_reports set details_pending = true,
           recorded_now = coalesce(recorded_now, jsonb_build_object('by', p_user, 'at', now(), 'reason', 'Added after the trip'))
     where id = c.id;
  end if;
  return app.handover_open_pre2815(p_user, p_booking, p_kind);
end $$;
select pg_temp.copy_grants('app.handover_open(uuid, uuid, text)'::regprocedure, 'app.handover_open_pre2815(uuid, uuid, text)'::regprocedure);

-- photos and readings added after a closed rental never charge it again by themselves (km, fuel, late return): the
-- booking's money was settled when it closed; staff add a charge by hand if one is owed
alter function app.return_auto_charges(uuid) rename to return_auto_charges_pre2815;
create function app.return_auto_charges(p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from bookings b join condition_reports c on c.booking_id = b.id and c.kind = 'return'
              where b.id = p_booking and b.status::text = 'closed' and c.recorded_now ->> 'reason' = 'Added after the trip') then
    return jsonb_build_object('skipped', 'closed before the photos and readings were added');
  end if;
  return app.return_auto_charges_pre2815(p_booking);
end $$;
select pg_temp.copy_grants('app.return_auto_charges(uuid)'::regprocedure, 'app.return_auto_charges_pre2815(uuid)'::regprocedure);

-- an Admin or Fleet gives one to a field staff member
create function app.handover_missing_assign(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_kind text := p ->> 'kind';
  v_staff uuid := nullif(p ->> 'staff', '')::uuid;
  j field_jobs;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then raise exception 'An Admin or Fleet gives the job' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_kind not in ('pickup', 'return') or not app.handover_past_stage(b, v_kind) then
    raise exception 'Booking % has no past % to complete', b.booking_number, case v_kind when 'pickup' then 'check-in' else 'check-out' end using errcode = '23514';
  end if;
  if v_staff is null or not coalesce(app.user_is_field(v_staff), false) then raise exception 'Choose a field staff member' using errcode = '22023'; end if;
  select * into j from field_jobs x
   where x.booking_id = b.id and x.status not in ('done', 'cancelled')
     and x.kind = any (case v_kind when 'pickup' then array['handover', 'delivery'] else array['return_check_in', 'pickup_from_renter'] end)
   order by x.scheduled_at desc limit 1 for update;
  if j.id is null then
    insert into field_jobs (kind, booking_id, vehicle_id, assigned_to, dispatched_by, scheduled_at, place, status, instructions)
    values (case v_kind when 'pickup' then 'handover' else 'return_check_in' end, b.id, b.vehicle_id, v_staff, p_by, now(),
            case v_kind when 'pickup' then b.pickup_place else b.return_place end, 'scheduled',
            format('Add the %s photos and readings of this past rental.', case v_kind when 'pickup' then 'check-in' else 'check-out' end))
    returning * into j;
  else
    update field_jobs set assigned_to = v_staff where id = j.id returning * into j;
  end if;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('The %s photos and readings were given to %s', case v_kind when 'pickup' then 'check-in' else 'check-out' end, (select full_name from users where id = v_staff)),
    p_by, 'staff', jsonb_build_object('field_job_id', j.id));
  return jsonb_build_object('ok', true, 'job', j.id);
end $$;

revoke all on function app.field_handled(uuid, uuid), app.handover_past_stage(bookings, text), app.handover_missing(uuid, jsonb), app.handover_open_pre2815(uuid, uuid, text),
  app.handover_missing_assign(uuid, jsonb), app.return_auto_charges_pre2815(uuid) from public, anon, authenticated;
grant execute on function app.field_handled(uuid, uuid), app.handover_past_stage(bookings, text), app.handover_missing(uuid, jsonb), app.handover_open_pre2815(uuid, uuid, text),
  app.handover_missing_assign(uuid, jsonb), app.return_auto_charges_pre2815(uuid) to service_role;
