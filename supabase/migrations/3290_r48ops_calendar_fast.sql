-- 3290 (release 48, operations screens): the fleet calendar's read, fast on a large fleet, and the two jobs at the end
-- of a trip.
-- The owner (Nov 20): the calendar must stay usable with 100+ cars; a return is a check-out and shows its time; the return
-- check-out and the post-trip cleaning are two separate jobs on the calendar; the read was about 230 ms.
--   1. app.admin_calendar is written again as one set-based read of the base tables. Before, it read the calendar_entries
--      view through app.master_calendar (who-may-see-what asked again for every row), built the JSON, then took it apart
--      car by car to add the placeholder flag, the clashes (the turnaround looked up for every pair of bars) and the hold
--      of each offer. Now: who is asking is worked out once, each table is read once for the dates asked, the clashes are
--      one join with each car's turnaround read once. What a role sees is unchanged (the tests of 0284, 0480 and 2961 run
--      against it, and supabase/tests/99_r48ops_calendar.sql compares it with the old read on the same data).
--   2. New on an entry, nothing removed:
--        returned_at  a booking's actual return (checked_in_at), so the calendar shows when the car really came back
--        for_booking  the booking a field job or a cleaning block belongs to (its number)
--        done_at      a field job's completion; a post-trip cleaning's clean check after the return (vehicle_clean_checks)
--        job          'post_trip_cleaning' on the cleaning block a trip leaves behind (0040)
--        cleaned_at   on a booking: the clean check after its return, for a car with no cleaning block
--   3. Indexes for the dates asked: bookings by return, field jobs by time and by completion, Turo trips by end.
-- The read it replaces stays as app.admin_calendar_pre3290 (with app.admin_calendar_pre0284 and app.master_calendar
-- under it): the DB test compares the two for every role on the same data.
-- SCHEMA_MARKER 3290. docs/changes/2026-11-20-r48-ops-screens.md.
set local check_function_bodies = off;

create index if not exists bookings_return_at_idx on bookings (return_at);
create index if not exists field_jobs_scheduled_at_idx on field_jobs (scheduled_at);
create index if not exists field_jobs_completed_at_idx on field_jobs (completed_at) where completed_at is not null;
create index if not exists turo_trips_ends_at_idx on turo_trips (ends_at);

alter function app.admin_calendar(timestamptz, timestamptz, uuid) rename to admin_calendar_pre3290;

