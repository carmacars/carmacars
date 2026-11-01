-- 0284_conflicting_dates.sql
-- Conflicting dates on one car, said plainly (docs/changes/2026-11-05-placeholder-bookings.md, section 2). Two bookings,
-- requests or offers on the same car for overlapping dates were drawn on top of each other on the calendar, and the
-- booking page listed every overlap the same way, a placeholder for an insurer like a real rental.
--
-- 1. app.booking_date_conflicts(booking): everything else on the car for overlapping dates (the turnaround counted
--    around a blocking booking): each booking with what it is (booked and blocking, a request or offer, not blocking, a
--    placeholder), and the calendar blocks and Turo trips. "holds" says whether it keeps this one from going ahead. A
--    placeholder never holds anything and nothing holds against it.
-- 2. The booking page's "Competing for these dates" uses it (admin_booking_detail.competing, the same keys plus the
--    new ones), and the overview shows it too once the booking is confirmed.
-- 3. The calendar (admin_calendar): each entry says whether it is a placeholder, and "clash" lists what it collides
--    with: a request, offer or non-blocking booking over a blocking booking or a block (the dates are taken), or two
--    blocking entries over each other. The screen stacks overlapping bars instead of drawing them on top of each other.
-- No applied migration is edited.

-- ================================================================ 1. what else is on the car for these dates
create or replace function app.booking_date_conflicts(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_buffer interval := make_interval(mins => coalesce((app.settings()).turnaround_buffer_minutes, 0));
  v_out jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x order by x ->> 'starts_at', x ->> 'booking_number'), '[]'::jsonb) into v_out from (
    select jsonb_build_object('type', 'booking', 'id', o.id, 'booking_number', o.booking_number, 'status', o.status,
             'pickup_at', o.pickup_at, 'return_at', o.return_at, 'starts_at', o.pickup_at, 'ends_at', o.return_at,
             'renter', (select split_part(btrim(r.legal_name), ' ', 1) from renters r where r.id = o.renter_id),
             'blocks', o.blocks_calendar, 'placeholder', app.booking_is_placeholder(o.id),
             'kind', case when app.booking_is_placeholder(o.id) then 'placeholder'
                          when o.blocks_calendar and o.status in ('confirmed', 'on_rent') then 'booked'
                          when o.status in ('confirmed', 'on_rent') then 'not_blocking'
                          else 'request' end,
             -- it keeps this one off the car: a blocking booking, unless this one is the placeholder
             'holds', not app.booking_is_placeholder(b.id) and not app.booking_is_placeholder(o.id)
                      and o.blocks_calendar and o.status in ('confirmed', 'on_rent')) as x
      from bookings o
     where o.vehicle_id = b.vehicle_id and o.id <> b.id
       and o.status in ('requested', 'offered', 'tentative', 'pending_payment', 'confirmed', 'on_rent')
       and o.pickup_at < b.return_at + case when o.blocks_calendar then v_buffer else interval '0' end
       and coalesce(o.checked_in_at, o.return_at) > b.pickup_at - case when o.blocks_calendar then v_buffer else interval '0' end
    union all
    select jsonb_build_object('type', 'block', 'id', k.id, 'reason', k.reason, 'note', k.note, 'starts_at', k.starts_at, 'ends_at', k.ends_at,
             'kind', 'block', 'placeholder', false, 'holds', not app.booking_is_placeholder(b.id))
      from vehicle_calendar_blocks k
     where k.vehicle_id = b.vehicle_id and k.removed_at is null
       and k.starts_at < b.return_at and coalesce(k.ends_at, 'infinity'::timestamptz) > b.pickup_at
       and k.booking_id is distinct from b.id
    union all
    select jsonb_build_object('type', 'turo_trip', 'id', t.id, 'starts_at', t.starts_at, 'ends_at', t.ends_at, 'kind', 'turo',
             'placeholder', false, 'holds', not app.booking_is_placeholder(b.id))
      from turo_trips t
     where t.vehicle_id = b.vehicle_id and t.starts_at < b.return_at and t.ends_at > b.pickup_at
  ) q;
  return v_out;
end $$;
comment on function app.booking_date_conflicts(uuid) is 'Everything else on the booking''s car for overlapping dates (0284): bookings with their kind (booked, request, not_blocking, placeholder), calendar blocks and Turo trips; holds = it keeps this booking from going ahead.';

