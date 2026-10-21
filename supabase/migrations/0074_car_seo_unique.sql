-- 0074: one search title and description per car again (docs/changes/2026-10-21-real-car-listing-format.md, section 7)
--
-- Since 0073 every car's search title and description are built from the car and its price, as the sample cars'
-- are ("Rent a 2024 Kia K5 in Toronto from $100 a day | CarmaCars"). Two cars of the same year, make and model (and
-- price) then got the same title and description, which 0068 had prevented (search engines show one of them; the
-- deploy's SEO audit refused it). The car page now gets a distinguishing part when another car on the site shares
-- its year, make and model: its colour when no other of them has that colour, else a short code from the car. (Not the
-- fleet number 0070 used: the public reads never carry a fleet number, suite 11.) The page adds it to the title and the description; every
-- other car keeps the samples' format exactly.

create or replace function app.listing_seo_mark(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  with me as (select v.* from vehicles v where v.id = p_vehicle),
       twins as (select o.* from vehicles o join vehicle_listings l on l.vehicle_id = o.id, me
                  where o.id <> me.id and l.status in ('published', 'paused') and o.year = me.year
                    and lower(btrim(o.make)) = lower(btrim(me.make)) and lower(btrim(o.model)) = lower(btrim(me.model)))
  select case
    when not exists (select 1 from twins) then null
    when nullif(btrim(me.colour), '') is not null
         and not exists (select 1 from twins t where lower(btrim(t.colour)) = lower(btrim(me.colour))) then lower(btrim(me.colour))
    else 'car ' || upper(left(md5(me.id::text), 4)) end
    from me
$$;

alter function app.public_car_page(text) rename to public_car_page_pre0074;
create or replace function app.public_car_page(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when r is null or r ? 'redirect' then r
              else r || jsonb_build_object('seo_mark', app.listing_seo_mark((r ->> 'vehicle_id')::uuid)) end
    from (select app.public_car_page_pre0074(p_slug) r) x
$$;

-- privileges: the new helper for the service role; the car page keeps the privileges it had
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  revoke all on function app.listing_seo_mark(uuid) from public, anon, authenticated;
  grant execute on function app.listing_seo_mark(uuid) to service_role;
  for r in select p.oid, oidvectortypes(p.proargtypes) as args from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = 'public_car_page_pre0074' loop
    v_new := format('app.public_car_page(%s)', r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