create function app.admin_calendar(p_from timestamptz, p_to timestamptz, p_vehicle uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  -- who is asking, once (the calendar_entries view asked for every row)
  v_admin boolean := app.is_admin();
  v_staff boolean := app.is_staff();
  v_full boolean;   -- full names, notes and insurers; field jobs
  v_moves boolean;  -- car moves and Turo trips
  v_turn integer := coalesce((app.settings()).turnaround_buffer_minutes, 0);
  v jsonb;
begin
  v_full := v_admin or app.va_has('cs', 'finance', 'fleet');
  v_moves := v_admin or app.va_has('fleet', 'finance');
  with veh as materialized (
    select v.id, v.year || ' ' || v.make || ' ' || v.model as label, v.plate, v.fleet_number, v.status::text as status, v.class::text as class,
           v.supply_type, v.management_mode::text as mode,
           case when o.id is null then null when v.supply_type = 'company' then 'CarmaCars'
                when v.supply_type = 'partner' then (select r.business_name from partners r where r.id = v.partner_id) else o.legal_name end as owner,
           greatest(coalesce(v.turnaround_block_minutes, v_turn, 0), 0) as turn,
           v_moves or app.owns_vehicle(v.id) as sees_turo
      from vehicles v
      left join owners o on o.id = v.owner_id
     where (v_staff or app.owns_vehicle(v.id))
       and v.status::text not in ('declined', 'exited')
       and (v.retired_at is null or v.retired_at > p_from)
       and (p_vehicle is null or v.id = p_vehicle)
  ), ent as materialized (
    select b.vehicle_id, 'booking'::text as type, b.id as entry_id, b.id as booking_id, b.booking_number, b.booking_type::text as booking_type, b.status::text as status,
           case when b.status::text in ('requested', 'offered', 'tentative', 'pending_payment') then 'pending' when b.status::text = 'confirmed' then 'booked'
                when b.status::text = 'on_rent' then 'out' when b.status::text in ('returned', 'closed') then 'done' else 'void' end as state,
           b.pickup_at as starts_at, b.return_at as ends_at, b.blocks_calendar as blocks,
           b.blocks_calendar and b.status::text in ('confirmed', 'on_rent') as blocking, b.bill_to::text as bill_to, b.dates_provisional as provisional,
           case when v_full then i.name end as insurer,
           case when v_full then r.legal_name else split_part(btrim(r.legal_name), ' ', 1) end as renter,
           null::text as reason, case when v_full then b.notes end as note, null::text as assignee, null::text as detail,
           case when b.status::text in ('offered', 'pending_payment') then app.booking_hold_until(b) end as hold_until,
           (b.is_placeholder or (not b.blocks_calendar and b.handed_over_at is null)) and b.status::text not in ('on_rent', 'returned', 'closed') as ph,
           b.blocks_calendar and b.status::text in ('pending_payment', 'confirmed', 'on_rent') as takes,
           b.checked_in_at as returned_at, null::text as for_booking, null::timestamptz as done_at, null::text as job,
           (select min(k.checked_at) from vehicle_clean_checks k where k.booking_id = b.id and k.moment = 'after_return' and k.clean) as cleaned_at
      from bookings b
      join veh on veh.id = b.vehicle_id
      join renters r on r.id = b.renter_id
      left join insurers i on i.id = b.insurer_id
     where b.pickup_at < p_to and b.return_at > p_from
    union all
    select c.vehicle_id, 'block', c.id, null, null, null, 'blocked', 'blocked', c.starts_at, c.ends_at, true, true, null, false, null, null,
           c.reason, case when v_staff then c.note end, null, null, null, false, true,
           null, (select x.booking_number from bookings x where x.id = c.booking_id),
           case when c.source = 'turnaround' then (select min(k.checked_at) from vehicle_clean_checks k where k.booking_id = c.booking_id and k.moment = 'after_return' and k.clean) end,
           case when c.source = 'turnaround' then 'post_trip_cleaning' end, null
      from vehicle_calendar_blocks c
      join veh on veh.id = c.vehicle_id
     where c.removed_at is null and c.starts_at < p_to and (c.ends_at is null or c.ends_at > p_from)
    union all
    select j.vehicle_id, 'field_job', j.id, null, null, null, j.status, 'job', j.scheduled_at,
           greatest(coalesce(j.completed_at, j.scheduled_at + interval '1 hour'), j.scheduled_at + interval '1 minute'), false, false, null, false, null, null,
           null, j.instructions, u.full_name, j.kind, null, false, false,
           null, (select x.booking_number from bookings x where x.id = j.booking_id), j.completed_at, null, null
      from field_jobs j
      join veh on veh.id = j.vehicle_id
      left join users u on u.id = j.assigned_to
     where v_full and j.status <> 'cancelled' and j.scheduled_at < p_to
       and (j.scheduled_at > p_from - interval '1 hour' or j.completed_at > p_from)
       and greatest(coalesce(j.completed_at, j.scheduled_at + interval '1 hour'), j.scheduled_at + interval '1 minute') > p_from
    union all
    select m.vehicle_id, 'vehicle_move', m.id, null, null, null, case when m.ended_at is null then 'open' else 'done' end, 'move', m.started_at, m.ended_at,
           false, false, null, false, null, null, null, nullif(concat_ws(' to ', m.from_place, m.to_place), ''), u.full_name, m.purpose, null, false, false,
           null, null, null, null, null
      from vehicle_moves m
      join veh on veh.id = m.vehicle_id
      left join users u on u.id = m.staff_user_id
     where v_moves and m.started_at < p_to and (m.ended_at is null or m.ended_at > p_from)
    union all
    select t.vehicle_id, 'turo_trip', t.id, null, null, null, 'turo', 'turo', t.starts_at, t.ends_at, false, false, null, false, null, null,
           null, null, null, t.turo_trip_ref, null, false, false, null, null, null, null, null
      from turo_trips t
      join veh on veh.id = t.vehicle_id
     where veh.sees_turo and t.starts_at < p_to and (t.ends_at is null or t.ends_at > p_from)
  ), bars as (
    select e.vehicle_id, e.type, e.entry_id, e.booking_number, e.reason, e.ph, e.takes, e.starts_at as s, coalesce(e.ends_at, 'infinity'::timestamptz) as f
      from ent e where e.type in ('booking', 'block')
  ), clash as (
    -- the bars each bar collides with on its car: a bar that takes the car, over a booking or (a booking) over a block;
    -- two bookings also keep the car's turnaround between them
    select e.type, e.entry_id,
           jsonb_agg(coalesce(o.booking_number, initcap(replace(coalesce(o.reason, 'block'), '_', ' '))) order by o.s, o.entry_id) as hits
      from bars e
      join veh on veh.id = e.vehicle_id
      join bars o on o.vehicle_id = e.vehicle_id and (o.type, o.entry_id) is distinct from (e.type, e.entry_id)
     where not e.ph and not o.ph and o.takes
       and not (e.type = 'block' and o.type = 'block')
       and o.s - case when e.type = 'booking' and o.type = 'booking' then make_interval(mins => veh.turn) else interval '0' end < e.f
       and o.f + case when e.type = 'booking' and o.type = 'booking' then make_interval(mins => veh.turn) else interval '0' end > e.s
     group by e.type, e.entry_id
  ), per_car as (
    select e.vehicle_id,
           jsonb_agg(jsonb_build_object('type', e.type, 'id', e.entry_id, 'booking_id', e.booking_id, 'booking_number', e.booking_number, 'booking_type', e.booking_type,
               'status', e.status, 'state', e.state, 'starts_at', e.starts_at, 'ends_at', e.ends_at, 'blocks', e.blocks, 'blocking', e.blocking, 'bill_to', e.bill_to,
               'provisional', e.provisional, 'insurer', e.insurer, 'renter', e.renter, 'reason', e.reason, 'note', e.note, 'assignee', e.assignee, 'detail', e.detail)
             || jsonb_build_object('hold_until', e.hold_until, 'placeholder', e.ph and e.type = 'booking', 'clash', coalesce(c.hits, '[]'::jsonb),
               'returned_at', e.returned_at, 'for_booking', e.for_booking, 'done_at', e.done_at, 'job', e.job, 'cleaned_at', e.cleaned_at)
             order by e.starts_at, e.type, e.entry_id) as entries
      from ent e
      left join clash c on c.type = e.type and c.entry_id = e.entry_id
     group by e.vehicle_id
  )
  select jsonb_build_object('from', p_from, 'to', p_to, 'now', now(),
           'vehicles', coalesce(jsonb_agg(jsonb_build_object('id', veh.id, 'label', veh.label, 'plate', veh.plate, 'fleet_number', veh.fleet_number, 'status', veh.status,
               'class', veh.class, 'owner', veh.owner, 'supply_type', veh.supply_type, 'mode', veh.mode, 'entries', coalesce(p.entries, '[]'::jsonb))
             order by veh.fleet_number nulls last, veh.label, veh.id), '[]'::jsonb))
    into v
    from veh
    left join per_car p on p.vehicle_id = veh.id;
  return v;
end $$;
comment on function app.admin_calendar(timestamptz, timestamptz, uuid) is
  'The fleet calendar (3290): every car the caller may see with its bookings, blocks, field jobs, moves and Turo trips of the dates asked, the clashes, the holds and the two end-of-trip jobs. One set-based read.';
revoke all on function app.admin_calendar(timestamptz, timestamptz, uuid) from public, anon, authenticated;
grant execute on function app.admin_calendar(timestamptz, timestamptz, uuid) to service_role;