-- ================================================================ 2. the booking page
alter function app.admin_booking_detail(uuid) rename to admin_booking_detail_pre0284;
create function app.admin_booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_booking_detail_pre0284(p_booking);
begin
  if v is null then return v; end if;
  return v || jsonb_build_object('competing', app.booking_date_conflicts(p_booking),
    'placeholder', coalesce((select jsonb_build_object('on', b.is_placeholder, 'reason', b.placeholder_reason, 'at', b.placeholder_at,
                                                       'by', (select u.full_name from users u where u.id = b.placeholder_by),
                                                       'shape', app.booking_is_placeholder(b.id))
                               from bookings b where b.id = p_booking), '{}'::jsonb));
end $$;

-- ================================================================ 3. the calendar
-- Each bar (a booking or a block) gets "placeholder" and "clash": the bars it collides with on the same car. A bar that
-- takes the car is a blocking booking (confirmed or on rent) or a block; a request, an offer or a non-blocking booking
-- over one of those has its dates taken; two that take the car over each other collide both ways.
alter function app.admin_calendar(timestamptz, timestamptz, uuid) rename to admin_calendar_pre0284;
create function app.admin_calendar(p_from timestamptz, p_to timestamptz, p_vehicle uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_calendar_pre0284(p_from, p_to, p_vehicle);
  veh jsonb;
  vehs jsonb := '[]'::jsonb;
  ents jsonb;
  ph uuid[];
begin
  if v is null or jsonb_typeof(v -> 'vehicles') <> 'array' then return v; end if;
  ph := array(select b.id from bookings b where b.is_placeholder or (not b.blocks_calendar and b.handed_over_at is null)
                and b.id in (select (e ->> 'booking_id')::uuid from jsonb_array_elements(v -> 'vehicles') x, jsonb_array_elements(x -> 'entries') e
                              where e ->> 'booking_id' ~ '^[0-9a-f-]{36}$'));
  for veh in select x from jsonb_array_elements(v -> 'vehicles') x loop
    with e as (
      select x, n,
             coalesce((x ->> 'booking_id')::uuid = any (ph) and coalesce(x ->> 'status', '') not in ('on_rent', 'returned', 'closed'), false) as ph,
             x ->> 'type' in ('booking', 'block') as bar,
             (x ->> 'type' = 'block') or (x ->> 'type' = 'booking' and coalesce((x ->> 'blocks')::boolean, true) and x ->> 'status' in ('confirmed', 'on_rent')) as takes,
             (x ->> 'starts_at')::timestamptz as s, coalesce((x ->> 'ends_at')::timestamptz, 'infinity'::timestamptz) as f
        from jsonb_array_elements(coalesce(veh -> 'entries', '[]'::jsonb)) with ordinality t(x, n))
    select coalesce(jsonb_agg(e.x || jsonb_build_object('placeholder', e.ph, 'clash', coalesce((
             select jsonb_agg(coalesce(o.x ->> 'booking_number', initcap(replace(coalesce(o.x ->> 'reason', 'block'), '_', ' '))) order by o.s)
               from e o
              where o.n <> e.n and e.bar and o.bar and not e.ph and not o.ph and o.takes
                and o.s < e.f and o.f > e.s
                -- a block over a block is not a clash; a booking that takes the car over another one, or over a block, is
                and not (e.x ->> 'type' = 'block' and o.x ->> 'type' = 'block')), '[]'::jsonb)) order by e.n), '[]'::jsonb)
      into ents from e;
    vehs := vehs || jsonb_build_array(veh || jsonb_build_object('entries', ents));
  end loop;
  return jsonb_set(v, '{vehicles}', vehs);
end $$;

-- ================================================================ privileges
do $$
declare
  g text;
  pair text[];
begin
  foreach pair slice 1 in array array[
      array['app.admin_booking_detail(uuid)', 'app.admin_booking_detail_pre0284(uuid)'],
      array['app.admin_calendar(timestamptz, timestamptz, uuid)', 'app.admin_calendar_pre0284(timestamptz, timestamptz, uuid)']] loop
    execute format('revoke all on function %s from public, anon, authenticated', pair[1]);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, pair[2]::regprocedure, 'execute') then execute format('grant execute on function %s to %I', pair[1], g); end if;
    end loop;
    execute format('revoke all on function %s from public, anon, authenticated', pair[2]);
    execute format('grant execute on function %s to service_role', pair[2]);
  end loop;
end $$;
revoke all on function app.booking_date_conflicts(uuid) from public, anon, authenticated;
grant execute on function app.booking_date_conflicts(uuid) to service_role;

