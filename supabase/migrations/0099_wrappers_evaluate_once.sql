-- 0099: the public page wrappers evaluate the wrapped function once.
--
-- The wrappers added by 0061, 0073, 0074 and 0079 were SQL functions of the form
--   select case when r is null ... else r || ... end from (select app.inner(...) r) x
-- Postgres inlines that subquery, so every mention of r called the inner function again. Each layer doubled or
-- tripled the work: a car page took 2 to 3.5 s (the public API cuts a statement at 3 s, so car pages and the home
-- page answered 500 on Oct 22), and a fleet row 48 ms instead of 7 ms. Same results, written in PL/pgSQL, so the
-- inner call runs exactly once per layer.

create or replace function app.public_listing_row_pre0079(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb := app.public_listing_row_0022(p_vehicle);
begin
  if r is null then return null; end if;
  if r -> 'cover' is null or r -> 'cover' = 'null'::jsonb then
    return r || jsonb_build_object('cover', app.vehicle_sample_photos(p_vehicle) -> 0, 'sample_photos', true);
  end if;
  return r || jsonb_build_object('sample_photos', false);
end $$;

create or replace function app.public_listing_row(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare x jsonb := app.public_listing_row_pre0079(p_vehicle);
begin
  if x is null then return null; end if;
  return x || jsonb_build_object('car_code', (select v.car_code from vehicles v where v.id = p_vehicle));
end $$;

create or replace function app.public_car_page_pre0073(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb := app.public_car_page_pre0061(p_slug); vid uuid;
begin
  if r is null or r ? 'redirect' then return r; end if;
  vid := (r ->> 'vehicle_id')::uuid;
  return r || jsonb_build_object(
    'copy', (select case when cc.copy = '{}'::jsonb then null else cc.copy - 'alt_texts' end from car_copy cc where cc.vehicle_id = vid),
    'reviews', app.public_car_reviews(vid));
end $$;

create or replace function app.public_car_page_pre0074(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb := app.public_car_page_pre0073(p_slug);
begin
  if r is null or r ? 'redirect' then return r; end if;
  return r || jsonb_build_object('copy_locked', (select to_jsonb(cc.locked) from car_copy cc where cc.vehicle_id = (r ->> 'vehicle_id')::uuid));
end $$;

create or replace function app.public_car_page(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb := app.public_car_page_pre0074(p_slug);
begin
  if r is null or r ? 'redirect' then return r; end if;
  return r || jsonb_build_object('seo_mark', app.listing_seo_mark((r ->> 'vehicle_id')::uuid));
end $$;
