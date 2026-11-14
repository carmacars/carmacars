-- 2891 (release 47): the website's fleet shows the cars that rent least first, and a partner's sheet fleet after our own.
--
-- The owner's request: show first the cars (not 01 Motors' cars) with a low occupancy, the bookings hidden from owners not
-- counted. The "featured" order of /cars and every list that reads app.public_fleet_trending is now:
--   1. a car an Admin pinned (as before), 2. real cars before the sample cars (as before),
--   3. our own cars before a partner fleet set to show after them (partners.site_priority = 'low'; 01 Motors' sheet fleet
--      is set so once), 4. the lowest occupancy first, 5. then the trending score and the order before (as before).
-- Occupancy: the share of the last 30 and the next 30 days (60 in all) covered by the car's confirmed, on-rent, returned or closed
-- bookings that its owner can see (app.booking_visible_to_owner: an insurer replacement hidden from the owner is not
-- counted). program_settings.fleet_low_occupancy_first switches step 4 off (on by default).
set local check_function_bodies = off;

alter table partners add column if not exists site_priority text not null default 'normal' check (site_priority in ('normal', 'low'));
comment on column partners.site_priority is 'r47 (2891): low: this partner''s cars come after our own cars in the website''s fleet order.';
update partners set site_priority = 'low' where business_name ilike '01 motors%' and site_priority <> 'low';

alter table program_settings add column if not exists fleet_low_occupancy_first boolean not null default true;
comment on column program_settings.fleet_low_occupancy_first is 'r47 (2891): the website''s featured fleet order puts the cars with the lowest occupancy (last and next 30 days, bookings the owner can see) first.';

create or replace function app.fleet_occupancy_bps(p_vehicle uuid, p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select least(10000, round(10000 * coalesce(sum(extract(epoch from (least(b.return_at, p_now + interval '30 days') - greatest(b.pickup_at, p_now - interval '30 days')))), 0)
               / extract(epoch from interval '60 days'))::integer)
    from bookings b
   where b.vehicle_id = p_vehicle and b.status in ('confirmed', 'on_rent', 'returned', 'closed')
     and b.pickup_at < p_now + interval '30 days' and b.return_at > p_now - interval '30 days'
     and app.booking_visible_to_owner(b)
$$;
comment on function app.fleet_occupancy_bps(uuid, timestamptz) is 'r47 (2891): the share (basis points) of the last and next 30 days covered by the car''s confirmed, on-rent, returned or closed bookings its owner can see.';
revoke all on function app.fleet_occupancy_bps(uuid, timestamptz) from public, anon, authenticated;
grant execute on function app.fleet_occupancy_bps(uuid, timestamptz) to service_role;

create or replace function app.public_fleet_trending(p_filters jsonb default '{}'::jsonb) returns setof jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  hot integer := (app.settings()).fleet_hot_count;
  v_occ boolean := coalesce((app.settings()).fleet_low_occupancy_first, true);
begin
  return query
  select q.r || jsonb_build_object('trend_rank', q.n, 'pinned', q.pinned_rank is not null,
                                   'hot', q.n <= hot and q.trend_score > 0 and not coalesce((q.r ->> 'is_sample')::boolean, false),
                                   'popular', q.popular)
    from (select f.r, l.pinned_rank, coalesce(t.score, 0) trend_score, coalesce(t.popular, false) popular,
                 row_number() over (order by l.pinned_rank nulls last, coalesce((f.r ->> 'is_sample')::boolean, false),
                                             coalesce(p.site_priority = 'low', false),
                                             case when v_occ then app.fleet_occupancy_bps((f.r ->> 'vehicle_id')::uuid) end nulls last,
                                             coalesce(t.score, 0) desc, f.o) n
            from app.public_fleet(p_filters) with ordinality f(r, o)
            left join vehicle_listings l on l.vehicle_id = (f.r ->> 'vehicle_id')::uuid
            left join vehicles v on v.id = (f.r ->> 'vehicle_id')::uuid
            left join partners p on p.id = v.partner_id
            left join app.fleet_trend t on t.vehicle_id = (f.r ->> 'vehicle_id')::uuid) q
   order by q.n;
end $$;
