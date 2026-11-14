-- 2830_r44_owner_rental_history.sql
-- Release 44 (late addition). The owner asked: "Owners need to see a big list of every single rental that their cars have been on, in
-- chronological order, with only the details that they should be able to see visible."
-- public.owner_portal_rental_history (the owner portal's Cars > Bookings > Rental history; the server calls it with the
-- service role and the owner's user id, like every owner read) gives one page of the owner's rentals and the totals:
--   which rentals: every booking on the owner's cars (the booking is theirs and the car is theirs) and every booking whose
--     split for this owner is on one of their cars (a car swapped in), that
--       - is a rental: not a request, an offer, a hold, a checkout not yet paid, expired or declined, and not the owner's
--         own booking of their car;
--       - the owner may see: app.booking_visible_to_owner (2783: it counts for the owner and is not "never" shown);
--       - is not a test booking (a test owner's own account still sees its test bookings);
--       - is not cancelled or a no-show, unless a charge was kept for it: an approved statement carries a rental line for it
--         (2781), or the next statement will (app.owner_period_rentals has a line for it). Shown as "Cancelled, charge kept".
--   what of each: booking number, car (name and plate), pickup and return, rental days and status (upcoming, on rent,
--     completed, cancelled with a charge kept), and the owner's earnings for it exactly as their statements count it: the
--     amount of its rental lines on their approved statements (owner_statement_lines.amount_cents, the "Net earnings" a
--     statement shows, Owner Revenue less the Revenue Share). Nothing approved yet: null ("not yet on a statement"); part
--     of a long rental approved: that amount and more_to_come.
--   never: the renter (name, phone, email, licence, address), insurer, claim, adjuster, deposit, payments, notes or any fee
--     line CarmaCars keeps. The result goes through app.owner_redact (1830) like every owner read.
--   paging: oldest first by default (p_newest for newest first), p_car for one car, p_offset and p_limit (at most 200).
-- No applied migration is edited.
set local check_function_bodies = off;

create function app.owner_rental_history(p_by uuid, p_car uuid default null, p_newest boolean default false,
                                         p_offset integer default 0, p_limit integer default 50) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with o as (
    select ow.id, coalesce(ow.is_test, false) as test from owners ow where ow.id = app.portal_owner_id(p_by)
  ),
  cars as (
    select v.id, app.vehicle_name(v.id) as name, v.plate, v.fleet_number, v.created_at from vehicles v join o on o.id = v.owner_id
  ),
  -- the owner's bookings on their cars, and the cars of theirs a booking was swapped onto (its split for this owner)
  pairs as (
    select b.id as booking_id, b.vehicle_id from bookings b join cars c on c.id = b.vehicle_id join o on o.id = b.owner_id
    union
    select x.booking_id, x.vehicle_id from booking_splits x join cars c on c.id = x.vehicle_id join o on o.id = x.owner_id
     where x.status is distinct from 'reversed'
  ),
  -- what the owner's approved statements carried for each booking and car (the rental lines, as the statement shows them)
  st as (
    select l.booking_id, l.vehicle_id, sum(l.amount_cents)::bigint as cents, bool_or(not l.partial) as complete
      from owner_statement_lines l join owner_statements s on s.id = l.owner_statement_id join o on o.id = s.owner_id
     where s.status::text not in ('void', 'draft') and l.line_type = 'rental' and l.booking_id is not null
     group by l.booking_id, l.vehicle_id
  ),
  r as (
    select b.id, b.booking_number, p.vehicle_id, b.pickup_at, b.return_at, b.status::text as bstatus,
           greatest(coalesce(b.billable_days, ceil(extract(epoch from (b.return_at - b.pickup_at)) / 86400)::integer, 1), 1) as days,
           s.cents, coalesce(s.complete, false) as complete
      from pairs p join bookings b on b.id = p.booking_id cross join o
      left join st s on s.booking_id = b.id and s.vehicle_id = p.vehicle_id
     where b.booking_type::text <> 'owner'
       and b.status::text not in ('requested', 'offered', 'tentative', 'pending_payment', 'expired', 'declined')
       and app.booking_visible_to_owner(b)
       and (o.test or not app.booking_is_test(b.id))
       and (p_car is null or p.vehicle_id = p_car)
       and case when b.status::text not in ('cancelled', 'no_show') then true
                when s.booking_id is not null then s.cents <> 0
                -- a kept charge the next statement will carry
                else exists (select 1 from app.owner_period_rentals(o.id, p.vehicle_id, date '9999-01-01') x
                              where x.booking_id = b.id and x.amount_cents <> 0) end
  ),
  page as (
    select r.* from r
     order by case when p_newest then r.pickup_at end desc nulls last, r.pickup_at, r.booking_number, r.vehicle_id
    offset greatest(coalesce(p_offset, 0), 0) limit least(greatest(coalesce(p_limit, 50), 1), 200)
  )
  select jsonb_build_object(
    'count', (select count(*) from r),
    'days', (select coalesce(sum(r.days), 0) from r),
    'earned_cents', (select coalesce(sum(r.cents), 0) from r),
    'not_on_statement', (select count(*) from r where r.cents is null),
    'upcoming', (select count(*) from r where r.bstatus not in ('on_rent', 'returned', 'closed', 'cancelled', 'no_show')),
    'on_rent', (select count(*) from r where r.bstatus = 'on_rent'),
    'completed', (select count(*) from r where r.bstatus in ('returned', 'closed')),
    'cancelled_kept', (select count(*) from r where r.bstatus in ('cancelled', 'no_show')),
    'offset', greatest(coalesce(p_offset, 0), 0),
    'limit', least(greatest(coalesce(p_limit, 50), 1), 200),
    'newest_first', coalesce(p_newest, false),
    'car', p_car,
    'cars', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', c.id, 'name', c.name, 'plate', c.plate)
                                       order by c.fleet_number nulls last, c.created_at, c.id) from cars c), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'booking_id', g.id, 'booking_number', g.booking_number, 'vehicle_id', g.vehicle_id,
        'car', (select c.name from cars c where c.id = g.vehicle_id), 'plate', (select c.plate from cars c where c.id = g.vehicle_id),
        'pickup_at', g.pickup_at, 'return_at', g.return_at, 'days', g.days,
        'state', case when g.bstatus in ('cancelled', 'no_show') then 'cancelled_kept' when g.bstatus = 'on_rent' then 'on_rent'
                      when g.bstatus in ('returned', 'closed') then 'completed' else 'upcoming' end,
        'earned_cents', g.cents, 'more_to_come', g.cents is not null and not g.complete)
        order by case when p_newest then g.pickup_at end desc nulls last, g.pickup_at, g.booking_number, g.vehicle_id) from page g), '[]'::jsonb))
    from (select 1) one where exists (select 1 from o)
$$;
comment on function app.owner_rental_history(uuid, uuid, boolean, integer, integer) is 'The owner portal''s Rental history (2830): one page of every rental on the owner''s cars that the owner may see, with the totals; the earnings are the rental lines of their approved statements (null: not yet on a statement). Never the renter, payments, deposit, insurer or fees CarmaCars keeps.';

create function public.owner_portal_rental_history(p_by uuid, p_car uuid default null, p_newest boolean default false,
                                                   p_offset integer default 0, p_limit integer default 50) returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select app.owner_redact(app.owner_rental_history(p_by, p_car, p_newest, p_offset, p_limit))
$$;

revoke all on function app.owner_rental_history(uuid, uuid, boolean, integer, integer),
  public.owner_portal_rental_history(uuid, uuid, boolean, integer, integer) from public, anon, authenticated;
grant execute on function app.owner_rental_history(uuid, uuid, boolean, integer, integer),
  public.owner_portal_rental_history(uuid, uuid, boolean, integer, integer) to service_role;
