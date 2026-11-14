-- 2841_r45_photo_order.sql
-- Release 45: the order of a car's photos and its first photo, enforced in the database. The owner: "You should never have
-- an interior photo as the first photo. Always have a front exterior photo as the first photo."
--   1. app.photo_rank: the front three-quarter (front_left) first, then the standard outside views in r45.ts's order (front,
--      side profile, rear three-quarter, rear), the other outside views, then the inside in the
--      standard order (dashboard 20, front seats 21, rear seats 22, trunk 23, wheel 24), then any other detail (30). The
--      same ranks as web/src/lib/photo-order.ts.
--   2. A car's first photo is always an outside one: app.cover_photo (the cards, the feeds, the OG image, the live row)
--      returns no photo rather than an inside one, and app.public_listing_photos (the car's page and every channel) returns
--      no photos while the first would be an inside one. With 2840 the job generates the missing front three-quarter of such
--      a car first, so it is back with an outside photo first within minutes.
--   3. A listing is never published while its first photo would be an inside one (vehicle_listings, a check on publishing).
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

-- ================================================================ 1. the order
create or replace function app.photo_rank(p_shot text) returns integer
language sql immutable parallel safe as $$
  select case when p_shot like 'cover\_%' then -1
              when p_shot = any (array['front_left', 'front', 'left', 'rear_left', 'rear', 'front_right', 'right', 'rear_right', 'exterior_more'])
                then array_position(array['front_left', 'front', 'left', 'rear_left', 'rear', 'front_right', 'right', 'rear_right', 'exterior_more'], p_shot) - 1
              when p_shot = any (array['dashboard', 'front_seats', 'rear_seats', 'trunk', 'wheel'])
                then 19 + array_position(array['dashboard', 'front_seats', 'rear_seats', 'trunk', 'wheel'], p_shot)
              else 30 end
$$;
comment on function app.photo_rank(text) is 'Which photo of a car comes first (2690, 2841): a made cover -1, the front three-quarter (front_left) 0, front 1, left 2, rear_left 3, rear 4, front_right 5, right 6, rear_right 7, exterior_more 8, then the inside: dashboard 20, front seats 21, rear seats 22, trunk 23, wheel 24, any other detail 30. Same ranks as web/src/lib/photo-order.ts.';

create function app.photo_is_exterior(p_shot text) returns boolean language sql immutable parallel safe as $$ select app.photo_rank(p_shot) between -1 and 8 $$;

-- ================================================================ 2. the first photo is always an outside one
alter function app.cover_photo(uuid) rename to cover_photo_pre2841;
create function app.cover_photo(p_vehicle uuid) returns vehicle_photos
language sql stable security definer set search_path = public, app as $$
  select c.* from app.cover_photo_pre2841(p_vehicle) c where c.id is not null and app.photo_is_exterior(c.shot_type)
$$;
select pg_temp.copy_grants('app.cover_photo(uuid)'::regprocedure, 'app.cover_photo_pre2841(uuid)'::regprocedure);
-- the flag of Admin > Cars still sees the inside photo the site would have shown first
create or replace function app.vehicle_primary_state(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when cp.id is null then 'none' when app.photo_is_exterior(cp.shot_type) then 'exterior' else 'not_exterior' end
    from app.cover_photo_pre2841(p_vehicle) cp
$$;

alter function app.public_listing_photos(uuid) rename to public_listing_photos_pre2841;
create function app.public_listing_photos(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  -- (a sample photo or a made cover leads as before: only a real listing shot that is not an outside one is never first)
  select case when jsonb_array_length(x.ph) = 0 or app.photo_is_exterior(x.ph -> 0 ->> 'shot')
                   or not exists (select 1 from listing_shot_types st where st.code = x.ph -> 0 ->> 'shot') then x.ph else '[]'::jsonb end
    from (select coalesce(app.public_listing_photos_pre2841(p_vehicle), '[]'::jsonb) as ph) x
$$;
select pg_temp.copy_grants('app.public_listing_photos(uuid)'::regprocedure, 'app.public_listing_photos_pre2841(uuid)'::regprocedure);

-- ================================================================ 3. never published with an inside photo first
create function app.listing_primary_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'published' and (tg_op = 'INSERT' or old.status is distinct from 'published')
     and not coalesce((select v.is_sample from vehicles v where v.id = new.vehicle_id), false)
     and app.vehicle_primary_state(new.vehicle_id) = 'not_exterior' then
    raise exception 'This car''s first photo would be an inside one: add or approve an outside photo first (a missing front three-quarter is generated by itself)' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists listing_primary_guard on vehicle_listings;
create trigger listing_primary_guard before insert or update of status on vehicle_listings for each row execute function app.listing_primary_guard();

revoke all on function app.photo_is_exterior(text), app.cover_photo_pre2841(uuid), app.public_listing_photos_pre2841(uuid), app.listing_primary_guard() from public, anon, authenticated;
grant execute on function app.photo_is_exterior(text), app.cover_photo_pre2841(uuid), app.public_listing_photos_pre2841(uuid), app.listing_primary_guard() to service_role;
