-- 0430: the cars in the rows of the revamped admin and staff pages show their photo (r27, the design review of November 1,
-- 2026: "bring the car tiles closer to real photos"). The cover photo the public site shows for each car (approved, the
-- cover, not replaced), with its sizes, as the Now view (0330) reads it. These photos are already public on the car's
-- page; the server asks only for cars that are in rows the person already sees. Service role only.
create or replace function app.row_car_photos(p_vehicles uuid[]) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_object_agg(x.vehicle_id::text, jsonb_build_object('path', x.processed_path, 'variants', x.variants, 'alt', x.alt_text)), '{}'::jsonb)
    from (select distinct on (ph.vehicle_id) ph.vehicle_id, ph.processed_path, ph.variants, ph.alt_text
            from vehicle_photos ph
           where ph.vehicle_id = any ((coalesce(p_vehicles, '{}'::uuid[]))[1:500]) and ph.is_cover and ph.status = 'approved'
             and ph.replaced_at is null and ph.processed_path is not null
           order by ph.vehicle_id, ph.sort_order, ph.created_at) x
$$;

create or replace function public.server_row_car_photos(p_vehicles uuid[]) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.row_car_photos(p_vehicles) $$;

revoke all on function app.row_car_photos(uuid[]) from public, anon, authenticated;
revoke all on function public.server_row_car_photos(uuid[]) from public, anon, authenticated;
grant execute on function app.row_car_photos(uuid[]) to service_role;
grant execute on function public.server_row_car_photos(uuid[]) to service_role;
